import 'dart:async';
import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'canonical.dart';
import 'models.dart';
import 'runtime.dart';
import 'signature.dart';
import 'state.dart';

class OtaConfig {
  const OtaConfig({
    required this.serverUrl,
    required this.appSlug,
    required this.releaseVersion,
    required this.publicKeys,
    required this.runtime,
    this.channel = 'production',
    this.applicationId,
    this.storageDir,
    this.platform,
    this.arch,
    this.httpClient,
  });

  /// e.g. https://ota.example.com (Android emulator to your PC: http://10.0.2.2:8000)
  final String serverUrl;
  final String appSlug;

  /// Store version incl. build number, exactly as registered with `ota release create`.
  final String releaseVersion;

  /// key id → base64 uncompressed P-256 point. From `ota key show --dart`.
  final Map<String, String> publicKeys;
  final PatchRuntime runtime;
  final String channel;

  /// Optional: pin the server's application id so patches of another app are refused.
  final String? applicationId;

  /// Test overrides. Defaults: app support dir, current platform, current CPU ABI.
  final Directory? storageDir;
  final String? platform;
  final String? arch;
  final http.Client? httpClient;
}

/// The OTA client: boot protection at start, then check → download → verify → stage.
///
/// ```dart
/// final ota = OtaClient(config);
/// await ota.boot();                       // before runApp
/// runApp(...);
/// ota.markBootSuccessfulAfterFirstFrame(); // confirms the patch works
/// ota.checkForUpdate();                    // in the background, never awaited at startup
/// ```
class OtaClient {
  OtaClient(this.config)
      : _verifier = SignatureVerifier(config.publicKeys),
        _http = config.httpClient ?? http.Client();

  final OtaConfig config;
  final SignatureVerifier _verifier;
  final http.Client _http;

  late Directory _root;
  late StateStore _store;
  late OtaState _state;
  bool _booted = false;
  Future<UpdateResult>? _inFlight;

  /// The patch running now, or null for the store build.
  PatchRecord? get activePatch => _booted ? _state.active : null;
  int get activePatchNumber => activePatch?.number ?? 0;
  String get installationId => _state.installationId;

  /// The channel this device checks: the runtime choice from [setChannel], else [OtaConfig.channel].
  String get channel => _state.channel ?? config.channel;

  /// Switch this device to another channel, e.g. "staging" for testers (null = back to the default).
  /// Saved, and used from the next check on. The running code does not change until a patch from the
  /// new channel is downloaded and the app restarts.
  Future<void> setChannel(String? channel) async {
    _state.channel = channel == config.channel ? null : channel;
    _state.lastCheckAt = null;
    await _save();
  }

  String get _platform => config.platform ?? (Platform.isIOS ? 'ios' : 'android');
  String get _arch => config.arch ?? _abiName(Abi.current());

  Directory _patchDir(String id) => Directory('${_root.path}/patches/$id');
  Directory get _tmpDir => Directory('${_root.path}/tmp');

  // ---- boot ------------------------------------------------------------------------------

  /// Call once, before runApp. Never throws: on any problem the store build runs.
  Future<void> boot() async {
    _root = config.storageDir ?? Directory('${(await getApplicationSupportDirectory()).path}/ota');
    _store = StateStore(_root);
    _state = await _store.load() ?? OtaState(installationId: _newInstallationId());
    _booted = true;

    if (_state.releaseVersion != config.releaseVersion) {
      // First run, or the user installed a new store version: old patches don't apply.
      _state.resetForNewRelease(config.releaseVersion);
      await _deleteDir(Directory('${_root.path}/patches'));
    }

    final runtime = config.runtime;
    if (runtime is NativeBootRuntime) {
      await _bootNative(runtime);
      unawaited(_cleanUnusedPatches());
      return;
    }

    // The previous start with a new patch never confirmed success → it crashed.
    final attempt = _state.bootAttemptPatchId;
    if (attempt != null) {
      _state.badPatchIds.add(attempt);
      _state.addEvent('patch_boot_failed', attempt);
      _state.addEvent('patch_auto_rollback', attempt);
      _state.active = _state.lastGood;
      _state.bootAttemptPatchId = null;
      // The crashed patch never really ran, so it must not block older good patches as "replays".
      _state.highestAcceptedNumber = max(_state.lastGood?.number ?? 0, _state.staged?.number ?? 0);
    }

    final staged = _state.staged;
    if (staged != null) {
      _state.staged = null;
      if (!_state.badPatchIds.contains(staged.id)) {
        _state.active = staged;
        _state.bootAttemptPatchId = staged.id;
      }
    }

    if (_state.active != null && _state.badPatchIds.contains(_state.active!.id)) {
      _state.active = _state.lastGood;
    }
    await _save();

    final active = _state.active;
    try {
      await config.runtime.load(active, active == null ? null : _patchDir(active.id));
    } catch (_) {
      // Missing or corrupted patch on disk: run the store build, never this patch again.
      if (active != null) {
        _state.badPatchIds.add(active.id);
        _state.addEvent('patch_hash_failed', active.id);
        _state.active = null;
        _state.lastGood = null;
        _state.bootAttemptPatchId = null;
        await _save();
      }
      await config.runtime.load(null, null);
    }
    unawaited(_cleanUnusedPatches());
  }

