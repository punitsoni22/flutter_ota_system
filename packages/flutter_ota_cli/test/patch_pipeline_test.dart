// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';
import 'dart:io';

import 'package:flutter_ota_cli/flutter_ota_cli.dart';
import 'package:flutter_ota_cli/src/features/generator.dart';
import 'package:flutter_ota_cli/src/features/snapshot.dart';
import 'package:flutter_ota_cli/src/patch/commands.dart';
import 'package:flutter_ota_cli/src/patch/container.dart';
import 'package:flutter_ota_cli/src/patch/module_builder.dart';
import 'package:flutter_ota_cli/src/patch/pipeline.dart';
import 'package:flutter_ota_cli/src/patch/process.dart';
import 'package:flutter_ota_cli/src/patch/upload.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

import 'patch_support.dart';

const hostPkgs = {
  'shop',
  'core',
  'products',
  'products_data',
  'cart',
  'analytics',
  'legacy',
  'flutter_ota_system',
  'collection',
};

void main() {
  late FixtureProject f;
  late Directory tmp;
  late Map<String, String> env;
  late FakeTools tools;
  late String tc;
  late String releaseDir;
  late StringBuffer out;
  final requests = <http.Request>[];
  var serverSequence = 0;

  setUp(() {
    f = FixtureProject.create();
    tmp = Directory.systemTemp.createTempSync('flutter_ota_pipeline_test');
    tc = p.join(tmp.path, 'toolchain');
    for (final d in ['flutter/bin/cache/dart-sdk/bin', 'tools']) {
      Directory(p.join(tc, d)).createSync(recursive: true);
    }
    Directory(p.join(tmp.path, 'pub-cache')).createSync();
    env = {
      'HOME': p.join(tmp.path, 'home'),
      'FLUTTER_OTA_CONFIG_DIR': p.join(tmp.path, 'config'),
      'FLUTTER_OTA_BUILD_ROOT': p.join(tmp.path, 'canon'),
      'PUB_CACHE': p.join(tmp.path, 'pub-cache'),
      'FLUTTER_OTA_ADMIN_KEY': 'test-admin-key',
      'PATH': Platform.environment['PATH'] ?? '/usr/bin:/bin',
    };
    final keys = createTestKeys(env);
    generateFeatureRegistry(f.app);
    releaseDir = writeTestRelease(
      f.app,
      rootKeys: keys.roots,
      hostPackages: hostPkgs,
      canonicalRoot: p.join(tmp.path, 'canon'),
    );
    recordFeatureSnapshot(f.app, releaseDir);
    out = StringBuffer();
    requests.clear();
    serverSequence = 0;
    tools = FakeTools();
    _installFakeTools(tools, f);
  });
  tearDown(() {
    f.dispose();
    tmp.deleteSync(recursive: true);
  });

  PatchPipeline pipeline({bool withVerifier = true}) => PatchPipeline(
    ctx: CliContext(environment: env, workingDirectory: f.app, out: out, err: out),
    projectDir: f.app,
    tools: PatchTools(
      flutterSdk: p.join(tc, 'flutter'),
      dartAotRuntime: p.join(tc, 'flutter', 'bin', 'cache', 'dart-sdk', 'bin', 'dartaotruntime'),
      dart2bytecode: p.join(tc, 'tools', 'dart2bytecode.aot'),
      pkgRename: p.join(tc, 'tools', 'pkg_rename.aot'),
      patchGuard: p.join(tc, 'tools', 'patch_guard.aot'),
      bcVerify: withVerifier ? p.join(tc, 'tools', 'bc_verify.aot') : null,
    ),
    toolchainRoot: tc,
    toolchainId: testToolchainRecord()['id']! as String,
    processEnvironment: env,
    run: tools.call,
    clock: () => DateTime.now().toUtc(),
    serverFactory: (url, key) => PatchServer(
      url,
      key,
      MockClient((req) async {
        requests.add(req);
        expect(req.headers['X-API-Key'], 'test-admin-key');
        final path = req.url.path;
        if (req.method == 'GET' && path.endsWith('/patches')) {
          return http.Response(
            jsonEncode([
              {
                'id': 'old',
                'artifacts': [
                  {'sequence': serverSequence},
                ],
              },
            ]),
            200,
          );
        }
        if (req.method == 'POST' && path == '/v1/admin/releases/$testReleaseId/patches') {
          return http.Response(jsonEncode({'id': 'srv-1', 'number': 2, 'artifacts': []}), 201);
        }
        if (req.method == 'POST' && path == '/v1/admin/patches/srv-1/artifacts') {
          return http.Response('{"id":"srv-1"}', 201);
        }
        if (req.method == 'POST' && path == '/v1/admin/patches/srv-1/publish') {
          return http.Response('{"id":"srv-1"}', 200);
        }
        return http.Response('{"detail":"unexpected"}', 404);
      }),
    ),
  );

  void changeProducts() =>
      f.edit('packages/products/lib/products.dart', (s) => s.replaceFirst("'products: ", "'products v2: "));

  test('dry run: closure, codegen check, rename, guard, compile, verify, sign; no upload', () async {
    changeProducts();
    final r = await pipeline().execute(PatchOptions(dryRun: true));
    expect(tools.toolNames, ['flutter', 'dart', 'pkg_rename', 'patch_guard', 'dart2bytecode', 'bc_verify']);
    expect(requests, isEmpty, reason: 'a dry run never contacts the server');

    final canon = p.join(tmp.path, 'canon');
    final rename = tools.calls[2];
    expect(rename.args.sublist(1, 2), ['prepare']);
    final spec = rename.opt('--module')!;
    expect(loadYaml(File(p.join(spec, 'module.yaml')).readAsStringSync())['change'], ['cart', 'products']);
    expect(
      File(p.join(spec, 'lib', 'entry.dart')).readAsStringSync(),
      contains("'products': () => feature_products.ProductsFeature()"),
    );
    final policy = loadYaml(File(rename.opt('--policy')!).readAsStringSync()) as YamlMap;
    expect(policy['host_owned'], containsAll(['core', 'analytics', 'legacy']));

    final guard = tools.calls[3];
    expect(guard.opt('--module-packages'), 'ota_patch_1,cart_ota1,products_ota1');
    expect(guard.opt('--original-names'), 'cart_ota1=cart,products_ota1=products');
    expect(guard.opt('--host-packages'), p.join(releaseDir, 'host_packages.json'));
    expect(guard.opt('--sdk'), p.join(canon, 'toolchain', 'flutter', 'bin', 'cache', 'dart-sdk'));

    final compile = tools.calls[4];
    expect(compile.opt('--import-dill'), p.join(releaseDir, 'link.dill'));
    expect(compile.opt('--validate'), p.join(releaseDir, 'dynamic_interface.yaml'));
    expect(compile.opt('--target'), 'flutter');
    expect(compile.opt('--platform'), startsWith(p.join(canon, 'toolchain', 'flutter')));
    final cfgPath = compile.opt('--packages')!;
    expect(cfgPath, startsWith(canon));
    final cfg = jsonDecode(File(cfgPath).readAsStringSync()) as Map;
    final roots = {for (final e in cfg['packages'] as List) e['name']: e['rootUri'] as String};
    expect(
      roots.values.every((u) => Uri.parse(u).toFilePath().startsWith(canon)),
      isTrue,
      reason: 'no developer path ends up in the module',
    );
    expect(roots.keys, containsAll(['products_ota1', 'cart_ota1', 'ota_patch_1', 'core', 'products']));

    final m = r.manifest!;
    expect(m['sequence'], 1);
    expect(m['release_id'], testReleaseId);
    expect((m['module']! as Map)['entry_contract'], 3);
    expect((m['host_interface']! as Map)['host_packages'], isNot(contains('products')));
    final otp = File(r.containerPath!).readAsBytesSync();
    expect(splitContainer(otp).module, utf8.encode('BYTECODE'));
    final summary = jsonDecode(File(p.join(releaseDir, 'patches', '1', 'patch.json')).readAsStringSync()) as Map;
    expect(summary['features'], ['cart', 'products']);
    expect(summary['dry_run'], isTrue);
    expect(out.toString(), contains('Dry run: nothing was uploaded.'));
    expect(out.toString(), contains('products: generated files are up to date'));
  });

  test('upload: sequence after the server, create dbc-v1, upload container, publish', () async {
    changeProducts();
    serverSequence = 4;
    final r = await pipeline().execute(PatchOptions(channel: 'beta', rolloutPercent: 10, note: 'fix prices'));
    expect(r.uploaded, isTrue);
    expect(r.serverPatchId, 'srv-1');
    expect(r.manifest!['sequence'], 5);
    expect(requests.map((x) => '${x.method} ${x.url.path}'), [
      'GET /v1/admin/releases/$testReleaseId/patches',
      'POST /v1/admin/releases/$testReleaseId/patches',
      'POST /v1/admin/patches/srv-1/artifacts',
      'POST /v1/admin/patches/srv-1/publish',
    ]);
    expect(jsonDecode(requests[1].body), {'artifact_format': 'dbc-v1', 'note': 'fix prices'});
    expect(requests[2].headers['content-type'], startsWith('multipart/form-data'));
    expect(requests[2].bodyBytes.length, greaterThan(File(r.containerPath!).lengthSync()));
    expect(jsonDecode(requests[3].body), {'channel': 'beta', 'rollout_percent': 10});
  });

  test('shared package change is refused before any build step', () async {
    f.edit('packages/core/lib/src/money.dart', (s) => s.replaceFirst('cents', 'amount'));
    await expectLater(
      pipeline().execute(PatchOptions(dryRun: true)),
      throwsA(
        isA<CliException>()
            .having((e) => e.exitCode, 'exitCode', 3)
            .having((e) => e.message, 'message', contains('core is a shared (host-owned) package')),
      ),
    );
    expect(tools.toolNames, ['flutter']);
  });

  test('stale generated code stops the patch', () async {
    changeProducts();
    tools.handlers['dart'] = (c) {
      File(p.join(c.cwd!, 'lib', 'src', 'model.g.dart')).writeAsStringSync('// regenerated differently\n');
      return ToolResult(0, '', '');
    };
    await expectLater(
      pipeline().execute(PatchOptions(dryRun: true)),
      throwsA(isA<CliException>().having((e) => e.message, 'm', contains('generated code of products is out of date'))),
    );
    expect(tools.toolNames, isNot(contains('pkg_rename')));
  });

  test('guard rejection stops the patch (exit 4)', () async {
    changeProducts();
    tools.handlers['patch_guard'] = (c) => ToolResult(4, '', 'PATCH REJECTED\nReason: Dynamic invocation detected');
    await expectLater(
      pipeline().execute(PatchOptions(dryRun: true)),
      throwsA(isA<CliException>().having((e) => e.exitCode, 'exitCode', 4)),
    );
    expect(tools.toolNames, isNot(contains('dart2bytecode')));
  });

  test('never uploads without the reference verifier', () async {
    changeProducts();
    await expectLater(
      pipeline(withVerifier: false).execute(PatchOptions()),
      throwsA(isA<CliException>().having((e) => e.message, 'm', contains('bc_verify'))),
    );
    expect(requests.where((r) => r.method == 'POST'), isEmpty);
  });

  test('bytecode verifier rejection stops the patch', () async {
    changeProducts();
    tools.handlers['bc_verify'] = (c) => ToolResult(1, 'REJECT module.bc f pc=3: stack underflow', '');
    await expectLater(
      pipeline().execute(PatchOptions()),
      throwsA(isA<CliException>().having((e) => e.exitCode, 'e', 4)),
    );
    expect(requests.where((r) => r.method == 'POST'), isEmpty);
  });

  test('nothing changed: no patch', () async {
    final r = await pipeline().execute(PatchOptions(dryRun: true));
    expect(r.containerPath, isNull);
    expect(out.toString(), contains('Nothing to patch'));
  });

  group('toolsFor: reference verifier', () {
    late ResolvedToolchain rtc;
    late String override;
    setUp(() {
      rtc = ResolvedToolchain('test', testToolchainRecord()['id']! as String, p.join(tmp.path, 'tc_bc'));
      Directory(rtc.flutterSdk).createSync(recursive: true);
      override = p.join(tmp.path, 'own_bc_verify.aot');
      File(override).writeAsStringSync('override');
    });

    test('uses the toolchain bc_verify snapshot, even when the env override is set', () {
      File(rtc.bcVerifySnapshot)
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('shipped');
      expect(toolsFor(rtc, {bcVerifyEnv: override}).bcVerify, rtc.bcVerifySnapshot);
      expect(toolsFor(rtc, const {}).bcVerify, rtc.bcVerifySnapshot);
    });

    test('falls back to FLUTTER_OTA_BC_VERIFY only when the snapshot is missing', () {
      expect(toolsFor(rtc, {bcVerifyEnv: override}).bcVerify, override);
    });

    test('no snapshot and no override: no verifier (the pipeline then refuses to upload)', () {
      expect(toolsFor(rtc, const {}).bcVerify, isNull);
      expect(toolsFor(rtc, {bcVerifyEnv: p.join(tmp.path, 'missing.aot')}).bcVerify, isNull);
    });
  });
}

