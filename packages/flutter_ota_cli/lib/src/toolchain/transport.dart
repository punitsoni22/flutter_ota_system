// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../errors.dart';

/// Allowed sources: `https://`, `file://` (local mirrors) and `http://` to this machine only.
/// Integrity never depends on the transport: everything is checked against the signed index.
void checkUrlAllowed(Uri url) {
  if (url.scheme == 'https' || url.scheme == 'file') return;
  if (url.scheme == 'http' && isLoopbackHost(url.host)) return;
  throw CliException('Refusing to download from $url: use https://, file:// or http://localhost.');
}

bool isLoopbackHost(String host) => host == 'localhost' || host == '127.0.0.1' || host == '::1' || host == '[::1]';

/// Reads a small document (the index) fully. Throws [CliException] on any failure.
Future<Uint8List> fetchBytes(Uri url, http.Client client, {int maxBytes = 4 * 1024 * 1024}) async {
  checkUrlAllowed(url);
  if (url.scheme == 'file') {
    final f = File.fromUri(url);
    if (!f.existsSync()) throw CliException('Not found: $url');
    if (f.lengthSync() > maxBytes) throw CliException('$url is too large');
    return f.readAsBytesSync();
  }
  final http.Response r;
  try {
    r = await client.get(url).timeout(const Duration(seconds: 60));
  } on Exception catch (e) {
    throw CliException('Could not download $url: $e');
  }
  if (r.statusCode != 200) throw CliException('Could not download $url: HTTP ${r.statusCode}');
  if (r.bodyBytes.length > maxBytes) throw CliException('$url is too large');
  return r.bodyBytes;
}
