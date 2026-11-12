// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

// Phase 2 prototype boot runtime. NOT production code: no network, no signature, fixed paths.
// Extends the Phase 1 loader with a per-patch failure counter, a blacklist, live fallback and
// Android exit-reason classification.
//
// Patch file (.otp): "OTAPRT01" | u32 big-endian manifest length | manifest JSON | module bytes
// Manifest: {format, runtime, app_id, baseline_id, patch_number, module_sha256, module_size, ...}

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dynamic_modules/dynamic_modules.dart' as dm;
import 'package:flutter/services.dart';

const _magic = 'OTAPRT01';
const formatVersion = 1;
const runtimeId = 'proto-dbc-flutter-3.47.9';

/// Module entry-point contract version (Phase 2: a map of slot overrides).
const moduleContract = 2;

/// A patch whose unconfirmed starts fail this many times is blacklisted and removed.
const maxFailures = 2;

const appId = String.fromEnvironment('OTA_APP_ID');
const baselineId = String.fromEnvironment('OTA_BASELINE_ID');

const package = 'io.github.punitsoni22.compat_host';
final inboxDir = Directory('/storage/emulated/0/Android/data/$package/files/inbox');
final resultsDir = Directory('/storage/emulated/0/Android/data/$package/files/results');
final storeDir = Directory('/data/user/0/$package/files/ota');

void log(String message) => print('[compat] $message');

class InvalidPatch implements Exception {
  InvalidPatch(this.reason);
  final String reason;
  @override
  String toString() => reason;
}

class ParsedPatch {
  ParsedPatch(this.manifest, this.module);
  final Map<String, Object?> manifest;
  final Uint8List module;
  String get id => manifest['module_sha256']! as String;
  String get label => '#${manifest['patch_number']} ${manifest['name'] ?? ''}'.trim();
}

ParsedPatch parsePatch(Uint8List file, {String kind = 'patch'}) {
  if (file.length < 12 || ascii.decode(file.sublist(0, 8), allowInvalid: true) != _magic) {
    throw InvalidPatch('not a patch file (bad magic)');
  }
  final length = ByteData.sublistView(file, 8, 12).getUint32(0);
  if (12 + length > file.length) throw InvalidPatch('truncated manifest');
  final Map<String, Object?> manifest;
  try {
    manifest = (jsonDecode(utf8.decode(file.sublist(12, 12 + length))) as Map).cast<String, Object?>();
  } on Object {
    throw InvalidPatch('manifest is not valid JSON');
  }
  final module = Uint8List.sublistView(file, 12 + length);
  if (manifest['format'] != formatVersion) throw InvalidPatch('unsupported patch format ${manifest['format']}');
  if (manifest['runtime'] != runtimeId) throw InvalidPatch('module built for runtime ${manifest['runtime']}');
  if (manifest['app_id'] != appId) throw InvalidPatch('patch is for another application');
  if (manifest['baseline_id'] != baselineId) throw InvalidPatch('patch is for another baseline build');
  if ((manifest['kind'] ?? 'patch') != kind) throw InvalidPatch('expected a $kind module, got ${manifest['kind']}');
  final number = manifest['patch_number'];
  if (number is! int || number < 1) throw InvalidPatch('invalid patch number');
  if (manifest['module_size'] != module.length) throw InvalidPatch('module size mismatch (truncated or padded)');
  if (manifest['module_sha256'] != sha256.convert(module).toString()) {
    throw InvalidPatch('module SHA-256 mismatch');
  }
  return ParsedPatch(manifest, module);
}

/// Android's record of how the previous process ended (API 30+), via a small host channel.
class ExitInfo {
  ExitInfo(this.reason, this.description, this.status);
  final int reason;
  final String description;
  final int status;

