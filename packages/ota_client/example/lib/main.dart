// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

// Minimal use of the Flutter OTA System client. Replace the placeholders with your own server's
// values (see README.md). It compiles and runs without a server: the check then reports `failed`.

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_ota_system/flutter_ota_system.dart';

final ota = OtaClient(
  OtaConfig(
    // Your Flutter OTA System server.
    serverUrl: 'https://ota.example.com',
    // The app's slug: `ota app create my-app "My App"`.
    appSlug: 'my-app',
    // The app's server id: "id" in `ota app list` (not the Android package name).
    applicationId: '00000000-0000-0000-0000-000000000000',
    // This build's version+build number, exactly as registered on the server.
    releaseVersion: '1.0.0+1',
    // {'<key id>': '<base64 point>'} from `ota key show --dart`. Empty: every patch is refused.
    publicKeys: const {},
    // Inert data patches. AotPatchRuntime() runs Android code patches (experimental).
    runtime: MockPatchRuntime(),
  ),
);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Before runApp: picks the store build, the last good patch, or a new one.
  await ota.boot();
  runApp(const ExampleApp());
  // Confirms that a new patch starts correctly.
  ota.markBootSuccessfulAfterFirstFrame();
}

class ExampleApp extends StatefulWidget {
  const ExampleApp({super.key});

  @override
  State<ExampleApp> createState() => _ExampleAppState();
}

class _ExampleAppState extends State<ExampleApp> {
  String _status = 'Not checked yet';

  Future<void> _check() async {
    final result = await ota.checkForUpdate(force: true); // never throws
    setState(
      () => _status = result.status == UpdateStatus.stagedRestartRequired
          ? 'Patch ${result.patchNumber} ready: restart the app to use it'
          : '$result',
    );
  }

  // Plain widgets only (no Material dependency): this example is about the OTA calls, not UI.
  @override
  Widget build(BuildContext context) => Directionality(
    textDirection: TextDirection.ltr,
    child: DefaultTextStyle(
      style: const TextStyle(fontSize: 16, color: Color(0xFF000000)),
      child: ColoredBox(
        color: const Color(0xFFFFFFFF),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Running: ${ota.activePatch == null ? 'store build' : 'patch #${ota.activePatchNumber}'}',
                ),
                const SizedBox(height: 8),
                Text(_status),
                const SizedBox(height: 16),
                GestureDetector(
                  onTap: _check,
                  child: const ColoredBox(
                    color: Color(0xFF1565C0),
                    child: Padding(
                      padding: EdgeInsets.all(12),
                      child: Text(
                        'Check for update',
                        style: TextStyle(color: Color(0xFFFFFFFF)),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
