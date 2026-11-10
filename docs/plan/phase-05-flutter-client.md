# Phase 5 — Flutter client vertical slice (2–3 pw) → Milestone B

**Goal:** the example app checks for an update, downloads the file, verifies its hash, stages it, and uses it after a restart. If anything goes wrong it keeps working on the store version.

**What "patch" means in this phase:** a `mock-v1` patch is just a file, for example a JSON config such as `{"banner":"Hello from patch 1"}`. No code is executed. This proves the whole pipeline safely.

Branch: `git switch -c phase-5-client`.

---

## 5.1 Protocol models (`packages/ota_protocol`)

**Why:** typed Dart classes for the JSON the server sends, matching `docs/api/openapi.json`.

**Do:** create `lib/src/models.dart` with plain immutable classes and `fromJson` factories:

```dart
class PatchArtifactInfo {
  const PatchArtifactInfo({
    required this.format,
    required this.url,
    required this.payloadSha256,
    required this.resultSha256,
    required this.baseArtifactSha256,
    required this.signature,
    required this.signatureAlgorithm,
    required this.keyId,
    required this.sizeBytes,
  });

  factory PatchArtifactInfo.fromJson(Map<String, dynamic> json) => PatchArtifactInfo(
        format: json['format'] as String,
        url: Uri.parse(json['url'] as String),
        payloadSha256: json['payload_sha256'] as String,
        resultSha256: json['result_sha256'] as String,
        baseArtifactSha256: json['base_artifact_sha256'] as String,
        signature: json['signature'] as String,
        signatureAlgorithm: json['signature_algorithm'] as String,
        keyId: json['key_id'] as String,
        sizeBytes: json['size_bytes'] as int,
      );

  final String format;
  final Uri url;
  final String payloadSha256;
  final String resultSha256;
  final String baseArtifactSha256;
  final String signature;
  final String signatureAlgorithm;
  final String keyId;
  final int sizeBytes;
}
```

Do the same for `PatchInfo` (id, number, mandatory, artifact), `CheckResponse` (update_available, reason, patch, next_check_after_seconds, jitter_seconds, revoked_patch_ids, rollback_to_patch_number) and `RegisterResponse`. Export them from `lib/ota_protocol.dart`.

> Hand-written is fine for this size. Later you can switch to `json_serializable` or generate from OpenAPI.

**Check:** unit tests that parse the JSON examples from the blueprint (pages 18–20).

---

## 5.2 The `PatchRuntime` interface (`packages/ota_runtime_api`)

**Do:** `lib/ota_runtime_api.dart`, copied from [ADR-0001](../adr/0001-runtime-abstraction.md):

```dart
library;

import 'dart:io';

enum RuntimeCompatibility { compatible, unsupportedFormat, incompatibleBase }

abstract interface class PatchRuntime {
  /// Formats this runtime can run, e.g. {'mock-v1'}. Sent to the server on check.
  Set<String> get supportedFormats;

  Future<RuntimeCompatibility> checkCompatibility(String format, String baseArtifactSha256);

  /// Called with a file that has ALREADY been hash- and signature-verified.
  Future<void> stagePatch(String patchId, File verifiedPayload);

  Future<void> activateStagedPatch();
  Future<void> markBootSuccessful();
  Future<void> rollback();
  Future<String?> activePatchId();
}
```

---

## 5.3 The mock runtime (`runtimes/mock`)

**Do:**
1. `dart create -t package runtimes/mock_runtime --no-pub`, then add it to the root `pubspec.yaml` workspace list, with `resolution: workspace` and a path dependency on `ota_runtime_api`.
2. `MockPatchRuntime` reads the active patch file as JSON and exposes it: `Map<String, dynamic>? get activeConfig`.

This is enough to prove activation: the app shows `activeConfig['banner']`.

---

## 5.4 On-device storage layout

**Why:** crashes can happen at any moment. The layout must make every state recoverable.

```
<app support dir>/ota/
├── state.json              the single source of truth (see 5.6)
├── tmp/                    downloads in progress (safe to delete at any time)
└── patches/
    ├── <patch_id_A>/payload     verified, immutable
    └── <patch_id_B>/payload
```

Get the directory with `path_provider`'s `getApplicationSupportDirectory()`.

---

## 5.5 Download + hash verification

**Do:** add dependencies to `ota_client`: `http`, `crypto`, `convert`, `path_provider`, `flutter_secure_storage`. Then `lib/src/downloader.dart`:

```dart
import 'dart:io';

import 'package:convert/convert.dart';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

class HashMismatch implements Exception {
  HashMismatch(this.expected, this.actual);
  final String expected;
  final String actual;
  @override
  String toString() => 'HashMismatch(expected $expected, got $actual)';
}

/// Streams [url] into [target] while hashing. Deletes [target] if anything fails.
Future<void> downloadVerified({
  required http.Client client,
  required Uri url,
  required File target,
  required String expectedSha256,
  required int expectedSize,
}) async {
  final response = await client.send(http.Request('GET', url));
  if (response.statusCode != 200) {
    throw HttpException('download failed: ${response.statusCode}', uri: url);
  }

  final digestSink = AccumulatorSink<Digest>();
  final hasher = sha256.startChunkedConversion(digestSink);
  final out = target.openWrite();
  var received = 0;
  try {
    await for (final chunk in response.stream) {
      received += chunk.length;
      if (received > expectedSize) throw const FormatException('payload larger than declared');
      hasher.add(chunk);
      out.add(chunk);
    }
    await out.flush();
  } finally {
    await out.close();
    hasher.close();
  }

  final actual = digestSink.events.single.toString();
  if (received != expectedSize || actual != expectedSha256) {
    await target.delete();
    throw HashMismatch(expectedSha256, actual);
  }
}
```

