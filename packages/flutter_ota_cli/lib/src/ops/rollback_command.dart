// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

import 'package:args/command_runner.dart';

import '../context.dart';
import '../errors.dart';
import '../server/admin_client.dart';
import 'project_server.dart';

/// `flutter_ota rollback`: marks one published patch as rolled back on the server. Nothing is
/// deleted; the patch can be published again later.
class RollbackCommand extends Command<int> {
  RollbackCommand(this.ctx) {
    argParser
      ..addOption('release', help: 'Release id (UUID). Default: the newest local release.')
      ..addOption('patch', help: 'Patch number to roll back. Default: the highest-numbered published patch.')
      ..addOption(
        'reason',
        help:
            'Why you roll back. Printed with the summary only: the server API has no reason field, '
            'so it is not stored.',
      )
      ..addFlag('yes', abbr: 'y', negatable: false, help: 'Do not ask for confirmation (for CI).');
  }

  final CliContext ctx;

  @override
  String get name => 'rollback';
  @override
  String get description =>
      'Roll back a published patch of a store release. Devices that run it go back to the patch they '
      'ran before it (if they still have it), or to the store code, at their next start. Deletes nothing.';

  @override
  Future<int> run() async {
    final a = argResults!;
    int? number;
    final rawPatch = a['patch'] as String?;
    if (rawPatch != null) {
      number = int.tryParse(rawPatch.trim());
      if (number == null || number < 1) usageException('--patch must be a patch number (1, 2, 3, ...).');
    }
    final reason = (a['reason'] as String?)?.trim();

    final project = OpsProject.load(ctx, releaseId: a['release'] as String?, requireRelease: true);
    final release = project.release!;
    if (release.registered == null) {
      throw CliException(
        'Release ${release.releaseId} was never registered on a server, so it has no patches to roll back.',
      );
    }
    final url = resolveOpsServerUrl(ctx, release);
    final client = opsClient(ctx, url);
    try {
      final List<Map<String, Object?>> patches;
      try {
        patches = await client.listPatches(release.releaseId);
      } on ServerException catch (e) {
        if (e.statusCode != 404) rethrow;
        throw CliException('The server $url does not know release ${release.releaseId} (HTTP 404).');
      }
      final published = patches.where((pt) => pt['status'] == 'published').toList()
        ..sort((x, y) => patchNumber(x).compareTo(patchNumber(y)));

      final Map<String, Object?> target;
      if (number != null) {
        final found = patches.where((pt) => patchNumber(pt) == number).firstOrNull;
        if (found == null) {
          final known = patches.map(patchNumber).toList()..sort();
          throw CliException(
            'Release ${release.releaseId} has no patch $number on the server. '
            '${known.isEmpty ? 'It has no patches.' : 'Its patches are: ${known.join(', ')}.'}',
          );
        }
        target = found;
      } else {
        if (published.isEmpty) {
          throw CliException(
            'Release ${release.releaseId} has no published patch, so there is nothing to roll back. '
            'Nothing was changed. See `flutter_ota status`.',
          );
        }
        target = published.last;
      }

      final n = patchNumber(target);
      final status = target['status'];
      if (status != 'published') {
        final why = switch (status) {
          'rolled_back' => 'it is already rolled back',
          'draft' => 'it is a draft that was never published',
          'revoked' => 'it is revoked (it can never run again)',
          _ => 'its status is "$status"',
        };
        throw CliException('Patch $n is not published: $why. Nothing was changed.');
      }

      final others = published.where((pt) => patchNumber(pt) != n).toList();
      final o = ctx.out;
      o.writeln('Release:  ${release.releaseId} (version ${release.version ?? '?'})');
      o.writeln('Patch:    $n  (id ${target['id']}, ${target['artifact_format']})');
      o.writeln('Channels: ${channelsText(target)}');
      if (reason != null && reason.isNotEmpty) {
        o.writeln('Reason:   $reason  (shown here only; the server does not store a reason)');
      }
      o.writeln('');
      o.writeln('What happens:');
      o.writeln('  - The server marks patch $n as rolled_back. Nothing is deleted.');
      if (others.isEmpty) {
        o.writeln('  - Devices that run patch $n go back to the store code (no patch) at their next start.');
      } else {
        o.writeln(
          '  - Devices that run patch $n go back to the patch they ran before it, if they still have it '
          '(published now: ${others.map(patchNumber).join(', ')}), or to the store code, at their next start. '
          'They never download an older patch again (replay protection): ship a fix as a new patch.',
        );
      }
      o.writeln('  - You can publish patch $n again later:  ota patch publish ${target['id']} --channel <channel>');
      o.writeln('');

      if (a['yes'] != true) {
        final answer = ctx.prompt('Roll back patch $n? [y/N] ');
        if (answer == null) {
          throw CliException(
            'Confirmation needed, but there is no interactive terminal. Nothing was changed. '
            'Re-run with --yes.',
          );
        }
        if (!const {'y', 'yes'}.contains(answer.trim().toLowerCase())) {
          o.writeln('Cancelled. Nothing was changed.');
          return 1;
        }
      }

      final Map<String, Object?> result;
      try {
        result = await client.rollbackPatch(target['id'] as String);
      } on ServerException catch (e) {
        if (e.statusCode == 409) {
          throw CliException('The server refused the rollback: ${e.message}\nNothing was changed.');
        }
        rethrow;
      }
      o.writeln('Patch $n is now ${result['status']}. Devices stop using it at their next start.');
      o.writeln('Check with:  flutter_ota status');
      return 0;
    } finally {
      client.close();
    }
  }
}
