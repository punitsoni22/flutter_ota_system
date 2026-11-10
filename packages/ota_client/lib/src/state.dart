import 'dart:convert';
import 'dart:io';

import 'models.dart';

/// Everything the client remembers, in one JSON file written atomically (write tmp, then rename).
///
/// A crash at any moment leaves either the old or the new file, never a half-written one.
class OtaState {
  OtaState({
    required this.installationId,
    this.releaseVersion,
    this.releaseId,
    this.accessToken,
    this.active,
    this.staged,
    this.lastGood,
    this.bootAttemptPatchId,
    Set<String>? badPatchIds,
    this.highestAcceptedNumber = 0,
    this.lastCheckAt,
    this.channel,
    List<Map<String, String>>? pendingEvents,
  })  : badPatchIds = badPatchIds ?? {},
        pendingEvents = pendingEvents ?? [];

  /// Random id created on first launch. Not tied to the person or the hardware.
  final String installationId;
  String? releaseVersion;

  /// Server id of our release, remembered on the first check. A change means a replay attempt.
  String? releaseId;
  String? accessToken;

  /// The patch the app runs now (null = the store build).
  PatchRecord? active;

  /// Downloaded and verified; becomes [active] on the next start.
  PatchRecord? staged;

  /// The last patch that booted successfully (null = the store build).
  PatchRecord? lastGood;

  /// Set while a new patch is booting for the first time. Still set on the next start = it crashed.
  String? bootAttemptPatchId;
  final Set<String> badPatchIds;

  /// Anti-replay (ADR-0006): never accept a lower number unless the server says it is a rollback.
  int highestAcceptedNumber;
  DateTime? lastCheckAt;

  /// Channel picked at runtime (e.g. a tester switching to "staging"). Null = the app's default.
  /// Kept across store updates, so testers stay on their channel.
  String? channel;
  final List<Map<String, String>> pendingEvents;

  /// A store update means a new release: old patches don't belong to it.
  void resetForNewRelease(String version) {
    releaseVersion = version;
    releaseId = null;
    active = null;
    staged = null;
    lastGood = null;
    bootAttemptPatchId = null;
    badPatchIds.clear();
    highestAcceptedNumber = 0;
    lastCheckAt = null;
  }

  void addEvent(String type, String patchId) {
    pendingEvents.add({'type': type, 'patch_id': patchId});
    if (pendingEvents.length > 100) pendingEvents.removeRange(0, pendingEvents.length - 100);
  }

  Map<String, dynamic> toJson() => {
        'installation_id': installationId,
        'release_version': releaseVersion,
        'release_id': releaseId,
        'access_token': accessToken,
        'active': active?.toJson(),
        'staged': staged?.toJson(),
        'last_good': lastGood?.toJson(),
        'boot_attempt_patch_id': bootAttemptPatchId,
        'bad_patch_ids': badPatchIds.toList(),
        'highest_accepted_number': highestAcceptedNumber,
        'last_check_at': lastCheckAt?.toIso8601String(),
        'channel': channel,
        'pending_events': pendingEvents,
      };

  factory OtaState.fromJson(Map<String, dynamic> j) {
    PatchRecord? patch(String key) =>
        j[key] == null ? null : PatchRecord.fromJson(j[key] as Map<String, dynamic>);
    return OtaState(
      installationId: j['installation_id'] as String,
      releaseVersion: j['release_version'] as String?,
      releaseId: j['release_id'] as String?,
      accessToken: j['access_token'] as String?,
      active: patch('active'),
      staged: patch('staged'),
      lastGood: patch('last_good'),
      bootAttemptPatchId: j['boot_attempt_patch_id'] as String?,
      badPatchIds: {...(j['bad_patch_ids'] as List? ?? const []).cast<String>()},
      highestAcceptedNumber: j['highest_accepted_number'] as int? ?? 0,
      lastCheckAt: j['last_check_at'] == null ? null : DateTime.parse(j['last_check_at'] as String),
      channel: j['channel'] as String?,
      pendingEvents: [
        for (final e in (j['pending_events'] as List? ?? const []))
          Map<String, String>.from(e as Map),
      ],
    );
  }
}

class StateStore {
  StateStore(this.dir);
  final Directory dir;

  File get _file => File('${dir.path}/state.json');

  /// Returns null if there is no state yet or it is unreadable (then the store build runs).
  Future<OtaState?> load() async {
    try {
      if (!await _file.exists()) return null;
      return OtaState.fromJson(jsonDecode(await _file.readAsString()) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  Future<void> save(OtaState state) async {
    await dir.create(recursive: true);
    final tmp = File('${_file.path}.tmp');
    final raf = await tmp.open(mode: FileMode.write);
    try {
      await raf.writeString(jsonEncode(state.toJson()));
      await raf.flush();
    } finally {
      await raf.close();
    }
    await tmp.rename(_file.path);
  }
}