  /// Code patches: native code already picked what runs (and caught crashes). Mirror it here.
  Future<void> _bootNative(NativeBootRuntime runtime) async {
    final report = await runtime.readBootReport();
    for (final id in report.failedPatchIds) {
      if (_state.badPatchIds.add(id)) {
        _state.addEvent('patch_boot_failed', id);
        _state.addEvent('patch_auto_rollback', id);
      }
    }
    bool bad(PatchRecord? p) => p != null && _state.badPatchIds.contains(p.id);
    final candidates = [_state.staged, _state.active, _state.lastGood];
    final loaded = report.loadedPatchId;
    _state.active = candidates.firstWhere((p) => p != null && p.id == loaded, orElse: () => null);
    if (bad(_state.lastGood)) _state.lastGood = null;
    final staged = _state.staged;
    if (staged != null && (staged.id == loaded || bad(staged))) _state.staged = null;
    if (report.failedPatchIds.isNotEmpty) {
      // A crashed patch never really ran, so it must not block older good patches as "replays".
      _state.highestAcceptedNumber = [
        for (final p in [_state.lastGood, _state.active, _state.staged]) p?.number ?? 0,
      ].reduce(max);
    }
    final active = _state.active;
    // Unconfirmed until markBootSuccessful; native code counts it as failed if that never happens.
    _state.bootAttemptPatchId = active != null && active.id != _state.lastGood?.id ? active.id : null;
    await _save();
  }

  /// Saves the state, and for code patches tells the native side what to load on the next start.
  Future<void> _save() async {
    await _store.save(_state);
    final runtime = config.runtime;
    if (runtime is! NativeBootRuntime) return;
    final next = _state.staged ?? _state.active;
    final good = _state.lastGood;
    await runtime.setNextBoot(
      next: next,
      nextDir: next == null ? null : _patchDir(next.id),
      good: good,
      goodDir: good == null ? null : _patchDir(good.id),
    );
  }

  /// Confirms that the patch which just booted works. Call once the app is stable.
  Future<void> markBootSuccessful() async {
    if (!_booted) return;
    final attempt = _state.bootAttemptPatchId;
    if (attempt == null) return;
    _state.bootAttemptPatchId = null;
    _state.lastGood = _state.active;
    _state.addEvent('patch_boot_succeeded', attempt);
    await _save();
    // Report now, not at the next check (up to 30 min away): staging results decide promotions.
    await _flushEvents();
  }

  /// Waits for the first frame plus [stableFor], then calls [markBootSuccessful].
  void markBootSuccessfulAfterFirstFrame({Duration stableFor = const Duration(seconds: 10)}) {
    Future.delayed(stableFor, markBootSuccessful);
  }

  // ---- update check ----------------------------------------------------------------------

  /// Checks the server and stages a new patch if there is one. Never throws.
  ///
  /// Respects the server's check interval unless [force] is true.
  Future<UpdateResult> checkForUpdate({bool force = false}) {
    if (!_booted) return Future.value(const UpdateResult(UpdateStatus.failed, message: 'boot() not called'));
    return _inFlight ??= _check(force).whenComplete(() => _inFlight = null);
  }

  Future<UpdateResult> _check(bool force) async {
    try {
      await _flushEvents();
      final last = _state.lastCheckAt;
      if (!force && last != null && DateTime.now().difference(last) < _minInterval) {
        return const UpdateResult(UpdateStatus.upToDate, message: 'checked recently');
      }
      final response = await _requestCheck();
      _state.lastCheckAt = DateTime.now();
      _minInterval = _jittered(response.nextCheckAfterSeconds);

      final idProblem = _checkIdentity(response);
      if (idProblem != null) {
        await _save();
        return UpdateResult(UpdateStatus.rejected, message: idProblem);
      }

      final rolledBack = _applyBadPatchLists(response);
      final offered = response.patch;
      if (!response.updateAvailable || offered == null) {
        await _save();
        return rolledBack
            ? UpdateResult(UpdateStatus.rollbackRestartRequired, patchNumber: response.rollbackToPatchNumber)
            : const UpdateResult(UpdateStatus.upToDate);
      }
      final result = await _downloadVerifyStage(offered, response);
      await _save();
      await _flushEvents();
      return result;
    } catch (e) {
      return UpdateResult(UpdateStatus.failed, message: '$e');
    }
  }

