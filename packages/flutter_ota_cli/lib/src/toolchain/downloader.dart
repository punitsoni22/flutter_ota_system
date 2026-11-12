// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../errors.dart';
import 'disk_space.dart';
import 'index.dart';
import 'transport.dart';

/// SHA-256 of a file, streamed (works for multi-GB files with little memory).
Future<String> sha256OfFile(String path) async => (await sha256.bind(File(path).openRead()).first).toString();

/// Downloads artifacts into `downloads/` with resume, size and SHA-256 checks.
///
/// - `downloads/<sha256>.part` grows while downloading; a later run resumes it
///   (HTTP `Range`, or an offset into a `file://` source).
/// - When complete, the size and SHA-256 must match the signed index, then the file is renamed to
///   `downloads/<sha256>`. A cached file is re-hashed before every use.
/// - A resumed file with the wrong hash is thrown away and downloaded once more from scratch.
class Downloader {
  Downloader({required this.downloadsDir, required this.client, required this.diskSpace, this.log});

  final String downloadsDir;
  final http.Client client;
  final DiskSpaceProbe diskSpace;
  final void Function(String)? log;

  String completedPath(ToolchainArtifact a) => p.join(downloadsDir, a.sha256);
  String partPath(ToolchainArtifact a) => '${completedPath(a)}.part';

  /// Bytes still to download for [a] (0 if a verified copy may already exist).
  int remainingBytes(ToolchainArtifact a) {
    if (File(completedPath(a)).existsSync()) return 0;
    final part = File(partPath(a));
    final have = part.existsSync() ? part.lengthSync() : 0;
    return have >= a.size ? 0 : a.size - have;
  }

  /// Returns the path of a verified copy of [a].
  Future<String> fetch(ToolchainArtifact a, {required String label}) async {
    checkUrlAllowed(a.url);
    Directory(downloadsDir).createSync(recursive: true);
    final done = File(completedPath(a));
    if (done.existsSync()) {
      if (done.lengthSync() == a.size && await sha256OfFile(done.path) == a.sha256) return done.path;
      log?.call('Cached $label is corrupted; downloading it again.');
      done.deleteSync();
    }
    for (var attempt = 0; ; attempt++) {
      final part = File(partPath(a));
      var have = part.existsSync() ? part.lengthSync() : 0;
      if (have > a.size) {
        part.deleteSync();
        have = 0;
      }
      final resumed = have > 0;
      if (have < a.size) {
        await requireDiskSpace(diskSpace, downloadsDir, a.size - have, 'downloading $label');
        log?.call(
          resumed
              ? 'Resuming $label at ${formatBytes(have)} of ${formatBytes(a.size)}'
              : 'Downloading $label (${formatBytes(a.size)}) from ${a.url}',
        );
        if (a.url.scheme == 'file') {
          await _copyFile(a, part, have);
        } else {
          await _httpDownload(a, part, have);
        }
      }
      final got = part.lengthSync();
      if (got != a.size) {
        throw DownloadInterruptedException(
          'Download of $label stopped at ${formatBytes(got)} of ${formatBytes(a.size)}. '
          'Run the same command again to resume.',
        );
      }
      final hash = await sha256OfFile(part.path);
      if (hash == a.sha256) {
        part.renameSync(done.path);
        return done.path;
      }
      part.deleteSync();
      if (resumed && attempt == 0) {
        log?.call('Resumed download of $label did not verify; downloading it again from the start.');
        continue;
      }
      throw IntegrityException(
        'SHA-256 mismatch for $label from ${a.url}:\n  expected ${a.sha256}\n  got      $hash\n'
        'The file was deleted. The mirror may be corrupted or tampered with.',
      );
    }
  }

  Future<void> _copyFile(ToolchainArtifact a, File part, int offset) async {
    final src = File.fromUri(a.url);
    if (!src.existsSync()) throw CliException('Not found: ${a.url}');
    if (src.lengthSync() != a.size) {
      throw IntegrityException(
        'Mirror file ${a.url} has ${src.lengthSync()} bytes, but the signed index says ${a.size}. '
        'The mirror is incomplete or corrupted.',
      );
    }
    final sink = part.openWrite(mode: offset == 0 ? FileMode.write : FileMode.append);
    try {
      await sink.addStream(src.openRead(offset, a.size));
    } finally {
      await sink.close();
    }
  }

  Future<void> _httpDownload(ToolchainArtifact a, File part, int offset) async {
    final req = http.Request('GET', a.url);
    if (offset > 0) req.headers['Range'] = 'bytes=$offset-';
    final http.StreamedResponse resp;
    try {
      resp = await client.send(req).timeout(const Duration(seconds: 60));
    } on Exception catch (e) {
      throw DownloadInterruptedException('Could not connect to ${a.url}: $e. Run the command again to resume.');
    }
    var start = offset;
    if (resp.statusCode == 200) {
      start = 0; // The server ignored Range: start over.
    } else if (resp.statusCode == 206) {
      final cr = resp.headers['content-range'] ?? '';
      final m = RegExp(r'^bytes (\d+)-').firstMatch(cr);
      if (m == null || int.parse(m.group(1)!) != offset) {
        await resp.stream.drain<void>();
        part.deleteSync();
        throw DownloadInterruptedException('Server sent an unexpected range for ${a.url}; run again to restart.');
      }
    } else if (resp.statusCode == 416 && offset > 0) {
      await resp.stream.drain<void>();
      part.deleteSync();
      throw DownloadInterruptedException('Server rejected the resume for ${a.url}; run again to restart.');
    } else {
      await resp.stream.drain<void>();
      throw CliException('Could not download ${a.url}: HTTP ${resp.statusCode}');
    }
    final raf = part.openSync(mode: start == 0 ? FileMode.write : FileMode.append);
    var written = start;
    var nextReport = written + 64 * 1024 * 1024;
    try {
      await for (final chunk in resp.stream.timeout(const Duration(seconds: 60))) {
        if (written + chunk.length > a.size) {
          raf.writeFromSync(chunk, 0, a.size - written);
          written = a.size;
          break; // Never store more than the signed size.
        }
        raf.writeFromSync(chunk);
        written += chunk.length;
        if (written >= nextReport) {
          log?.call('  ${formatBytes(written)} of ${formatBytes(a.size)}');
          nextReport += 64 * 1024 * 1024;
        }
      }
    } on TimeoutException {
      // Keep the partial file; the caller reports an interrupted download.
    } on http.ClientException {
      // Connection dropped: same as above.
    } on IOException {
      // Same as above.
    } finally {
      raf.closeSync();
    }
  }
}
