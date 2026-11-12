// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../errors.dart';
import '../toolchain/manager.dart';
import '../toolchain/records.dart';
import 'zip_reader.dart';

/// Environment for every process the CLI starts with a toolchain (pub get, front end, flutter
/// build). Starts from [base] and:
///
/// - removes `FLUTTER_ROOT` (the toolchain's `flutter` script sets its own);
/// - sets `FLUTTER_STORAGE_BASE_URL` (file mirror with our engine) and `GRADLE_USER_HOME`
///   (isolated) from the toolchain;
/// - puts the toolchain's `flutter/bin` and Dart `bin` first on `PATH` for the child process only,
///   so nothing in the build can reach a global `flutter`.
///
/// The caller's own environment, PATH and global Flutter are never changed.
Map<String, String> toolchainProcessEnvironment(Map<String, String> base, ResolvedToolchain tc) {
  final env = Map<String, String>.of(base)
    ..remove('FLUTTER_ROOT')
    ..addAll(tc.buildEnvironment);
  final path = base['PATH'] ?? '/usr/bin:/bin';
  env['PATH'] = [p.join(tc.flutterSdk, 'bin'), p.dirname(tc.dartBin), path].join(':');
  return env;
}

/// Front-end (CFE) files inside a toolchain's Flutter SDK.
String frontendServerSnapshot(String flutterSdk) =>
    p.join(flutterSdk, 'bin', 'cache', 'artifacts', 'engine', 'linux-x64', 'frontend_server_aot.dart.snapshot');

/// The product platform the store build is compiled against.
String patchedSdkProduct(String flutterSdk) =>
    p.join(flutterSdk, 'bin', 'cache', 'artifacts', 'engine', 'common', 'flutter_patched_sdk_product');

/// One external command, as run (for logs and `release.json`).
class CommandRecord {
  CommandRecord(this.executable, this.arguments, this.workingDirectory);
  final String executable;
  final List<String> arguments;
  final String workingDirectory;
}

/// Runs a command, streaming its output to [sink]. Throws [CliException] on a non-zero exit.
Future<void> runChecked(
  String executable,
  List<String> args, {
  required String workingDirectory,
  required Map<String, String> environment,
  required StringSink sink,
  required String what,
  List<CommandRecord>? record,
  bool Function(String line)? show,
}) async {
  record?.add(CommandRecord(executable, args, workingDirectory));
  final Process proc;
  try {
    proc = await Process.start(
      executable,
      args,
      workingDirectory: workingDirectory,
      environment: environment,
      includeParentEnvironment: false,
    );
  } on ProcessException catch (e) {
    throw CliException('Could not start $what ($executable): ${e.message}');
  }
  final tail = <String>[];
  void line(String l) {
    if (show == null || show(l)) sink.writeln(l);
    tail.add(l);
    if (tail.length > 30) tail.removeAt(0);
  }

  final a = proc.stdout.transform(utf8.decoder).transform(const LineSplitter()).forEach(line);
  final b = proc.stderr.transform(utf8.decoder).transform(const LineSplitter()).forEach(line);
  final code = await proc.exitCode;
  await Future.wait([a, b]);
  if (code != 0) {
    throw CliException('$what failed (exit code $code). Last output:\n  ${tail.join('\n  ')}');
  }
}

/// Compiles the app's kernel the way patches need it (`link.dill`): not AOT, no tree shaking,
/// platform not linked, with exactly the store build's defines.
Future<void> compileLinkKernel({
  required String flutterSdk,
  required String dartAotRuntime,
  required String packageConfig,
  required String entryUri,
  required String outputDill,
  required List<String> defines,
  String? dynamicInterface,
  required String workingDirectory,
  required Map<String, String> environment,
  required StringSink sink,
  List<CommandRecord>? record,
}) async {
  final snapshot = frontendServerSnapshot(flutterSdk);
  if (!File(snapshot).existsSync()) {
    throw CliException('The toolchain has no front end ($snapshot). Check it with: flutter_ota toolchain doctor');
  }
  await runChecked(
    dartAotRuntime,
    [
      snapshot,
      '--sdk-root',
      '${patchedSdkProduct(flutterSdk)}/',
      '--target',
      'flutter',
      '--no-aot',
      '--no-tfa',
      '--no-link-platform',
      for (final d in defines) '-D$d',
      if (dynamicInterface != null) ...['--dynamic-interface', dynamicInterface],
      '--packages',
      packageConfig,
      '--output-dill',
      outputDill,
      entryUri,
    ],
    workingDirectory: workingDirectory,
    environment: environment,
    sink: sink,
    what: 'Compiling the kernel ($entryUri)',
    record: record,
    // The front end lists every compiled source ("+file:///..."); keep only real messages.
    show: (l) => !l.startsWith('+') && !l.startsWith('-') && !l.startsWith('result '),
  );
  if (!File(outputDill).existsSync()) throw CliException('The front end wrote no $outputDill.');
}

/// Path of `libflutter.so` inside the engine jar and inside an APK.
const libflutterArm64 = 'lib/arm64-v8a/libflutter.so';
const libappArm64 = 'lib/arm64-v8a/libapp.so';

/// SHA-256 of the toolchain's own `libflutter.so` (arm64), read from the engine jar of the
/// toolchain's Maven mirror. The jar itself is covered by the verified install record.
String expectedLibflutterSha256(ResolvedToolchain tc, String engineCommit) {
  final jar = mirrorFilesFor(engineCommit).firstWhere((m) => m.contains('/arm64_v8a_release/') && m.endsWith('.jar'));
  final path = p.join(tc.root, jar);
  if (!File(path).existsSync()) throw CliException('The toolchain mirror has no engine jar ($jar).');
  Never bad(Object e) => throw CliException('Cannot read libflutter.so from the toolchain engine jar ($jar): $e');
  try {
    final bytes = readZipEntry(path, libflutterArm64);
    if (bytes == null) bad('entry missing');
    return sha256.convert(bytes).toString();
  } on FormatException catch (e) {
    bad(e.message);
  }
}