  // android.app.ApplicationExitInfo.REASON_* (subset)
  static const names = {
    0: 'UNKNOWN', 1: 'EXIT_SELF', 2: 'SIGNALED', 3: 'LOW_MEMORY', 4: 'CRASH', 5: 'CRASH_NATIVE',
    6: 'ANR', 7: 'INITIALIZATION_FAILURE', 8: 'PERMISSION_CHANGE', 9: 'EXCESSIVE_RESOURCE_USAGE',
    10: 'USER_REQUESTED', 11: 'USER_STOPPED', 12: 'DEPENDENCY_DIED', 13: 'OTHER', 14: 'FREEZER',
    15: 'PACKAGE_STATE_CHANGE', 16: 'PACKAGE_UPDATED',
  };
  String get name => names[reason] ?? 'REASON_$reason';

  /// Ends that say nothing about the patch's health (the user or the system stopped the app).
  bool get notAPatchFailure => const {3, 10, 11, 15, 16}.contains(reason);

  @override
  String toString() => '$name(status=$status${description.isEmpty ? '' : ', $description'})';
}

const _exitChannel = MethodChannel('compat/exit_info');

Future<ExitInfo?> lastExitInfo() async {
  try {
    final m = await _exitChannel.invokeMapMethod<String, Object?>('lastExit');
    if (m == null) return null;
    return ExitInfo(m['reason']! as int, m['description'] as String? ?? '', m['status'] as int? ?? 0);
  } catch (e) {
    log('exit info unavailable: $e');
    return null;
  }
}

class BootResult {
  BootResult(this.patch, this.overrides, this.loadMs);
  final ParsedPatch patch;
  final Map<Object?, Object?> overrides;
  final double loadMs;
}

class PatchStore {
  File get active => File('${storeDir.path}/active.otp');
  File get attempt => File('${storeDir.path}/attempt.json');
  File get failuresFile => File('${storeDir.path}/failures.json');
  File get badFile => File('${storeDir.path}/bad.json');

  Map<String, int> failures() => failuresFile.existsSync()
      ? (jsonDecode(failuresFile.readAsStringSync()) as Map).cast<String, int>()
      : <String, int>{};
  Set<String> bad() => badFile.existsSync()
      ? (jsonDecode(badFile.readAsStringSync()) as List).cast<String>().toSet()
      : <String>{};

  void _write(File f, Object value) {
    final tmp = File('${f.path}.tmp')..writeAsStringSync(jsonEncode(value), flush: true);
    tmp.renameSync(f.path);
  }

  void _delete(File f) {
    if (f.existsSync()) f.deleteSync();
  }

  /// Records one failed start of [id]; blacklists and removes it at [maxFailures].
  /// Returns true when the patch was rolled back.
  bool recordFailure(String id, String why) {
    final f = failures();
    final n = (f[id] ?? 0) + 1;
    f[id] = n;
    _write(failuresFile, f);
    log('FAILURE_COUNT patch=${id.substring(0, 12)} count=$n/$maxFailures reason="$why"');
    if (n >= maxFailures) {
      _write(badFile, [...bad(), id]);
      _delete(active);
      _delete(attempt);
      log('ROLLED_BACK patch=${id.substring(0, 12)} blacklisted after $n failed starts; baseline will run');
      return true;
    }
    return false;
  }

