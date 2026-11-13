// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_ota_cli/flutter_ota_cli.dart';
import 'package:flutter_ota_cli/src/build_support/toolchain_build.dart';
import 'package:path/path.dart' as p;

import '../elf_fixture.dart';

const appId = '3f2b8c1e-5d4a-4e7b-9c0f-1a2b3c4d5e6f';
const appSlug = 'demo-app';
const adminKey = 'test-admin-key';
const engineCommit = '89c39edfdfae2949f6806e4a315c0c08522238b7';
const toolchainName = 'flutter-3.47.9-ota.1';

/// Content of the fake toolchain's dynamic_modules library.
const loaderSource = '// fake loader\nFuture<Object?> loadModuleFromBytes(Object bytes) async => null;\n';

/// Kernel libraries of the fake app (as the fake front end "compiles" them).
const fakeKernelLibraries = [
  'dart:async',
  'dart:core',
  'dart:ffi',
  'dart:_internal',
  'dart:ui',
  'package:demo_app/main.dart',
  'package:feature_a/feature_a.dart',
  'package:flutter/src/widgets/framework.dart',
  'package:flutter/widgets.dart',
  'package:collection/collection.dart',
  'package:flutter_ota_system/flutter_ota_system.dart',
  'package:demo_app/flutter_ota_main.g.dart',
  'package:dynamic_modules/dynamic_modules.dart',
];

// ------------------------------------------------------------------ zip

/// Writes a ZIP file (entries stored, or deflated when [deflate] is true).
Uint8List makeZip(Map<String, List<int>> files, {bool deflate = false}) {
  final out = BytesBuilder();
  final central = BytesBuilder();
  void u16(BytesBuilder b, int v) => b.add([v & 0xff, (v >> 8) & 0xff]);
  void u32(BytesBuilder b, int v) => b.add([v & 0xff, (v >> 8) & 0xff, (v >> 16) & 0xff, (v >> 24) & 0xff]);
  for (final e in files.entries) {
    final name = utf8.encode(e.key);
    final data = deflate ? ZLibEncoder(raw: true).convert(e.value) : e.value;
    final offset = out.length;
    u32(out, 0x04034b50);
    u16(out, 20);
    u16(out, 0);
    u16(out, deflate ? 8 : 0);
    u32(out, 0);
    u32(out, 0); // crc (not checked by the reader)
    u32(out, data.length);
    u32(out, e.value.length);
    u16(out, name.length);
    u16(out, 0);
    out.add(name);
    out.add(data);
    u32(central, 0x02014b50);
    u16(central, 20);
    u16(central, 20);
    u16(central, 0);
    u16(central, deflate ? 8 : 0);
    u32(central, 0);
    u32(central, 0);
    u32(central, data.length);
    u32(central, e.value.length);
    u16(central, name.length);
    u16(central, 0);
    u16(central, 0);
    u16(central, 0);
    u16(central, 0);
    u32(central, 0);
    u32(central, offset);
    central.add(name);
  }
  final cdOffset = out.length;
  final cd = central.takeBytes();
  out.add(cd);
  u32(out, 0x06054b50);
  u16(out, 0);
  u16(out, 0);
  u16(out, files.length);
  u16(out, files.length);
  u32(out, cd.length);
  u32(out, cdOffset);
  u16(out, 0);
  return out.takeBytes();
}

// ------------------------------------------------------------------ kernel