  Duration _minInterval = Duration.zero;

  Duration _jittered(int seconds) =>
      Duration(seconds: (seconds * (0.8 + Random().nextDouble() * 0.4)).round());

  String? _checkIdentity(UpdateCheckResponse r) {
    final pinned = config.applicationId;
    if (pinned != null && r.applicationId != pinned) return 'application id mismatch';
    final releaseId = r.releaseId;
    if (releaseId == null) return null;
    if (_state.releaseId == null) {
      _state.releaseId = releaseId;
    } else if (_state.releaseId != releaseId) {
      return 'release id changed';
    }
    return null;
  }

  /// ADR-0005: every response lists bad patches. Returns true if the running patch is bad.
  bool _applyBadPatchLists(UpdateCheckResponse r) {
    final bad = r.badPatchNumbers;
    if (bad.isEmpty) return false;
    final staged = _state.staged;
    if (staged != null && bad.contains(staged.number)) _state.staged = null;
    final lastGood = _state.lastGood;
    if (lastGood != null && bad.contains(lastGood.number)) _state.lastGood = null;

    final active = _state.active;
    if (active == null || !bad.contains(active.number)) return false;
    _state.badPatchIds.add(active.id);
    // Takes effect on the next start: the running code is never swapped live.
    _state.active = _state.lastGood;
    _state.bootAttemptPatchId = null;
    return true;
  }

  Future<UpdateResult> _downloadVerifyStage(PatchRecord p, UpdateCheckResponse r) async {
    UpdateResult reject(String why) => UpdateResult(UpdateStatus.rejected, patchNumber: p.number, message: why);

    if (_state.badPatchIds.contains(p.id)) return reject('patch previously failed on this device');
    // Already downloaded by an earlier check (e.g. the background one at startup): not a replay.
    if (_state.staged?.id == p.id) return UpdateResult(UpdateStatus.stagedRestartRequired, patchNumber: p.number);
    if (p.number <= _state.highestAcceptedNumber && p.number != r.rollbackToPatchNumber) {
      return reject('replay: patch ${p.number} is not newer than ${_state.highestAcceptedNumber}');
    }
    if (p.arch != _arch) return reject('arch mismatch');
    if (p.runtimeAbi != config.runtime.runtimeAbi) return reject('runtime abi mismatch');
    if (!config.runtime.supportedFormats.contains(p.artifactFormat)) return reject('unsupported format');
    if (!_verifier.knowsKey(p.keyId)) return reject('unknown signing key ${p.keyId}');

    final fields = SignedFields(
      applicationId: r.applicationId,
      releaseId: r.releaseId!,
      patchNumber: p.number,
      platform: _platform,
      arch: _arch,
      runtimeAbi: config.runtime.runtimeAbi,
      artifactFormat: p.artifactFormat,
      baseArtifactSha256: p.baseArtifactSha256,
      payloadSha256: p.payloadSha256,
      resultSha256: p.resultSha256,
      sizeBytes: p.sizeBytes,
    );
    // Verify the signature BEFORE downloading: a forged manifest costs no bandwidth.
    if (!_verifier.verify(p.keyId, fields.message(), p.signature)) {
      _state.addEvent('patch_signature_failed', p.id);
      return reject('signature invalid');
    }

    await _tmpDir.create(recursive: true);
    final tmp = File('${_tmpDir.path}/${p.id}.download');
    try {
      try {
        await _download(p, tmp);
      } on _IntegrityError catch (e) {
        _state.addEvent('patch_hash_failed', p.id);
        return reject(e.message);
      }
      final digest = (await sha256.bind(tmp.openRead()).first).toString();
      if (digest != p.payloadSha256) {
        _state.addEvent('patch_hash_failed', p.id);
        return reject('hash mismatch');
      }
      _state.addEvent('patch_downloaded', p.id);

      final dir = _patchDir(p.id);
      await _deleteDir(dir);
      await config.runtime.stage(p, tmp, dir);
    } finally {
      if (await tmp.exists()) await tmp.delete();
    }

    _state.staged = p;
    if (p.number > _state.highestAcceptedNumber) _state.highestAcceptedNumber = p.number;
    _state.addEvent('patch_staged', p.id);
    return UpdateResult(UpdateStatus.stagedRestartRequired, patchNumber: p.number);
  }

