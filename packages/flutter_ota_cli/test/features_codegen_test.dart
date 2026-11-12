// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:flutter_ota_cli/flutter_ota_cli.dart';
import 'package:flutter_ota_cli/src/features/codegen_check.dart';
import 'package:flutter_ota_cli/src/features/package_graph.dart';
import 'package:flutter_ota_cli/src/patch/process.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'patch_support.dart';

void main() {
  late FixtureProject f;
  late FakeTools tools;
  setUp(() {
    f = FixtureProject.create();
    tools = FakeTools();
  });
  tearDown(() => f.dispose());

  CodegenChecker checker() => CodegenChecker(
    project: ProjectPackages.load(f.app),
    dartBin: '/toolchain/dart',
    flutterSdk: '/toolchain/flutter',
    run: tools.call,
    workDir: p.join(f.root, 'work'),
    environment: const {},
  );

  /// Fake build_runner: writes [generated] as model.g.dart into the clean copy.
  void fakeBuildRunner(String generated) {
    tools.handlers['dart'] = (c) {
      expect(c.args, ['run', 'build_runner', 'build', '--delete-conflicting-outputs']);
      // The clean copy keeps the project layout and the pub state.
      expect(File(p.join(c.cwd!, 'pubspec.yaml')).existsSync(), isTrue);
      expect(File(p.join(c.cwd!, '..', '..', '.dart_tool', 'package_config.json')).existsSync(), isTrue);
      expect(p.isWithin(f.app, c.cwd!), isFalse, reason: 'never runs in the developer project');
      File(p.join(c.cwd!, 'lib', 'src', 'model.g.dart')).writeAsStringSync(generated);
      return ToolResult(0, '', '');
    };
  }

  String current() => File(p.join(f.pkg('products'), 'lib', 'src', 'model.g.dart')).readAsStringSync();

  test('fresh generated code passes and is cached', () async {
    fakeBuildRunner(current());
    final pkg = ProjectPackages.load(f.app).local['products']!;
    expect(await checker().staleFiles(pkg), isEmpty);
    expect(tools.calls, hasLength(1));
    expect(await checker().staleFiles(pkg), isEmpty);
    expect(tools.calls, hasLength(1), reason: 'unchanged inputs are not regenerated');
    expect(Directory(p.join(f.root, 'work')).listSync(), isEmpty, reason: 'the clean copy is removed');
  });

  test('stale generated code is detected (changed JSON key, generator not re-run)', () async {
    f.edit(
      'packages/products/lib/src/model.dart',
      (s) => s.replaceFirst('final String name;', "@JsonKey(name: 'title')\n  final String name;"),
    );
    fakeBuildRunner(current().replaceFirst("'name'", "'title'"));
    final pkg = ProjectPackages.load(f.app).local['products']!;
    expect(await checker().staleFiles(pkg), ['lib/src/model.g.dart']);
    expect(current(), contains("'name'"), reason: 'the developer files are never changed');
  });

  test('build_runner failure is reported with the command to run', () async {
    tools.handlers['dart'] = (c) => ToolResult(1, '', 'Could not find freezed');
    final pkg = ProjectPackages.load(f.app).local['products']!;
    await expectLater(
      checker().staleFiles(pkg),
      throwsA(
        isA<CliException>().having(
          (e) => e.message,
          'm',
          allOf(contains('Could not find freezed'), contains('build_runner build')),
        ),
      ),
    );
  });

  test('packages without build_runner are not checked', () async {
    final pkg = ProjectPackages.load(f.app).local['cart']!;
    expect(await checker().staleFiles(pkg), isEmpty);
    expect(tools.calls, isEmpty);
  });

  test('freezed older than 4.0.3 is refused', () {
    f.edit('packages/products/pubspec.yaml', (s) => '$s  freezed: ^3.2.5\n');
    final pkg = ProjectPackages.load(f.app).local['products']!;
    final lock = p.join(f.app, 'pubspec.lock');
    expect(codegenVersionProblems(pkg, lock), isEmpty);
    File(lock).writeAsStringSync('packages:\n  freezed:\n    source: hosted\n    version: "3.2.5"\n');
    expect(codegenVersionProblems(pkg, lock).single, contains('freezed >= 4.0.3'));
    File(lock).writeAsStringSync('packages:\n  freezed:\n    source: hosted\n    version: "4.0.3"\n');
    expect(codegenVersionProblems(pkg, lock), isEmpty);
  });
}
