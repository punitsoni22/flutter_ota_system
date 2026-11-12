// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'aot_runtime.dart';
import 'canonical.dart';
import 'models.dart';
import 'native_boot.dart';
import 'protocol.dart';
import 'patch_id.dart';
import 'runtime.dart';
import 'signature.dart';
import 'state.dart';
import 'test_overrides.dart';
import 'transport.dart';

/// Settings of an [OtaClient]: which server and application to use, which keys to trust, and
/// how patches run.
///
/// ```dart
/// final config = OtaConfig(
///   serverUrl: 'https://ota.example.com',
///   appSlug: 'shop-app',
///   applicationId: '12ebc1fd-abb9-4ee3-83c3-78deb9fadaa8', // from `ota app list`
///   releaseVersion: '1.0.0+1',                             // version+build, as registered
///   publicKeys: const {'prod-1': 'BIi7De…'},               // from `ota key show --dart`
///   runtime: MockPatchRuntime(),
/// );
/// ```
class OtaConfig {
  /// Creates the settings. [serverUrl], [appSlug], [applicationId], [releaseVersion],
  /// [publicKeys] and [runtime] are required; [channel] defaults to `production`.
  const OtaConfig({
    required this.serverUrl,
    required this.appSlug,
    required this.applicationId,
    required this.releaseVersion,
    required this.publicKeys,
    required this.runtime,
    this.channel = 'production',
    this.httpClient,
  }) : assert(applicationId != '', 'applicationId must be the server application id');

  /// Base URL of your Flutter OTA System server, e.g. `https://ota.example.com`.
  ///
  /// Release and profile builds require `https://`. Debug builds may also use
  /// `http://localhost`, `http://127.0.0.1`, `http://[::1]` (e.g. with `adb reverse`) and
  /// `http://10.0.2.2` (Android emulator). Patch download URLs and every redirect follow the
  /// same rules; a refused URL makes [OtaClient.checkForUpdate] return
  /// [UpdateStatus.failed] or [UpdateStatus.rejected] without sending the request.
  final String serverUrl;

  /// The application's **slug** on the server (e.g. `shop-app`), as given to `ota app create`.
  /// Used to register the device.
  final String appSlug;

  /// The application's **server id**: the UUID that `ota app create` and `ota app list` print
  /// as `"id"`.
  ///
  /// Every update-check response names the application it belongs to, and every patch
  /// signature covers this id. The client refuses responses for any other application
  /// (`application id mismatch`), so patches of another app on the same server can never be
  /// installed.
  ///
  /// Not to be confused with [appSlug], nor with the Android `applicationId` (package name) in
  /// your Gradle files: this is the Flutter OTA System server's id.
  final String applicationId;

  /// The installed store build's full version **including the build number**, exactly as
  /// registered on the server (`ota release create` / `ota release android`), e.g. `1.0.0+1`.
  /// With `package_info_plus`: `'${info.version}+${info.buildNumber}'`.
  final String releaseVersion;

  /// Trusted signing keys: key id → base64 uncompressed P-256 public key, as printed by
  /// `ota key show --dart`. Patches signed with any other key are refused. Several keys allow
  /// key rotation. Never ship an app that trusts a local development key.
  final Map<String, String> publicKeys;

  /// How patches run: [MockPatchRuntime] (inert data) or [AotPatchRuntime] (Android code
  /// patches, experimental).
  final PatchRuntime runtime;

  /// Default channel of this build, e.g. `production` or `staging`. Testers can switch at
  /// runtime with [OtaClient.setChannel].
  final String channel;

  /// Optional HTTP client, e.g. for a proxy or certificate pinning. Every request still passes
  /// the URL rules described at [serverUrl], including redirects, which the OTA client follows
  /// itself. Defaults to a `dart:io` client with a 15-second connect timeout.
  final http.Client? httpClient;
}

/// The Flutter OTA System client.
///
/// At start, [boot] picks the code or data to run and protects against patches that fail to
/// start. Later, [checkForUpdate] asks the server for a newer patch, downloads it, verifies its
/// size, SHA-256 and ES256 signature, and stages it. A staged patch runs after the next app
/// restart; the running code is never replaced live.
///
/// ```dart
/// final ota = OtaClient(config);
/// await ota.boot();                        // once, at start
/// runApp(const MyApp());
/// ota.markBootSuccessfulAfterFirstFrame(); // confirms that a new patch starts correctly
/// unawaited(ota.checkForUpdate());         // in the background; never block startup on it
/// ```
///
/// Only [boot] may be called before [boot] has completed; the other members throw a
/// [StateError] (or, for [checkForUpdate], return [UpdateStatus.failed]).
class OtaClient {
  /// Creates a client for [config]. Throws an [ArgumentError] if a public key in
  /// [OtaConfig.publicKeys] is not a valid P-256 point.
  OtaClient(this.config)
    : _verifier = SignatureVerifier(config.publicKeys),
      _overrides = otaTestOverrides,
      // Every request, including redirects, goes through the URL rules (SEC-02).
      _http = SecureRedirectClient(config.httpClient ?? createDefaultHttpClient());

