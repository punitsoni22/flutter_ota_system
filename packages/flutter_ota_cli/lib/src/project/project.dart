// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import '../errors.dart';

const projectFileName = 'flutter_ota.yaml';

final _uuidV4 = RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$');

/// Validates and normalises (lower case) a server application UUID. Slugs, Android package names
/// and other identifiers are refused with an explanation.
String validateAppId(String raw) {
  final v = raw.trim().toLowerCase();
  if (_uuidV4.hasMatch(v)) return v;
  final hint = raw.contains('.')
      ? 'It looks like an Android package name.'
      : RegExp(r'^[a-z0-9-]+$').hasMatch(v)
      ? 'It looks like an app slug.'
      : 'It is not a UUID.';
  throw CliException(
    '"$raw" is not a valid app_id. $hint\n'
    'app_id must be the server application UUID (version 4), the "id" shown by `ota app list`,\n'
    'for example 3f2b8c1e-5d4a-4e7b-9c0f-1a2b3c4d5e6f.',
  );
}

/// Finds the nearest directory (from [start] upwards) that contains `flutter_ota.yaml`.
String? findProjectDir(String start) {
  var dir = p.normalize(p.absolute(start));
  while (true) {
    if (File(p.join(dir, projectFileName)).existsSync()) return dir;
    final parent = p.dirname(dir);
    if (parent == dir) return null;
    dir = parent;
  }
}

/// Reads `app_id` from `flutter_ota.yaml`. The file may contain nothing else.
String readAppId(String projectDir) {
  final f = File(p.join(projectDir, projectFileName));
  final Object? y;
  try {
    y = loadYaml(f.readAsStringSync());
  } on YamlException catch (e) {
    throw CliException('${f.path} is not valid YAML: ${e.message}');
  }
  if (y is! YamlMap || y['app_id'] is! String) throw CliException('${f.path} must contain `app_id: <uuid>`.');
  final extra = y.keys.where((k) => k != 'app_id').toList();
  if (extra.isNotEmpty) {
    throw CliException(
      '${f.path} must contain only app_id (found: ${extra.join(', ')}). '
      'Server URL and keys belong in `flutter_ota config`, never in this file.',
    );
  }
  return validateAppId(y['app_id'] as String);
}

/// The exact content of a new `flutter_ota.yaml`.
String projectFileContent(String appId) => 'app_id: $appId\n';