List<int> _kUint(int v) {
  if (v < 0x80) return [v];
  if (v < 0x4000) return [0x80 | (v >> 8), v & 0xff];
  return [0xc0 | (v >> 24), (v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff];
}

List<int> _u32be(int v) => [(v >> 24) & 0xff, (v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff];

/// A minimal, structurally valid kernel component that contains [libraries] (enough for the
/// CLI's library reader; not loadable by a Dart VM).
Uint8List makeKernel(List<String> libraries, {int extraReferencedOnly = 0}) {
  final b = BytesBuilder();
  b.add(_u32be(0x90ABCDEF));
  b.add(_u32be(138));
  b.add(List.filled(10, 0));
  final names = [...libraries, for (var i = 0; i < extraReferencedOnly; i++) 'dart:referenced_$i'];
  final libOffsets = <int>[];
  for (var i = 0; i < libraries.length; i++) {
    libOffsets.add(b.length);
    b.add([0]); // flags
    b.add(_kUint(3));
    b.add(_kUint(8));
    b.add(_kUint(i + 1)); // canonical name reference
    b.add([0, 0, 0, 0]); // filler (rest of a library is not read)
  }
  final libEnd = b.length;
  final canonOffset = b.length;
  b.add(_kUint(names.length));
  for (var i = 0; i < names.length; i++) {
    b.add(_kUint(0));
    b.add(_kUint(i));
  }
  final stringOffset = b.length;
  final encoded = names.map(utf8.encode).toList();
  b.add(_kUint(encoded.length));
  var end = 0;
  for (final e in encoded) {
    end += e.length;
    b.add(_kUint(end));
  }
  for (final e in encoded) {
    b.add(e);
  }
  while (b.length % 8 != 0) {
    b.add([0]);
  }
  final indexStart = b.length;
  for (final v in [0, 0, 0, canonOffset, 0, 0, stringOffset, indexStart, 0]) {
    b.add(_u32be(v));
  }
  for (final o in [...libOffsets, libEnd]) {
    b.add(_u32be(o));
  }
  b.add(_u32be(libraries.length));
  final size = b.length + 4;
  b.add(_u32be(size));
  return b.takeBytes();
}

// ------------------------------------------------------------------ world

/// A temp world with a fake installed toolchain, a fake Flutter app, a fake pub cache, a fake
/// global `flutter` on PATH (must never run) and a fake backend.
class ReleaseWorld {
  ReleaseWorld._(this.dir);

  final String dir;
  final out = StringBuffer();
  final err = StringBuffer();
  late FakeBackend backend;
  // The APK holds the stripped engine; the toolchain jar may hold the unstripped one (same build ID).
  final engineBytes = fakeElf(otaEngineBuildId);

  String get project => p.join(dir, 'work', 'demo_app');
  String get cacheRoot => p.join(dir, 'cache');
  String get configDir => p.join(dir, 'config');
  String get pubCache => p.join(dir, 'pub-cache');
  String get toolchainDir => p.join(cacheRoot, 'toolchains', toolchainName);
  String get flutterLog => p.join(dir, 'flutter.log');
  String get frontendLog => p.join(dir, 'frontend.log');
  String get globalMarker => p.join(dir, 'GLOBAL_FLUTTER_WAS_RUN');
  String get canonRoot => p.join(dir, 'canon');
  String get output => '$out$err';

  static Future<ReleaseWorld> create() async {
    final w = ReleaseWorld._(
      Directory.systemTemp.createTempSync('flutter_ota_release_test').resolveSymbolicLinksSync(),
    );
    w._makeToolchain();
    w._makeProject();
    w._makeGlobalFlutter();
    File(p.join(w.dir, 'kernel.dill')).writeAsBytesSync(makeKernel(fakeKernelLibraries));
    w.setApk(w.engineBytes);
    w.backend = await FakeBackend.start();
    return w;
  }

  Future<void> dispose() async {
    await backend.close();
    Directory(dir).deleteSync(recursive: true);
  }

  void _write(String path, String content, {bool exec = false}) {
    final f = File(path)..parent.createSync(recursive: true);
    f.writeAsStringSync(content);
    if (exec) Process.runSync('chmod', ['0755', path]);
  }

  void _makeToolchain() {
    final t = toolchainDir;
    final fl = p.join(t, 'flutter');
    // Fake toolchain flutter: logs args + env, then acts like pub get / build.
    _write(p.join(fl, 'bin', 'flutter'), r'''#!/bin/sh
{
  printf 'ARGS'; for a in "$@"; do printf ' [%s]' "$a"; done; printf '\n'
  printf 'PWD %s\n' "$(pwd)"
  printf 'ENV FLUTTER_STORAGE_BASE_URL=%s\n' "$FLUTTER_STORAGE_BASE_URL"
  printf 'ENV GRADLE_USER_HOME=%s\n' "$GRADLE_USER_HOME"
  printf 'ENV FLUTTER_ROOT=%s\n' "${FLUTTER_ROOT:-<unset>}"
  printf 'ENV PATH=%s\n' "$PATH"
} >> "$FAKE_FLUTTER_LOG"
if [ "$1" = "pub" ]; then
  mkdir -p .dart_tool && cp "$FAKE_PACKAGE_CONFIG" .dart_tool/package_config.json
  exit 0
fi
if [ "$1" = "build" ]; then
  [ -n "$FAKE_BUILD_FAIL" ] && { echo "gradle exploded" >&2; exit 1; }
  {
    [ -f lib/flutter_ota_main.g.dart ] && echo 'BUILT-WITH lib/flutter_ota_main.g.dart'
    [ -f .flutter_ota/packages/dynamic_modules/lib/dynamic_modules.dart ] && echo 'BUILT-WITH loader package'
    grep -q '^  dynamic_modules:' pubspec.yaml && echo 'BUILT-WITH dynamic_modules dependency'
    [ -d build ] && echo 'BUILT-WITH stale build folder'
    for f in .flutter_ota/releases/*/*; do [ -f "$f" ] && echo "BUILT-WITH $(basename "$f")"; done
  } >> "$FAKE_FLUTTER_LOG"
  if [ "$2" = "apk" ]; then
    mkdir -p build/app/outputs/flutter-apk && cp "$FAKE_APK" build/app/outputs/flutter-apk/app-release.apk
  else
    mkdir -p build/app/outputs/bundle/release && cp "$FAKE_AAB" build/app/outputs/bundle/release/app-release.aab
  fi
  echo "Built."
  exit 0
fi
exit 0
''', exec: true);
    final dartBin = p.join(fl, 'bin', 'cache', 'dart-sdk', 'bin');
    _write(p.join(dartBin, 'dart'), '#!/bin/sh\nexit 1\n', exec: true);
    // Fake front end: logs args, copies the fixture kernel to --output-dill.
    _write(p.join(dartBin, 'dartaotruntime'), r'''#!/bin/sh
{ printf 'ARGS'; for a in "$@"; do printf ' [%s]' "$a"; done; printf '\n'; printf 'PWD %s\n' "$(pwd)"; } >> "$FAKE_FRONTEND_LOG"
out=""; prev=""
for a in "$@"; do [ "$prev" = "--output-dill" ] && out="$a"; prev="$a"; done
cp "$FAKE_DILL" "$out"
''', exec: true);
    _write(frontendServerSnapshot(fl), 'snapshot');
    _write(p.join(patchedSdkProduct(fl), 'platform_strong.dill'), 'platform');
    _write(p.join(fl, 'bin', 'internal', 'engine.version'), '$engineCommit\n');
    Directory(p.join(fl, 'packages', 'flutter', 'lib')).createSync(recursive: true);
    Directory(p.join(fl, 'bin', 'cache', 'pkg', 'sky_engine', 'lib')).createSync(recursive: true);
    final jar = mirrorFilesFor(engineCommit).firstWhere((m) => m.contains('arm64_v8a_release') && m.endsWith('.jar'));
    File(p.join(t, jar))
      ..parent.createSync(recursive: true)
      ..writeAsBytesSync(
        makeZip({'lib/arm64-v8a/libflutter.so': fakeElf(otaEngineBuildId, padding: 8192)}, deflate: true),
      );
    final fields = {
      'flutter': '3.47.9',
      'dart': '3.13.7',
      'engine': engineCommit.substring(0, 8),
      'dart_revision': '416e33b0',
      'bytecode_format': 3,
      'generator_sha256': 'a' * 64,
      'engine_patch_sha256': 'b' * 64,
      'compiler_sha256': 'c' * 64,
      'build_config_sha256': 'd' * 64,
    };
    final tj = {...fields, 'id': computeToolchainId(fields)};
    _write(p.join(t, 'toolchain.json'), jsonEncode(tj));
    final files = <String, String>{};
    // The loader package shipped by the overlay (milestone 4D).
    _write(p.join(t, 'packages', 'dynamic_modules', 'pubspec.yaml'), 'name: dynamic_modules\npublish_to: none\n');
    _write(p.join(t, 'packages', 'dynamic_modules', 'lib', 'dynamic_modules.dart'), loaderSource);
    for (final rel in [
      'flutter/bin/flutter',
      'toolchain.json',
      jar,
      'flutter/bin/internal/engine.version',
      'packages/dynamic_modules/pubspec.yaml',
      'packages/dynamic_modules/lib/dynamic_modules.dart',
    ]) {
      files[rel] = sha256.convert(File(p.join(t, rel)).readAsBytesSync()).toString();
    }
    _write(
      p.join(t, 'install.json'),
      jsonEncode({
        'format': 1,
        'toolchain': toolchainName,
        'toolchain_id': tj['id'],
        'flutter': '3.47.9',
        'dart': '3.13.7',
        'engine': engineCommit,
        'dart_revision': '416e33b0ffaef062a60ec966bb8c82ed2b83f128',
        'host': 'linux-x64',
        'target': 'android-arm64',
        'files': files,
      }),
    );
  }

  String get toolchainId =>
      (jsonDecode(File(p.join(toolchainDir, 'toolchain.json')).readAsStringSync()) as Map)['id'] as String;

  void _makeProject() {
    final d = project;
    _write(p.join(d, 'flutter_ota.yaml'), 'app_id: $appId\n');
    _write(p.join(d, 'pubspec.yaml'), '''
name: demo_app
version: 1.2.0+7
environment:
  sdk: ">=3.8.0 <4.0.0"
dependencies:
  flutter:
    sdk: flutter
  flutter_ota_system: ^0.1.0-alpha.1
  feature_a:
    path: ../packages/feature_a
''');
    _write(p.join(d, 'lib', 'main.dart'), '''
import 'package:flutter/widgets.dart';
import 'package:flutter_ota_system/flutter_ota_system.dart';
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await FlutterOta.initialize();
  runApp(const SizedBox());
}
''');
    _write(p.join(d, 'android', 'app', 'build.gradle.kts'), '// fake\n');
    _write(p.join(d, '.gitignore'), '/build/\n/.flutter_ota/releases/\n');
    _write(p.join(d, 'pubspec.lock'), '# fake lock\n');
    _write(
      p.join(d, lockFileName),
      Lockfile(
        toolchain: toolchainName,
        toolchainId: toolchainId,
        flutter: '3.47.9',
        dart: '3.13.7',
        engine: engineCommit,
        dartRevision: '416e33b0ffaef062a60ec966bb8c82ed2b83f128',
      ).serialize(),
    );
    _write(p.join(dir, 'work', 'packages', 'feature_a', 'lib', 'feature_a.dart'), '// feature\n');
    final hosted = p.join(pubCache, 'hosted', 'pub.dev');
    for (final n in ['collection-1.19.1', 'flutter_ota_system-0.1.0-alpha.1']) {
      Directory(p.join(hosted, n, 'lib')).createSync(recursive: true);
    }
    final fl = p.join(toolchainDir, 'flutter');
    final cfg = {
      'configVersion': 2,
      'packages': [
        {
          'name': 'collection',
          'rootUri': 'file://$hosted/collection-1.19.1',
          'packageUri': 'lib/',
          'languageVersion': '3.4',
        },
        {'name': 'feature_a', 'rootUri': '../../packages/feature_a', 'packageUri': 'lib/', 'languageVersion': '3.8'},
        {'name': 'flutter', 'rootUri': 'file://$fl/packages/flutter', 'packageUri': 'lib/', 'languageVersion': '3.8'},
        {
          'name': 'flutter_ota_system',
          'rootUri': 'file://$hosted/flutter_ota_system-0.1.0-alpha.1',
          'packageUri': 'lib/',
          'languageVersion': '3.8',
        },
        {
          'name': 'sky_engine',
          'rootUri': 'file://$fl/bin/cache/pkg/sky_engine',
          'packageUri': 'lib/',
          'languageVersion': '3.8',
        },
        {'name': 'demo_app', 'rootUri': '../', 'packageUri': 'lib/', 'languageVersion': '3.8'},
        {'name': 'dynamic_modules', 'rootUri': '../.flutter_ota/packages/dynamic_modules', 'packageUri': 'lib/'},
        // A dev dependency: in the package config, but not in the store build's kernel.
        {'name': 'flutter_test', 'rootUri': 'file://$fl/packages/flutter_test', 'packageUri': 'lib/'},
      ],
    };
    _write(p.join(dir, 'package_config.json'), jsonEncode(cfg));
  }

  void _makeGlobalFlutter() {
    _write(p.join(dir, 'global-bin', 'flutter'), '#!/bin/sh\ntouch "$globalMarker"\nexit 0\n', exec: true);
  }

  /// The fake `flutter build` output: an APK whose libflutter.so has [engine] bytes.
  /// [extraLibs] adds more entries (for example a plugin's `lib/x86_64/libfoo.so`).
  void setApk(List<int> engine, {bool withLibapp = true, Map<String, List<int>> extraLibs = const {}}) {
    final files = {
      'AndroidManifest.xml': utf8.encode('manifest'),
      'lib/arm64-v8a/libflutter.so': engine,
      if (withLibapp) 'lib/arm64-v8a/libapp.so': utf8.encode('LIBAPP of demo_app'),
      ...extraLibs,
    };
    File(p.join(dir, 'fake.apk')).writeAsBytesSync(makeZip(files));
    File(p.join(dir, 'fake.aab')).writeAsBytesSync(makeZip({for (final e in files.entries) 'base/${e.key}': e.value}));
  }

  List<int> get libappBytes => utf8.encode('LIBAPP of demo_app');

  Map<String, String> env([Map<String, String> extra = const {}]) => {
    'HOME': p.join(dir, 'home'),
    'FLUTTER_OTA_CACHE': cacheRoot,
    'FLUTTER_OTA_CONFIG_DIR': configDir,
    'FLUTTER_OTA_BUILD_ROOT': canonRoot,
    'PUB_CACHE': pubCache,
    'PATH': '${p.join(dir, 'global-bin')}:${Platform.environment['PATH'] ?? '/usr/bin:/bin'}',
    'FLUTTER_ROOT': p.join(dir, 'global-flutter-root'),
    'FLUTTER_OTA_SERVER_URL': backend.url,
    'FLUTTER_OTA_ADMIN_KEY': adminKey,
    'FAKE_FLUTTER_LOG': flutterLog,
    'FAKE_FRONTEND_LOG': frontendLog,
    'FAKE_PACKAGE_CONFIG': p.join(dir, 'package_config.json'),
    'FAKE_APK': p.join(dir, 'fake.apk'),
    'FAKE_AAB': p.join(dir, 'fake.aab'),
    'FAKE_DILL': p.join(dir, 'kernel.dill'),
    ...extra,
  };

  Future<int> run(
    List<String> args, {
    Map<String, String> extraEnv = const {},
    Set<String> drop = const {},
    String? cwd,
  }) {
    final e = env(extraEnv)..removeWhere((k, _) => drop.contains(k));
    return runCli(
      args,
      context: CliContext(
        environment: e,
        workingDirectory: cwd ?? project,
        out: out,
        err: err,
        prompt: (_) => null,
        diskSpace: (_) async => null,
      ),
    );
  }

  List<String> flutterCalls() => File(flutterLog).existsSync()
      ? File(flutterLog).readAsLinesSync().where((l) => l.startsWith('ARGS')).toList()
      : [];
  List<String> frontendCalls() => File(frontendLog).existsSync()
      ? File(frontendLog).readAsLinesSync().where((l) => l.startsWith('ARGS')).toList()
      : [];

  /// `[a] [b]` -> ['a', 'b'].
  static List<String> parseArgs(String line) =>
      RegExp(r'\[([^\]]*)\]').allMatches(line).map((m) => m.group(1)!).toList();
}

// ------------------------------------------------------------------ backend

class Recorded {
  Recorded(this.method, this.path, this.headers, this.body);
  final String method;
  final String path;
  final HttpHeaders headers;
  final List<int> body;
  Object? get json => jsonDecode(utf8.decode(body));
}

/// A small fake of the backend admin API, enough for doctor, keys init and release.
class FakeBackend {
  FakeBackend._(this._server);

  static Future<FakeBackend> start() async {
    final s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final b = FakeBackend._(s);
    s.listen(b._handle);
    return b;
  }

  final HttpServer _server;
  final requests = <Recorded>[];
  final apps = <Map<String, Object?>>[
    {'id': appId, 'slug': appSlug, 'name': 'Demo'},
  ];
  final roots = <Map<String, Object?>>[];
  final certificates = <Map<String, Object?>>[];
  final releases = <Map<String, Object?>>[];
  bool healthy = true;

  String get url => 'http://127.0.0.1:${_server.port}';

  Future<void> close() => _server.close(force: true);

  Future<void> _handle(HttpRequest req) async {
    final body = await req.fold<List<int>>([], (a, b) => a..addAll(b));
    final path = req.uri.path;
    requests.add(Recorded(req.method, path, req.headers, body));
    void send(int code, Object? json) {
      req.response.statusCode = code;
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode(json));
      req.response.close();
    }

    if (path == '/health/live') return healthy ? send(200, {'status': 'ok'}) : send(503, {'detail': 'down'});
    if (req.headers.value('x-api-key') != adminKey) return send(401, {'detail': 'Invalid or missing X-API-Key'});
    final seg = path.split('/').where((s) => s.isNotEmpty).toList();
    // v1 admin apps ...
    if (req.method == 'GET' && path == '/v1/admin/apps') return send(200, apps);
    if (seg.length >= 4 && seg[2] == 'apps') {
      final ref = seg[3];
      final app = apps.where((a) => a['id'] == ref || a['slug'] == ref).firstOrNull;
      if (app == null) return send(404, {'detail': "Application '$ref' not found"});
      final rest = seg.sublist(4).join('/');
      if (req.method == 'GET' && rest == 'trust') {
        return send(200, {
          'application_id': app['id'],
          'roots': roots,
          'certificates': certificates,
          'revocation_lists': [],
        });
      }
      if (req.method == 'POST' && rest == 'trust/roots') {
        final j = jsonDecode(utf8.decode(body)) as Map<String, Object?>;
        final ex = roots.where((r) => r['key_id'] == j['key_id']).firstOrNull;
        if (ex != null) return ex['public_key'] == j['public_key'] ? send(200, ex) : send(409, {'detail': 'conflict'});
        final r = {'key_id': j['key_id'], 'public_key': j['public_key'], 'created_at': 'x', 'revoked_at': null};
        roots.add(r);
        return send(201, r);
      }
      if (req.method == 'POST' && rest == 'trust/certificates') {
        final j = jsonDecode(utf8.decode(body)) as Map<String, Object?>;
        final b = j['body'] as Map<String, Object?>;
        final c = {'serial': b['serial'], 'key_id': b['key_id'], 'certificate': j};
        certificates.add(c);
        return send(201, c);
      }
      if (rest == 'releases') {
        if (ref != app['slug']) return send(404, {'detail': 'release routes take the slug'});
        if (req.method == 'GET') return send(200, releases);
        final j = jsonDecode(utf8.decode(body)) as Map<String, Object?>;
        if (releases.any((r) => r['version'] == j['version'])) return send(409, {'detail': 'exists'});
        final r = {...j, 'artifacts': <Object?>[]};
        releases.add(r);
        return send(201, r);
      }
    }
    if (req.method == 'POST' && seg.length == 5 && seg[2] == 'releases' && seg[4] == 'artifacts') {
      final r = releases.where((x) => x['id'] == seg[3]).firstOrNull;
      if (r == null) return send(404, {'detail': 'Release not found'});
      final parts = parseMultipart(req.headers.contentType!, body);
      (r['artifacts'] as List).add({
        'arch': utf8.decode(parts['arch']!),
        'sha256': sha256.convert(parts['file']!).toString(),
        'size_bytes': parts['file']!.length,
      });
      return send(201, r);
    }
    send(404, {'detail': 'not found: ${req.method} $path'});
  }
}

/// Parses a multipart/form-data body into name -> bytes.
Map<String, List<int>> parseMultipart(ContentType type, List<int> body) {
  final boundary = '--${type.parameters['boundary']}';
  final text = latin1.decode(body);
  final out = <String, List<int>>{};
  for (final part in text.split(boundary)) {
    final i = part.indexOf('\r\n\r\n');
    if (i < 0) continue;
    final headers = part.substring(0, i);
    final name = RegExp(r'name="([^"]+)"').firstMatch(headers)?.group(1);
    if (name == null) continue;
    var content = part.substring(i + 4);
    if (content.endsWith('\r\n')) content = content.substring(0, content.length - 2);
    out[name] = latin1.encode(content);
  }
  return out;
}