  /// The settings this client was created with.
  final OtaConfig config;
  final SignatureVerifier _verifier;
  final OtaTestOverrides _overrides;
  final http.Client _http;

  late Directory _root;
  late StateStore _store;
  late OtaState _state;
  bool _booted = false;
  Future<UpdateResult>? _inFlight;

  void _requireBoot(String member) {
    if (!_booted) throw StateError('OtaClient.$member used before boot() completed');
  }

  /// The patch running now, or `null` for the store build (also before [boot]).
  PatchRecord? get activePatch => _booted ? _state.active : null;

  /// Number of the patch running now, or `0` for the store build.
  int get activePatchNumber => activePatch?.number ?? 0;

  /// Random id of this installation, created on first launch and sent to the server. It is not
  /// tied to the person or the hardware. Throws a [StateError] before [boot].
  String get installationId {
    _requireBoot('installationId');
    return _state.installationId;
  }

  /// The channel this device checks: the choice made with [setChannel], else
  /// [OtaConfig.channel]. Throws a [StateError] before [boot].
  String get channel {
    _requireBoot('channel');
    return _state.channel ?? config.channel;
  }

  /// Switches this device to another channel, e.g. `staging` for testers; `null` returns to
  /// [OtaConfig.channel]. The choice is saved and used from the next check on. The running code
  /// does not change until a patch from the new channel is downloaded and the app restarts.
  /// Throws a [StateError] before [boot].
  Future<void> setChannel(String? channel) async {
    _requireBoot('setChannel');
    _state.channel = channel == config.channel ? null : channel;
    _state.lastCheckAt = null;
    await _save();
  }

  String get _platform => _overrides.platform ?? (Platform.isIOS ? 'ios' : 'android');
  String get _arch => _overrides.arch ?? _abiName(Abi.current());

  /// Every patch path goes through here. Ids are validated when they arrive (server response,
  /// state file); this is the last line of defence against an id like `../..` (SEC-01).
  Directory _patchDir(String id) {
    if (!isValidPatchId(id)) throw ArgumentError.value(id, 'id', 'invalid patch id');
    return Directory('${_root.path}/patches/$id');
  }

  Directory get _tmpDir => Directory('${_root.path}/tmp');

  // ---- boot ------------------------------------------------------------------------------

