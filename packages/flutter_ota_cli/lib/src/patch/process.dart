// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';
import 'dart:io';

/// Result of one external tool run.
class ToolResult {
  ToolResult(this.exitCode, this.stdout, this.stderr);
  final int exitCode;
  final String stdout;
  final String stderr;
}

/// Runs an external program. Injectable so tests can record the argv and fake the tools.
typedef ToolRunner =
    Future<ToolResult> Function(
      String executable,
      List<String> arguments, {
      String? workingDirectory,
      Map<String, String>? environment,
    });

/// The real runner: runs the program at low CPU priority (`nice -n 10`) when `nice` exists, so a
/// patch build does not slow down the rest of the machine.
Future<ToolResult> runLowPriority(
  String executable,
  List<String> arguments, {
  String? workingDirectory,
  Map<String, String>? environment,
}) async {
  final nice = File('/usr/bin/nice').existsSync() ? '/usr/bin/nice' : null;
  final r = await Process.run(
    nice ?? executable,
    [
      if (nice != null) ...['-n', '10', executable],
      ...arguments,
    ],
    workingDirectory: workingDirectory,
    environment: environment,
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
  );
  return ToolResult(r.exitCode, r.stdout as String, r.stderr as String);
}

/// Last [lines] lines of [text] (for error messages).
String tail(String text, [int lines = 30]) {
  final l = const LineSplitter().convert(text.trimRight());
  return (l.length <= lines ? l : l.sublist(l.length - lines)).join('\n');
}
