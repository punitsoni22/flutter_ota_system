// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

// Phase 1 prototype loader. NOT production code: no network, no signature (integrity and
// identity checks only), fixed paths, one patchable package.
//
// Patch file (.otp):  "OTAPRT01" | u32 big-endian manifest length | manifest JSON | module bytes
// Manifest: {format, runtime, app_id, baseline_id, patch_number, module_sha256, module_size}

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dynamic_modules/dynamic_modules.dart' as dm;

const _magic = 'OTAPRT01';
const formatVersion = 1;

/// The bytecode runtime this host was built with (custom engine, Flutter 3.47.9).
const runtimeId = 'proto-dbc-flutter-3.47.9';

/// Identity of this host build, injected at build time.
const appId = String.fromEnvironment('OTA_APP_ID');
const baselineId = String.fromEnvironment('OTA_BASELINE_ID');

const _package = 'io.github.punitsoni22.bytecode_proto';
// Prototype only: fixed paths instead of path_provider. The inbox is app-specific external
// storage, so `adb push` can deliver a patch without root or a debuggable build.
final inboxDir = Directory('/storage/emulated/0/Android/data/$_package/files/inbox');
final storeDir = Directory('/data/user/0/$_package/files/ota');

void log(String message) => print('[ota-proto] $message');

class PatchResult {
  PatchResult(this.greeting, this.patchNumber);
  final String Function() greeting;
  final int patchNumber;
}

class InvalidPatch implements Exception {
  InvalidPatch(this.reason);
  final String reason;
  @override
  String toString() => reason;
}

/// Validates a patch file and returns its manifest and module bytes, or throws [InvalidPatch].
(Map<String, Object?>, Uint8List) parsePatch(Uint8List file) {
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
  final number = manifest['patch_number'];
  if (number is! int || number < 1) throw InvalidPatch('invalid patch number');
  if (manifest['module_size'] != module.length) throw InvalidPatch('module size mismatch');
  if (manifest['module_sha256'] != sha256.convert(module).toString()) {
    throw InvalidPatch('module SHA-256 mismatch');
  }
  return (manifest, module);
}

/// Boot sequence: rollback request → inbox → crash-loop guard → load the active patch.
/// Never throws: any problem means the baseline (AOT) code runs.
Future<PatchResult?> bootPatch() async {
  try {
    await storeDir.create(recursive: true);
    final active = File('${storeDir.path}/active.otp');
    final attempt = File('${storeDir.path}/ATTEMPT');

    // 1. Rollback request (prototype: a marker file pushed into the inbox).
    final rollback = File('${inboxDir.path}/ROLLBACK');
    if (rollback.existsSync()) {
      if (active.existsSync()) active.deleteSync();
      if (attempt.existsSync()) attempt.deleteSync();
      rollback.deleteSync();
      log('rollback requested: active patch removed, baseline will run');
    }

    // 2. New patch in the inbox: validate, then store it privately (never load from the inbox).
    final incoming = File('${inboxDir.path}/patch.otp');
    if (incoming.existsSync()) {
      final bytes = incoming.readAsBytesSync();
      incoming.deleteSync();
      try {
        final (manifest, _) = parsePatch(bytes);
        final tmp = File('${storeDir.path}/active.otp.tmp')..writeAsBytesSync(bytes, flush: true);
        tmp.renameSync(active.path);
        if (attempt.existsSync()) attempt.deleteSync();
        log('installed patch #${manifest['patch_number']} (${bytes.length} bytes) into private storage');
      } on InvalidPatch catch (e) {
        log('REJECTED incoming patch: $e (baseline stays)');
      }
    }

    // 3. Crash-loop guard: a previous start with the patch never confirmed → drop the patch.
    if (attempt.existsSync()) {
      attempt.deleteSync();
      if (active.existsSync()) active.deleteSync();
      log('previous start with the patch did not confirm: patch removed, baseline will run');
    }

    if (!active.existsSync()) {
      log('no active patch: running baseline (AOT) code');
      return null;
    }

    // 4. Re-validate the stored patch every start, then load it with the bytecode interpreter.
    final (manifest, module) = parsePatch(active.readAsBytesSync());
    attempt.writeAsStringSync('${manifest['patch_number']}', flush: true);
    log('loading bytecode module (${module.length} bytes) with the Dart VM interpreter');
    final result = await dm.loadModuleFromBytes(Uint8List.fromList(module));
    if (result is! Map || result['contract'] != 1 || result['greeting'] is! String Function()) {
      throw InvalidPatch('module entry point returned an unexpected value');
    }
    log('module loaded: patch #${manifest['patch_number']} replaces package:${result['package']}');
    return PatchResult(result['greeting']! as String Function(), manifest['patch_number']! as int);
  } catch (e) {
    log('patch not used ($e): running baseline (AOT) code');
    try {
      final active = File('${storeDir.path}/active.otp');
      if (active.existsSync()) active.deleteSync();
      final attempt = File('${storeDir.path}/ATTEMPT');
      if (attempt.existsSync()) attempt.deleteSync();
    } catch (_) {}
    return null;
  }
}

/// Marks the patched start as good (called once the first screen is up).
void confirmBoot() {
  final attempt = File('${storeDir.path}/ATTEMPT');
  if (attempt.existsSync()) {
    attempt.deleteSync();
    log('start confirmed');
  }
}