**Check:** tests with a fake `http.Client` (`package:http/testing.dart` → `MockClient.streaming`): correct file passes, one flipped byte throws, truncated file throws.

---

## 5.6 State file with atomic writes

**Why:** if the app is killed halfway through writing `state.json`, you must never end up with a half-written file. The trick is to write a temp file, then **rename**. A rename is atomic on Android and iOS file systems.

**Do:** `lib/src/state_store.dart`:

```dart
class OtaState {
  // Fields: activePatchId, activePatchNumber, stagedPatchId, stagedPatchNumber,
  // lastGoodPatchId, bootAttemptPatchId, badPatchIds (Set), revokedPatchIds (Set)
  // + toJson / fromJson
}

Future<void> writeStateAtomically(File stateFile, OtaState state) async {
  final tmp = File('${stateFile.path}.tmp');
  await tmp.writeAsString(jsonEncode(state.toJson()), flush: true);
  await tmp.rename(stateFile.path);
}
```

If `state.json` is missing or unreadable, treat it as "no patch" (the store version). **Never crash because of OTA state.**

---

## 5.7 The boot protocol (most important step)

**Why:** a patch that crashes the app on start would crash it forever, unless the next start notices and falls back.

**Do:** run this at app start, **before** `runApp`:

```
on start:
  state = read state.json (or empty)

  if state.bootAttemptPatchId != null:
      # The previous start with this patch never confirmed success → it's bad.
      badPatchIds += bootAttemptPatchId
      active = lastGoodPatchId (or none = store version)
      bootAttemptPatchId = null
      save; report telemetry 'patch_auto_rollback'

  if stagedPatchId != null and not in badPatchIds and not in revokedPatchIds:
      active = staged
      staged = null
      bootAttemptPatchId = active
      save

  if active in revokedPatchIds or badPatchIds:
      active = lastGoodPatchId (or none)
      save

  runtime loads `active`

after the app has run successfully for ~10 seconds (first frame rendered + timer):
  markBootSuccessful → lastGoodPatchId = active, bootAttemptPatchId = null, save
```

**Check:** unit tests for each branch, using a temporary directory. Simulate "killed before confirmation" by running the start logic twice without calling `markBootSuccessful`.

---

## 5.8 API client + auth

**Do:** `lib/src/api_client.dart`:
- `register()` on first launch. Generate `installation_id` with `package:uuid`, and store the ID and refresh token in `flutter_secure_storage`.
- Keep the access token in memory. On a 401, call `/token/refresh` once and retry.
- `check()` sends `release_id`, current patch ID and number, `platform`, `arch`, `channel`, and the runtime's `supportedFormats`.

How the app knows its `release_id`, `platform` and `arch`: pass them in an `OtaConfig` from the app. `release_id` comes from CI at build time (`--dart-define=OTA_RELEASE_ID=...`). `arch` can be read on Android via a small platform channel later. Hard-code `arm64-v8a` for now.

---

## 5.9 The update loop

**Do:** `OtaClient` with a small state machine: `idle → checking → downloading → verifying → staged` (activation happens at the next start via 5.7).

- Schedule: next check = `next_check_after_seconds + Random().nextInt(jitter_seconds)`.
- On failure, back off: 30 s, 1 m, 2 m, 5 m, 15 m, 30 m (+ up to 20% random jitter).
- Also check on app start and when the app returns to the foreground, but no more than once every 5 minutes.
- Before downloading: skip if the patch is in `badPatchIds` or `revokedPatchIds`, or if the runtime says it is incompatible.
- Always store `revoked_patch_ids` from the response in the state, even when there is no update.

---

## 5.10 Wire it into the example app

**Do:** in `app/example_app/lib/main.dart`:
- Call the boot protocol before `runApp`.
- Show: release ID, active patch number, OTA state, and `activeConfig['banner']`.
- Add a debug **Check now** button.

---

## 5.11 End-to-end on an emulator

**Do:**
1. `make up`. Create app, channel, release and patch with your Phase 4 CLI. Upload `{"banner":"Hello from patch 1"}`, then validate and publish.
2. The Android emulator reaches your laptop at `10.0.2.2`, so run with `flutter run --dart-define=OTA_API=http://10.0.2.2:8000`. Also set `OTA_CDN_BASE_URL` in compose to `http://10.0.2.2:10000/devstoreaccount1/artifacts`.
3. Press **Check now** → state `staged`. Restart the app → the banner shows "Hello from patch 1".

**Check:** 🎉 **Milestone B.** Then publish a patch whose `payload_sha256` is deliberately wrong. The app must reject it and keep patch 1.

---

## Phase 5 is done when

- [ ] Hash mismatch, truncated download and oversize download are all rejected (tests)
- [ ] Boot protocol tests pass, including "killed before confirmation"
- [ ] A corrupt or missing `state.json` never crashes the app
- [ ] The emulator demo works end to end