/// Fake toolchain programs that behave like the real ones at the file level.
void _installFakeTools(FakeTools tools, FixtureProject f) {
  tools.handlers['dart'] = (c) => ToolResult(0, '', ''); // build_runner: output identical
  tools.handlers['pkg_rename'] = (c) {
    final spec = c.opt('--module')!;
    final out = c.opt('--out')!;
    final y = loadYaml(File(p.join(spec, 'module.yaml')).readAsStringSync()) as YamlMap;
    final suffix = y['suffix'] as String;
    final moduleName = (loadYaml(File(p.join(spec, 'pubspec.yaml')).readAsStringSync()) as YamlMap)['name'] as String;
    final renames = <String, String>{};
    for (final pkg in (y['change'] as YamlList).cast<String>()) {
      renames[pkg] = '${pkg}_$suffix';
      copyTree(p.join(c.opt('--packages-root')!, pkg, 'lib'), p.join(out, '${pkg}_$suffix', 'lib'));
    }
    copyTree(p.join(spec, 'lib'), p.join(out, moduleName, 'lib'));
    File(
      p.join(out, 'rename_report.json'),
    ).writeAsStringSync(jsonEncode({'module': moduleName, 'renames': renames, 'notes': []}));
    return ToolResult(0, '', '');
  };
  tools.handlers['patch_guard'] = (c) {
    File(c.opt('--json')!).writeAsStringSync(jsonEncode({'accepted': true, 'analysis_errors': 0, 'findings': []}));
    return ToolResult(0, 'patch_guard: accepted', '');
  };
  tools.handlers['dart2bytecode'] = (c) {
    File(c.opt('-o')!).writeAsStringSync('BYTECODE');
    return ToolResult(0, '', '');
  };
  tools.handlers['bc_verify'] = (c) => ToolResult(0, 'OK ${c.args.last} functions=3 instructions=40\n', '');
}