  /// Loads the client's state and decides what runs. Call once per app start, before any
  /// other member.
  ///
  /// With [MockPatchRuntime], call it before `runApp` so the active payload is ready for the
  /// first screen. With [AotPatchRuntime] the code was already chosen natively, so it can also
  /// run after the first frame.
  ///
  /// A missing or corrupted patch, or a patch that failed to start last time, never makes it
  /// throw: the last good patch or the store build runs instead. It throws only if the app's
  /// storage directory cannot be read or written.
  Future<void> boot() async {
    _root = _overrides.storageDir ?? Directory('${(await getApplicationSupportDirectory()).path}/ota');
    _store = StateStore(_root);
    _state = await _store.load() ?? OtaState(installationId: _newInstallationId());
    _booted = true;

    if (_state.releaseVersion != config.releaseVersion) {
      // First run, or the user installed a new store version: old patches don't apply.
      _state.resetForNewRelease(config.releaseVersion);
      await _deleteDir(Directory('${_root.path}/patches'));
    }

    final native = nativeBootRuntimeOf(config.runtime);
    if (native != null) {
      await _bootNative(native);
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
    // Ids from native code are stored and sent to the server: keep only valid ones (SEC-01).
    for (final id in report.failedPatchIds.where(isValidPatchId)) {
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
    final runtime = nativeBootRuntimeOf(config.runtime);
    if (runtime == null) return;
    final next = _state.staged ?? _state.active;
    final good = _state.lastGood;
    await runtime.setNextBoot(
      next: next,
      nextDir: next == null ? null : _patchDir(next.id),
      good: good,
      goodDir: good == null ? null : _patchDir(good.id),
    );
  }

  /// Confirms that the patch which just started works, so it becomes the last good patch and
  /// the fallback for later patches. Call it once the app has started and is usable.
  ///
  /// Until a new patch is confirmed, the next start treats it as failed: it is skipped and the
  /// previous good patch (or the store build) runs. Does nothing before [boot] or when no new
  /// patch is waiting for confirmation. Also sends pending telemetry; network errors are
  /// ignored.
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

  /// Calls [markBootSuccessful] after [stableFor] (default 10 seconds).
  ///
  /// Despite its name, it does not watch frames itself: the delay starts when you call it. Call
  /// it right after `runApp` (or from a post-frame callback), so a patch that crashes while
  /// the first screen builds is never confirmed.
  void markBootSuccessfulAfterFirstFrame({Duration stableFor = const Duration(seconds: 10)}) {
    Future.delayed(stableFor, markBootSuccessful);
  }

  // ---- update check ----------------------------------------------------------------------

  /// Asks the server for a newer patch and, if there is one, downloads, verifies and stages it.
  ///
  /// Never throws: the outcome is in the returned [UpdateResult]. A staged patch runs after the
  /// next app restart ([UpdateStatus.stagedRestartRequired]). Also applies server-side rollbacks
  /// and revocations ([UpdateStatus.rollbackRestartRequired]) and sends pending telemetry.
  /// Calls made while a check is running share its result. Returns [UpdateStatus.failed]
  /// before [boot].
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

      final hadPatch = _state.active != null;
      final idProblem = _checkIdentity(response);
      if (idProblem != null) {
        await _save();
        return UpdateResult(UpdateStatus.rejected, message: idProblem);
      }
      // A new release id dropped the running patch: the next start runs the store build.
      final droppedPatch = hadPatch && _state.active == null;

      final rolledBack = _applyBadPatchLists(response) || droppedPatch;
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

  Duration _jittered(int seconds) => Duration(seconds: (seconds * (0.8 + Random().nextDouble() * 0.4)).round());

  String? _checkIdentity(UpdateCheckResponse r) {
    if (r.applicationId != config.applicationId) return 'application id mismatch';
    final releaseId = r.releaseId;
    if (releaseId == null) return null;
    final known = _state.releaseId;
    if (known == null) {
      _state.releaseId = releaseId;
    } else if (known != releaseId) {
      // Going back to an earlier id of this version would let old signed patches be replayed.
      if (_state.retiredReleaseIds.contains(releaseId)) return 'release id changed';
      // The release was deleted and registered again (KI-1). Its patches belonged to the old id,
      // so drop them like after a store update; the next start runs the store build until a
      // patch of the new release arrives. Signatures bind every patch to its release id.
      _state.retiredReleaseIds.add(known);
      _state.releaseId = releaseId;
      _state.staged = null;
      _state.active = null;
      _state.lastGood = null;
      _state.bootAttemptPatchId = null;
      _state.highestAcceptedNumber = 0;
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

    // The id is not signed but names files and directories: check it before anything else.
    if (!isValidPatchId(p.id)) return reject('invalid patch id');
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
    final Uri downloadUri;
    try {
      downloadUri = Uri.parse(p.downloadUrl);
    } on FormatException {
      return reject('invalid download URL');
    }
    final urlProblem = insecureUrlProblem(downloadUri);
    if (urlProblem != null) return reject(urlProblem);

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
        await _download(p, downloadUri, tmp);
      } on _IntegrityError catch (e) {
        _state.addEvent('patch_hash_failed', p.id);
        return reject(e.message);
      } on InsecureUrlException catch (e) {
        return reject(e.message); // a redirect to a refused URL, like a refused download URL
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

  /// Streams the patch into [target]. Every stage has a time limit (SEC-15), so a stalled server
  /// can never hang [checkForUpdate]: response headers, each pause between chunks, and the total.
  Future<void> _download(PatchRecord p, Uri uri, File target) async {
    final t = otaTimeouts;
    final total = Stopwatch()..start();
    final response = await _http
        .send(http.Request('GET', uri))
        .timeout(
          t.downloadResponse,
          onTimeout: () => throw TimeoutException('download: no response', t.downloadResponse),
        );
    if (response.statusCode != 200) {
      unawaited(response.stream.listen(null).cancel());
      throw HttpException('download failed: HTTP ${response.statusCode}');
    }
    final sink = target.openWrite();
    var received = 0;
    try {
      // Leaving the loop (error, timeout, size problem) cancels the download.
      await for (final chunk in response.stream.timeout(
        t.downloadIdle,
        onTimeout: (sink) {
          sink.addError(TimeoutException('download stalled', t.downloadIdle));
          sink.close();
        },
      )) {
        if (total.elapsed > t.downloadTotal) throw TimeoutException('download too slow', t.downloadTotal);
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

  /// Every API call is built here, so an insecure [OtaConfig.serverUrl] never sends a request
  /// (SEC-02). Callers turn the exception into a `failed` result.
  Uri _uri(String path, [Map<String, String>? query]) {
    final uri = Uri.parse('${config.serverUrl.replaceAll(RegExp(r'/+$'), '')}$path').replace(queryParameters: query);
    final problem = insecureUrlProblem(uri);
    if (problem != null) throw InsecureUrlException(problem);
    return uri;
  }

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
        .timeout(otaTimeouts.request);
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
    final r = await _authed((h) => _http.get(uri, headers: h).timeout(otaTimeouts.request));
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
      final r = await _authed(
        (h) => _http
            .post(
              _uri('/v1/events/batch'),
              headers: {...h, 'Content-Type': 'application/json'},
              body: jsonEncode({'events': batch}),
            )
            .timeout(otaTimeouts.request),
      );
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
