// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:http/http.dart' as http;

import 'toolchain/disk_space.dart';

/// Reads one line of user input, or returns null when there is no interactive terminal.
typedef Prompter = String? Function(String question);

/// Everything the CLI reads from the outside world, injectable for tests.
class CliContext {
  CliContext({
    Map<String, String>? environment,
    String? workingDirectory,
    StringSink? out,
    StringSink? err,
    Prompter? prompt,
    DiskSpaceProbe? diskSpace,
    http.Client Function()? httpClientFactory,
  }) : environment = environment ?? Platform.environment,
       workingDirectory = workingDirectory ?? Directory.current.path,
       out = out ?? stdout,
       err = err ?? stderr,
       prompt = prompt ?? _stdinPrompt,
       diskSpace = diskSpace ?? dfFreeBytes,
       httpClientFactory = httpClientFactory ?? http.Client.new;

  final Map<String, String> environment;
  final String workingDirectory;
  final StringSink out;
  final StringSink err;
  final Prompter prompt;
  final DiskSpaceProbe diskSpace;
  final http.Client Function() httpClientFactory;

  String get home {
    final h = environment['HOME'];
    if (h == null || h.isEmpty) throw StateError('HOME is not set');
    return h;
  }

  void log(String line) => err.writeln(line);
}

String? _stdinPrompt(String question) {
  if (!stdin.hasTerminal) return null;
  stdout.write(question);
  return stdin.readLineSync();
}
