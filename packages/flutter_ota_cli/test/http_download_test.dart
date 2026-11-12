// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_ota_cli/flutter_ota_cli.dart';
import 'package:flutter_ota_cli/src/toolchain/downloader.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// A tiny raw-socket HTTP server that can cut a response short (a dropped connection) and
/// honours `Range` requests, so resume behaviour is tested without any real download.
class FlakyServer {
  FlakyServer(this.body);

  final Uint8List body;
  final requests = <String>[];
  int? cutAfterBytes; // the next full response stops after this many body bytes
  bool ignoreRange = false;
  late ServerSocket _server;

  Uri get url => Uri.parse('http://127.0.0.1:${_server.port}/sdk.tar.gz');

  Future<void> start() async {
    _server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen((s) async {
      final head = StringBuffer();
      late StreamSubscription<Uint8List> sub;
      sub = s.listen((data) async {
        head.write(latin1.decode(data));
        if (!head.toString().contains('\r\n\r\n')) return;
        await sub.cancel();
        final req = head.toString();
        requests.add(req);
        final m = RegExp(r'[Rr]ange: bytes=(\d+)-').firstMatch(req);
        var start = 0;
        if (m != null && !ignoreRange) start = int.parse(m.group(1)!);
        final status = start > 0 ? '206 Partial Content' : '200 OK';
        final range = start > 0 ? 'Content-Range: bytes $start-${body.length - 1}/${body.length}\r\n' : '';
        s.add(
          latin1.encode(
            'HTTP/1.1 $status\r\nContent-Length: ${body.length - start}\r\n$range'
            'Connection: close\r\n\r\n',
          ),
        );
        var chunk = body.sublist(start);
        final cut = cutAfterBytes;
        if (cut != null) {
          chunk = chunk.sublist(0, cut);
          cutAfterBytes = null;
        }
        s.add(chunk);
        await s.flush();
        s.destroy();
      });
    });
  }

  Future<void> close() => _server.close();
}

void main() {
  late Directory tmp;
  late FlakyServer server;
  late Uint8List body;
  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('flutter_ota_http');
    body = Uint8List.fromList(List.generate(300000, (i) => (i * 31) & 0xff));
    server = FlakyServer(body);
    await server.start();
  });
  tearDown(() async {
    await server.close();
    tmp.deleteSync(recursive: true);
  });

  ToolchainArtifact art() =>
      ToolchainArtifact(url: server.url, sha256: sha256.convert(body).toString(), size: body.length, format: 'tar.gz');

  Downloader dl(List<String> log) => Downloader(
    downloadsDir: p.join(tmp.path, 'downloads'),
    client: http.Client(),
    diskSpace: (_) async => null,
    log: log.add,
  );

  test('a truncated response is reported, kept, and resumed with Range', () async {
    final log = <String>[];
    server.cutAfterBytes = 100000;
    final a = art();
    await expectLater(dl(log).fetch(a, label: 'sdk'), throwsA(isA<DownloadInterruptedException>()));
    expect(File(dl(log).partPath(a)).lengthSync(), 100000);
    final path = await dl(log).fetch(a, label: 'sdk');
    expect(File(path).readAsBytesSync(), body);
    expect(server.requests.last, contains('ange: bytes=100000-'));
    expect(log.any((l) => l.startsWith('Resuming sdk')), isTrue);
    expect(File(dl(log).partPath(a)).existsSync(), isFalse);
  });

  test('a server that ignores Range restarts the download from zero', () async {
    final log = <String>[];
    server.cutAfterBytes = 5000;
    final a = art();
    await expectLater(dl(log).fetch(a, label: 'sdk'), throwsA(isA<DownloadInterruptedException>()));
    server.ignoreRange = true;
    final path = await dl(log).fetch(a, label: 'sdk');
    expect(File(path).readAsBytesSync(), body);
  });

  test('wrong content from the server: SHA-256 mismatch, nothing kept', () async {
    final log = <String>[];
    final a = ToolchainArtifact(url: server.url, sha256: '1' * 64, size: body.length, format: 'tar.gz');
    await expectLater(dl(log).fetch(a, label: 'sdk'), throwsA(isA<IntegrityException>()));
    expect(File(dl(log).partPath(a)).existsSync(), isFalse);
    expect(File(dl(log).completedPath(a)).existsSync(), isFalse);
  });

  test('plain http to a non-local host is refused', () async {
    final a = ToolchainArtifact(
      url: Uri.parse('http://mirror.example.org/x.tar.gz'),
      sha256: '1' * 64,
      size: 1,
      format: 'tar.gz',
    );
    await expectLater(dl([]).fetch(a, label: 'x'), throwsA(isA<CliException>()));
  });
}
