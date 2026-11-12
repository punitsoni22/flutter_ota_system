// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:flutter_ota_cli/flutter_ota_cli.dart';

Future<void> main(List<String> args) async {
  exitCode = await runCli(args);
}
