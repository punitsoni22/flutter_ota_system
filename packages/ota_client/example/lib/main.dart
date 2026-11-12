// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

// The official Flutter OTA System demo app. It shows the whole client flow:
//
//  1. Initialise: create an OtaClient with your server, app and public key (below).
//  2. Registration: the client registers this installation with the server on its first check.
//  3. Check: checkForUpdate() asks the server whether a patch exists for this release.
//  4. Download and verify: the client checks the ES256 signature, the size and the SHA-256
//     before it stages a patch. A refused patch is reported as `rejected`.
//  5. Activate: a staged patch runs after the next app restart (boot()).
//  6. Confirm: markBootSuccessfulAfterFirstFrame() confirms that the patch started correctly.
//  7. Rollback: a patch that does not confirm its start (see the `crash` test hook below), or a
//     patch rolled back or revoked on the server, is replaced by the last good code.
//  8. Errors: checkForUpdate() never throws; it returns a status and a message.
//
// This demo uses MockPatchRuntime: a patch is a signed JSON file that changes the banner text
// and the colour. No code is downloaded. AotPatchRuntime() runs experimental Android Dart code
// patches instead. See README.md for how to run it against the local server.

import 'dart:convert';
import 'dart:io';

// Deprecated from Flutter 3.47 (replacement: package:material_ui), but kept so this demo also
// builds with Flutter 3.44.9, the SDK's minimum supported version.
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter_ota_system/flutter_ota_system.dart';
import 'package:package_info_plus/package_info_plus.dart';

// Set with --dart-define, see README.md and docs/configuration.md. The defaults match the local
// demo stack (`./flutter-ota-system.sh demo`) on an Android emulator.
const _serverUrl = String.fromEnvironment('OTA_SERVER_URL', defaultValue: 'http://10.0.2.2:8000');
const _appSlug = String.fromEnvironment('OTA_APP', defaultValue: 'flutter-ota-system-demo');
const _channel = String.fromEnvironment('OTA_CHANNEL', defaultValue: 'dev');
// "<key_id>:<base64 point>" from `ota key show`. Empty: every patch is refused.
const _publicKey = String.fromEnvironment('OTA_PUBLIC_KEY');
// The application's server id ("id" in `ota app list`), not the Android package name.
const _applicationId = String.fromEnvironment('OTA_APPLICATION_ID');

final _runtime = MockPatchRuntime();
late final OtaClient ota;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final info = await PackageInfo.fromPlatform();
  final keyParts = _publicKey.split(':');

  ota = OtaClient(OtaConfig(
    serverUrl: _serverUrl,
    appSlug: _appSlug,
    // Without OTA_APPLICATION_ID every response is refused ('application id mismatch').
    applicationId: _applicationId.isEmpty ? 'not-set' : _applicationId,
    channel: _channel,
    // This build's version+build number, exactly as registered on the server.
    releaseVersion: '${info.version}+${info.buildNumber}',
    publicKeys: keyParts.length == 2 ? {keyParts[0]: keyParts[1]} : const {},
    runtime: _runtime,
  ));
  // Before runApp: picks the store build, the last good patch, or a newly staged one.
  await ota.boot();

  final config = _patchConfig();
  // Test hook: a patch with {"crash": true} kills the app on start, like a broken patch would.
  // The next start must come back on the previous good code.
  if (config['crash'] == true) exit(1);

  runApp(DemoApp(config: config));
  ota.markBootSuccessfulAfterFirstFrame(stableFor: const Duration(seconds: 5));
  ota.checkForUpdate(); // background, never blocks startup
}

/// With the mock runtime, a patch is a JSON config. The store build has an empty one.
Map<String, dynamic> _patchConfig() {
  final bytes = _runtime.activePayload;
  if (bytes == null) return const {};
  try {
    return jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
  } catch (_) {
    return const {};
  }
}

class DemoApp extends StatelessWidget {
  const DemoApp({super.key, required this.config});
  final Map<String, dynamic> config;

  @override
  Widget build(BuildContext context) {
    final color = Color(int.tryParse('${config['color'] ?? ''}'.replaceFirst('#', 'FF'), radix: 16) ?? 0xFF607D8B);
    return MaterialApp(
      title: 'OTA demo',
      theme: ThemeData(colorSchemeSeed: color),
      home: HomePage(config: config),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.config});
  final Map<String, dynamic> config;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  String _status = 'Checking in the background…';
  bool _busy = false;

  Future<void> _check() async {
    setState(() => _busy = true);
    final result = await ota.checkForUpdate(force: true); // never throws
    setState(() {
      _busy = false;
      _status = switch (result.status) {
        UpdateStatus.upToDate => 'Up to date',
        UpdateStatus.stagedRestartRequired => 'Patch ${result.patchNumber} ready. Close and reopen the app.',
        UpdateStatus.rollbackRestartRequired => 'Current patch was rolled back. Close and reopen the app.',
        UpdateStatus.rejected => 'Refused: ${result.message}',
        UpdateStatus.failed => 'Failed: ${result.message}',
      };
    });
  }

  @override
  Widget build(BuildContext context) {
    final patch = ota.activePatch;
    final text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('OTA demo')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(widget.config['banner']?.toString() ?? 'Store build (no patch)', style: text.headlineSmall),
          const SizedBox(height: 24),
          _row('Release', ota.config.releaseVersion),
          _row('Channel', ota.config.channel),
          _row('Active patch', patch == null ? 'none' : '#${patch.number}'),
          _row('Installation', ota.installationId),
          _row('Server', ota.config.serverUrl),
          if (_publicKey.isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 16),
              child: Text('OTA_PUBLIC_KEY not set: every patch will be refused.',
                  style: TextStyle(color: Colors.red)),
            ),
          if (_applicationId.isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 16),
              child: Text('OTA_APPLICATION_ID not set: every update check will be refused.',
                  style: TextStyle(color: Colors.red)),
            ),
          const SizedBox(height: 24),
          Text(_status),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: _busy ? null : _check,
            child: Text(_busy ? 'Checking…' : 'Check for update now'),
          ),
        ],
      ),
    );
  }

  Widget _row(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(width: 110, child: Text(label, style: const TextStyle(fontWeight: FontWeight.bold))),
            Expanded(child: SelectableText(value)),
          ],
        ),
      );
}
