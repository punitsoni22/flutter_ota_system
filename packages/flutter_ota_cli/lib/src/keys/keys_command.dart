// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

import 'package:args/command_runner.dart';

import '../context.dart';
import '../errors.dart';
import '../release/app_project.dart';
import '../server/admin_client.dart';
import '../server/app_state.dart';
import 'key_store.dart';

/// `flutter_ota keys`: the app's signing keys (root + certified signer), kept on this machine.
class KeysCommand extends Command<int> {
  KeysCommand(CliContext ctx) {
    addSubcommand(_KeysInit(ctx));
    addSubcommand(_KeysList(ctx));
  }

  @override
  String get name => 'keys';
  @override
  String get description => 'Create and register the app signing keys (private keys never leave this machine).';
}

class _KeysInit extends Command<int> {
  _KeysInit(this.ctx) {
    argParser
      ..addOption('environment', defaultsTo: defaultEnvironment, help: 'Trust environment of the signer certificate.')
      ..addOption('validity-days', defaultsTo: '365', help: 'How long the signer certificate is valid.')
      ..addOption('server-url', help: 'Override the configured server URL for this run.');
  }

  final CliContext ctx;

  @override
  String get name => 'init';
  @override
  String get description =>
      'Create a root key and a certified signer key for this app (if missing) and register the PUBLIC '
      'root key and the certificate with the server. Safe to run again.';

  @override
  Future<int> run() async {
    final env = validateEnvironment(argResults!['environment'] as String);
    final days = int.tryParse(argResults!['validity-days'] as String);
    if (days == null || days < 1 || days > 3650) throw CliException('--validity-days must be 1..3650.');
    final (_, appId) = requireProject(ctx.workingDirectory);
    final client = AdminClient.fromContext(ctx, serverUrlFlag: argResults!['server-url'] as String?);
    try {
      final health = await client.health();
      if (health != null) throw CliException('The server ${client.baseUrl} is not reachable ($health).');
      final server = await fetchAppState(client, appId);
      final store = AppKeyStore.forApp(ctx.environment, appId);

      var roots = store.rootPublicKeys();
      if (roots.isEmpty) {
        final id = store.createRoot();
        ctx.out.writeln('Created root key $id.');
        roots = store.rootPublicKeys();
      }
      for (final e in roots.entries) {
        if (server.revokedRoots.contains(e.key)) {
          ctx.log('warning: root key ${e.key} is revoked on the server; it is not registered again.');
          continue;
        }
        final remote = server.activeRoots[e.key];
        if (remote != null && remote != e.value) {
          throw CliException('The server has a DIFFERENT public key for root ${e.key}. Stop and check.');
        }
        await client.registerRoot(appId, e.key, e.value);
        ctx.out.writeln('Root key ${e.key} is registered (public key only).');
      }

      var signer = store.activeSigner(env, DateTime.now());
      if (signer == null) {
        final rootId = roots.keys.firstWhere(
          (id) => store.hasRootPrivateKey(id) && !server.revokedRoots.contains(id),
          orElse: () => throw CliException(
            'No usable root private key on this machine to certify a new signer key.\n'
            'Run this command where the root key is kept.',
          ),
        );
        signer = store.createSigner(
          rootKeyId: rootId,
          environment: env,
          validity: Duration(days: days),
        );
        ctx.out.writeln('Created signer key ${signer.keyId} (certificate serial ${signer.serial}, environment $env).');
      }
      await client.uploadCertificate(appId, signer.certificate);
      ctx.out.writeln('Signer certificate ${signer.serial} is registered (valid until ${signer.body['not_after']}).');
      ctx.out.writeln('''

Keys folder: ${store.dir}
  roots/*.key    ROOT private key. Back it up offline (for example an encrypted USB stick).
                 It is only needed to certify new signer keys or to revoke keys.
  signers/*.key  signer private key, used by `flutter_ota patch android` on this machine.
Never copy these .key files into your project, a repository or a chat.''');
      return 0;
    } finally {
      client.close();
    }
  }
}

class _KeysList extends Command<int> {
  _KeysList(this.ctx);

  final CliContext ctx;

  @override
  String get name => 'list';
  @override
  String get description => 'Show the keys on this machine for the current app (no server needed).';

  @override
  Future<int> run() async {
    final (_, appId) = requireProject(ctx.workingDirectory);
    final store = AppKeyStore.forApp(ctx.environment, appId);
    ctx.out.writeln('Keys folder: ${store.dir}');
    final roots = store.rootPublicKeys();
    ctx.out.writeln('Root keys: ${roots.isEmpty ? '(none; run flutter_ota keys init)' : ''}');
    for (final id in roots.keys) {
      ctx.out.writeln('  $id${store.hasRootPrivateKey(id) ? '  (private key on this machine)' : '  (public only)'}');
    }
    final signers = store.signers();
    ctx.out.writeln('Signer keys: ${signers.isEmpty ? '(none)' : ''}');
    final now = DateTime.now();
    for (final s in signers) {
      final state = now.isBefore(s.notAfter) ? 'valid until ${s.body['not_after']}' : 'EXPIRED ${s.body['not_after']}';
      ctx.out.writeln('  ${s.keyId}  serial ${s.serial}  ${s.environment}  root ${s.rootKeyId}  $state');
    }
    return 0;
  }
}