  Future<void> _download(PatchRecord p, File target) async {
    final response = await _http.send(http.Request('GET', Uri.parse(p.downloadUrl)));
    if (response.statusCode != 200) {
      throw HttpException('download failed: HTTP ${response.statusCode}');
    }
    final sink = target.openWrite();
    var received = 0;
    try {
      await for (final chunk in response.stream) {
        received += chunk.length;
        if (received > p.sizeBytes) throw const _IntegrityError('download size mismatch');
        sink.add(chunk);
      }
    } finally {
      await sink.close();
    }
    if (received != p.sizeBytes) throw const _IntegrityError('download size mismatch');
  }

  // ---- server calls ----------------------------------------------------------------------

  Uri _uri(String path, [Map<String, String>? query]) =>
      Uri.parse('${config.serverUrl.replaceAll(RegExp(r'/+$'), '')}$path').replace(queryParameters: query);

  Future<void> _register() async {
    final r = await _http
        .post(
          _uri('/v1/devices/register'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'app': config.appSlug,
            'installation_id': _state.installationId,
            'platform': _platform,
            'arch': _arch,
            'release_version': config.releaseVersion,
            'channel': channel,
          }),
        )
        .timeout(const Duration(seconds: 15));
    if (r.statusCode != 200) throw HttpException('register failed: HTTP ${r.statusCode} ${r.body}');
    _state.accessToken = (jsonDecode(r.body) as Map<String, dynamic>)['access_token'] as String;
    await _save();
  }

  Future<http.Response> _authed(Future<http.Response> Function(Map<String, String> headers) send) async {
    if (_state.accessToken == null) await _register();
    var r = await send({'Authorization': 'Bearer ${_state.accessToken}'});
    if (r.statusCode == 401) {
      await _register();
      r = await send({'Authorization': 'Bearer ${_state.accessToken}'});
    }
    return r;
  }

  Future<UpdateCheckResponse> _requestCheck() async {
    final uri = _uri('/v1/updates/check', {
      'platform': _platform,
      'arch': _arch,
      'release_version': config.releaseVersion,
      'channel': channel,
      'current_patch_number': '$activePatchNumber',
      'supported_formats': config.runtime.supportedFormats.join(','),
      // So the server offers the newest patch that has NOT crashed here, not one we will refuse.
      if (_state.badPatchIds.isNotEmpty) 'failed_patch_ids': _state.badPatchIds.toList().reversed.take(20).join(','),
    });
    final r = await _authed((h) => _http.get(uri, headers: h).timeout(const Duration(seconds: 15)));
    if (r.statusCode != 200) throw HttpException('check failed: HTTP ${r.statusCode}');
    return UpdateCheckResponse.fromJson(jsonDecode(r.body) as Map<String, dynamic>);
  }

  Future<void>? _flushing;

  /// One send at a time, so a batch is never sent twice.
  Future<void> _flushEvents() => _flushing ??= _sendEvents().whenComplete(() => _flushing = null);

  Future<void> _sendEvents() async {
    if (_state.pendingEvents.isEmpty) return;
    final batch = List<Map<String, String>>.of(_state.pendingEvents);
    try {
      final r = await _authed((h) => _http
          .post(
            _uri('/v1/events/batch'),
            headers: {...h, 'Content-Type': 'application/json'},
            body: jsonEncode({'events': batch}),
          )
          .timeout(const Duration(seconds: 15)));
      if (r.statusCode == 202 || r.statusCode == 422) {
        // 422 = malformed batch; drop it rather than retry forever.
        _state.pendingEvents.removeRange(0, batch.length);
        await _save();
      }
    } catch (_) {
      // Telemetry is best effort; keep events for the next try.
    }
  }

  // ---- housekeeping ----------------------------------------------------------------------

  Future<void> _cleanUnusedPatches() async {
    try {
      final keep = {_state.active?.id, _state.staged?.id, _state.lastGood?.id};
      final dir = Directory('${_root.path}/patches');
      if (await dir.exists()) {
        await for (final entry in dir.list()) {
          final id = entry.uri.pathSegments.where((s) => s.isNotEmpty).last;
          if (!keep.contains(id)) await entry.delete(recursive: true);
        }
      }
      await _deleteDir(_tmpDir);
    } catch (_) {}
  }

  static Future<void> _deleteDir(Directory dir) async {
    if (await dir.exists()) await dir.delete(recursive: true);
  }

  static String _newInstallationId() {
    final rnd = Random.secure();
    return List.generate(16, (_) => rnd.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  }

  static String _abiName(Abi abi) => switch (abi) {
        Abi.androidArm64 => 'arm64-v8a',
        Abi.androidArm => 'armeabi-v7a',
        Abi.androidX64 => 'x86_64',
        Abi.androidIA32 => 'x86',
        Abi.iosArm64 => 'arm64',
        Abi.iosX64 => 'x86_64',
        _ => abi.toString(),
      };
}

class _IntegrityError implements Exception {
  const _IntegrityError(this.message);
  final String message;
}