  /// Boot sequence. Never throws: any problem means the baseline (AOT) code runs.
  Future<BootResult?> boot(ExitInfo? lastExit) async {
    try {
      // Test-only hook: wipe the private patch store (active patch, attempt, failures, blacklist).
      // The test phone refuses `pm clear` from adb, and reinstalling triggers Play Protect.
      final reset = File('${inboxDir.path}/RESET_STORE');
      if (reset.existsSync()) {
        reset.deleteSync();
        if (storeDir.existsSync()) storeDir.deleteSync(recursive: true);
        log('TEST_HOOK private patch store wiped');
      }
      await storeDir.create(recursive: true);
      _delete(File('${active.path}.tmp')); // a torn install never becomes active

      // 1. Rollback request (prototype: marker file in the inbox).
      final rollback = File('${inboxDir.path}/ROLLBACK');
      if (rollback.existsSync()) {
        _delete(active);
        _delete(attempt);
        rollback.deleteSync();
        log('ROLLBACK requested: active patch removed, baseline will run');
      }

      // Test-only hook: simulate a torn write of the stored patch (power loss mid-write).
      final truncate = File('${inboxDir.path}/STORE_TRUNCATE');
      if (truncate.existsSync()) {
        truncate.deleteSync();
        if (active.existsSync()) {
          final b = active.readAsBytesSync();
          active.writeAsBytesSync(b.sublist(0, b.length ~/ 2), flush: true);
          log('TEST_HOOK stored patch truncated to ${b.length ~/ 2} of ${b.length} bytes');
        }
      }

      // 2. New patch in the inbox: validate, refuse blacklisted patches, store privately.
      final incoming = File('${inboxDir.path}/patch.otp');
      if (incoming.existsSync()) {
        final bytes = incoming.readAsBytesSync();
        incoming.deleteSync();
        try {
          final p = parsePatch(bytes);
          if (bad().contains(p.id)) throw InvalidPatch('patch ${p.label} is blacklisted (failed $maxFailures starts)');
          final tmp = File('${active.path}.tmp')..writeAsBytesSync(bytes, flush: true);
          tmp.renameSync(active.path);
          _delete(attempt);
          final f = failures()..remove(p.id);
          _write(failuresFile, f);
          log('INSTALLED patch ${p.label} (${bytes.length} bytes)');
        } on InvalidPatch catch (e) {
          log('REJECTED incoming patch: $e (current state kept)');
        }
      }

      // 3. Crash guard: the previous start with a patch never confirmed.
      if (attempt.existsSync()) {
        final id = (jsonDecode(attempt.readAsStringSync()) as Map)['patch'] as String;
        _delete(attempt);
        if (lastExit != null && lastExit.notAPatchFailure) {
          log('UNCONFIRMED_START patch=${id.substring(0, 12)} ended by $lastExit: not counted');
        } else {
          log('UNCONFIRMED_START patch=${id.substring(0, 12)} previous exit: ${lastExit ?? 'unknown'}');
          recordFailure(id, 'start not confirmed (${lastExit?.name ?? 'unknown'})');
        }
      }

      if (!active.existsSync()) {
        log('NO_PATCH running baseline (AOT) code');
        return null;
      }

      // 4. Re-validate the stored patch every start.
      final ParsedPatch p;
      try {
        p = parsePatch(active.readAsBytesSync());
      } on InvalidPatch catch (e) {
        _delete(active);
        log('STORED_PATCH_INVALID ($e): removed, baseline will run');
        return null;
      }

      // 5. Mark the attempt, then load the module with the interpreter.
      _write(attempt, {'patch': p.id, 'started': DateTime.now().toIso8601String()});
      final sw = Stopwatch()..start();
      final Object? result;
      try {
        result = await dm.loadModuleFromBytes(Uint8List.fromList(p.module));
      } catch (e) {
        _delete(attempt);
        log('MODULE_LOAD_FAILED patch ${p.label}: ${e.runtimeType}: $e');
        recordFailure(p.id, 'module load/entry failed');
        return null;
      }
      final loadMs = sw.elapsedMicroseconds / 1000;
      if (result is! Map || result['contract'] != moduleContract) {
        _delete(attempt);
        log('MODULE_CONTRACT_MISMATCH patch ${p.label}: ${result.runtimeType}');
        recordFailure(p.id, 'entry point returned an unexpected value');
        return null;
      }
      log('LOADED patch ${p.label} in ${loadMs.toStringAsFixed(1)} ms (${p.module.length} bytes bytecode)');
      return BootResult(p, result, loadMs);
    } catch (e) {
      log('BOOT_ERROR ($e): running baseline (AOT) code');
      return null;
    }
  }

  void confirm(String id) {
    if (attempt.existsSync()) {
      _delete(attempt);
      final f = failures()..remove(id);
      _write(failuresFile, f);
      log('CONFIRMED patch=${id.substring(0, 12)} start confirmed');
    }
  }
}
