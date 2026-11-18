#!/usr/bin/env python3
# Copyright 2026 The Punit Authors
# SPDX-License-Identifier: Apache-2.0
"""Shot 1 / 1b: local proof of adaptive OTA patch levels with the real Dart AOT compiler.

Steps (all output goes to ./out, nothing else is touched):
  1. Build the test app with the real AOT compiler (dart compile exe):
       v1_plain     store build without OTA
       v1_instr     store build with redirect checks (+ vm:entry-point markers)
       v1_nopragma  same checks without markers (control for the optimizer test)
       v1_noleaf    store build in fast mode (tiny leaf functions without a check)
       patched_*    a store build + the generated patch in three modes: normal, fast, critical
                    (slots filled at start-up, which simulates loading the patch module)
       v2           the real new version (oracle)
  2. Correctness: v1_instr must equal v1_plain; every patched build must equal v2.
  3. Optimizer (H2): count redirect checks that survive AOT optimization, with and without
     markers, by printing the optimized IL of every app function.
  4. Cost: interleaved benchmarks of store-build variants and dynamic-interface variants.
  5. Size: executable and snapshot sizes.
Writes out/shot1_report.md and out/shot1_results.json.

Usage: python3 run_shot1.py [--dart /path/to/dart]
"""
import json
import os
import re
import shutil
import statistics
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(ROOT, 'out')
DART = sys.argv[sys.argv.index('--dart') + 1] if '--dart' in sys.argv else shutil.which('dart')
SDK = os.path.dirname(os.path.dirname(os.path.realpath(DART)))
if not os.path.isdir(os.path.join(SDK, 'lib', '_internal')):  # flutter/bin/dart wrapper
    SDK = os.path.join(os.path.dirname(os.path.realpath(DART)), 'cache', 'dart-sdk')

# Entry point of a patched build: fill the slots, then run the unchanged app (or, for a
# whole-app patch, the copy's own main).
MAIN_PATCHED = '''import 'package:app/ota_patch/install.dart';

import 'main.dart' as app;

Future<void> main(List<String> args) async {
  otaInstall();
  final m = otaMain;
  if (m != null) {
    await m(args);
  } else {
    await app.main(args);
  }
}
'''


def run(cmd, cwd=None, check=True):
    r = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True)
    if check and r.returncode != 0:
        print('FAILED:', ' '.join(cmd), '\n', r.stdout[-3000:], r.stderr[-3000:])
        sys.exit(1)
    return r


def log(msg):
    print(f'[{time.strftime("%H:%M:%S")}] {msg}', flush=True)


def copy_pkg(src, name):
    dst = os.path.join(OUT, name)
    shutil.rmtree(dst, ignore_errors=True)
    shutil.copytree(src, dst, ignore=shutil.ignore_patterns('.dart_tool', 'build'))
    run([DART, 'pub', 'get'], cwd=dst)
    return dst


def tool(*args):
    return run([DART, 'run', os.path.join(ROOT, 'tool', 'bin', 'ota_redirect.dart'), *args])


def compile_exe(pkg, entry='bin/main.dart'):
    exe = os.path.join(pkg, 'app.exe')
    run([DART, 'compile', 'exe', entry, '-o', exe], cwd=pkg)
    return exe


def results(exe):
    r = run([exe])
    return dict(line.split('\t', 1) for line in r.stdout.strip().splitlines())


def surviving_checks(pkg):
    """Distinct redirect slots still loaded in the optimized IL of all app functions."""
    dill = os.path.join(pkg, 'app.dill')
    run([os.path.join(SDK, 'bin', 'dartaotruntime'),
         os.path.join(SDK, 'bin', 'snapshots', 'gen_kernel_aot.dart.snapshot'),
         '--platform', os.path.join(SDK, 'lib', '_internal', 'vm_platform_product.dill'),
         '--aot', '--tfa', '--packages', os.path.join(pkg, '.dart_tool', 'package_config.json'),
         '-o', dill, os.path.join(pkg, 'bin', 'main.dart')])
    r = run([os.path.join(SDK, 'bin', 'utils', 'gen_snapshot'), '--snapshot_kind=app-aot-assembly',
             '--assembly=' + os.path.join(pkg, 'app.S'), '--print_flow_graph_optimized',
             '--print_flow_graph_filter=package:app/', dill])
    il = r.stdout + r.stderr
    loaded = set(re.findall(r'LoadStaticField\((ota\$s[0-9a-f]+)\)', il))
    return loaded


def aot_snapshot(pkg, name, iface=None):
    """Manual AOT pipeline (kernel + optimizer + snapshot), optionally with a dynamic interface."""
    dill = os.path.join(OUT, f'{name}.dill')
    aot = os.path.join(OUT, f'{name}.aot')
    cmd = [os.path.join(SDK, 'bin', 'dartaotruntime'),
           os.path.join(SDK, 'bin', 'snapshots', 'gen_kernel_aot.dart.snapshot'),
           '--platform', os.path.join(SDK, 'lib', '_internal', 'vm_platform_product.dill'),
           '--aot', '--tfa', '--packages', os.path.join(pkg, '.dart_tool', 'package_config.json'),
           '-o', dill, os.path.join(pkg, 'bin', 'main.dart')]
    if iface:
        cmd.insert(4, f'--dynamic-interface={iface}')
    run(cmd)
    run([os.path.join(SDK, 'bin', 'utils', 'gen_snapshot'), '--snapshot_kind=app-aot-elf',
         f'--elf={aot}', dill])
    return aot


def write_interface(name, sections, pkg_dir):
    libs = sorted('package:app/' + os.path.relpath(os.path.join(dp, f), os.path.join(pkg_dir, 'lib'))
                  for dp, _, fs in os.walk(os.path.join(pkg_dir, 'lib')) for f in fs
                  if f.endswith('.dart') and 'ota_patch' not in dp)
    sdk = ['dart:async', 'dart:collection', 'dart:convert', 'dart:core', 'dart:developer',
           'dart:io', 'dart:isolate', 'dart:math', 'dart:typed_data']
    groups = {'app': libs, 'sdk': sdk, 'all': sdk + libs}
    path = os.path.join(OUT, f'iface_{name}.yaml')
    with open(path, 'w') as f:
        for sec, group in sections:
            f.write(f'{sec}:\n' + ''.join(f"  - library: '{l}'\n" for l in groups[group]))
    return path


def bench_matrix(snapshots, rounds=7):
    """Interleaved runs; the minimum per benchmark filters background noise."""
    times = {}
    for _ in range(rounds):
        for label, aot in snapshots.items():
            r = run([os.path.join(SDK, 'bin', 'dartaotruntime'), aot, 'bench'])
            for line in r.stdout.splitlines():
                parts = line.split('\t')
                if parts[0] == 'bench':
                    times.setdefault(label, {}).setdefault(parts[1], []).append(int(parts[2]))
    return {label: {k: min(v) for k, v in t.items()} for label, t in times.items()}


def main():
    log(f'dart: {DART}  sdk: {SDK}')
    log(run([DART, '--version']).stdout.strip() or run([DART, '--version']).stderr.strip())
    os.makedirs(OUT, exist_ok=True)
    run([DART, 'pub', 'get'], cwd=os.path.join(ROOT, 'tool'))

    log('prepare variants')
    v1 = os.path.join(ROOT, 'cases', 'v1')
    v2 = os.path.join(ROOT, 'cases', 'v2')
    plain = copy_pkg(v1, 'v1_plain')
    instr = copy_pkg(v1, 'v1_instr')
    instr_out = tool('instrument', instr).stdout.strip()
    nopragma = copy_pkg(v1, 'v1_nopragma')
    tool('instrument', nopragma, '--no-pragma')
    noleaf = copy_pkg(v1, 'v1_noleaf')
    noleaf_out = tool('instrument', noleaf, '--skip-leaves').stdout.strip()
    modes = {
        'normal': (instr, []),
        'fast (tiny leaves without a check)': (noleaf, []),
        'critical (whole-app copy)': (instr, ['--critical']),
    }
    patched, patch_out = {}, {}
    for i, (mode, (base, flags)) in enumerate(modes.items()):
        pkg = copy_pkg(base, f'patched_{i}')
        patch_out[mode] = tool('patch', v1, v2, pkg, *flags).stdout
        with open(os.path.join(pkg, 'bin', 'main_patched.dart'), 'w') as f:
            f.write(MAIN_PATCHED)
        patched[mode] = pkg
    oracle = copy_pkg(v2, 'v2')

    log('compile AOT executables')
    exes = {
        'v1_plain': compile_exe(plain),
        'v1_instr': compile_exe(instr),
        'v1_nopragma': compile_exe(nopragma),
        'v2': compile_exe(oracle),
    }
    for mode, pkg in patched.items():
        exes[mode] = compile_exe(pkg, 'bin/main_patched.dart')

    log('run all cases (AOT)')
    res = {k: results(v) for k, v in exes.items()}
    cases = list(res['v2'].keys())
    instr_same = all(res['v1_plain'][c] == res['v1_instr'][c] for c in cases)
    rows = []
    summary = {m: {'match': 0, 'differ': []} for m in patched}
    for c in cases:
        row = [c, res['v1_plain'][c], res['v2'][c]]
        for m in patched:
            ok = res[m][c] == res['v2'][c]
            row.append(res[m][c] if not ok else '= v2')
            if ok:
                summary[m]['match'] += 1
            else:
                summary[m]['differ'].append(c)
        rows.append(row)

    log('optimizer check (H2)')
    with open(os.path.join(instr, 'ota_manifest.json')) as f:
        all_slots = {v['slot'] for v in json.load(f)['slots'].values()}
    kept_pragma = surviving_checks(instr)
    kept_nopragma = surviving_checks(nopragma)

    log('performance variants (this takes several minutes)')
    full = [('callable', 'all'), ('can-be-used-as-type', 'all'), ('extendable', 'all'),
            ('can-be-overridden', 'all')]
    app_callable = [('callable', 'app'), ('can-be-used-as-type', 'app')]
    sdk_callable = [('callable', 'sdk'), ('can-be-used-as-type', 'sdk')]
    variants = {
        'plain store build (no OTA)': aot_snapshot(plain, 'p_plain'),
        'checks in every function': aot_snapshot(instr, 'p_checks'),
        'checks, tiny leaves skipped': aot_snapshot(noleaf, 'p_noleaf'),
        'plain + interface: everything, all 4 sections (policy 2)':
            aot_snapshot(plain, 'p_iface_full', write_interface('full', full, plain)),
        'plain + interface: SDK callable/type only':
            aot_snapshot(plain, 'p_iface_sdk', write_interface('sdk', sdk_callable, plain)),
        'plain + interface: app callable/type only':
            aot_snapshot(plain, 'p_iface_app', write_interface('app', app_callable, plain)),
        'checks (leaves skipped) + app callable/type interface':
            aot_snapshot(noleaf, 'p_noleaf_app', write_interface('app2', app_callable, noleaf)),
    }
    perf = bench_matrix(variants)
    with open(os.path.join(noleaf, 'ota_manifest.json')) as f:
        leaves = json.load(f)['leaves']

    sizes = {k: os.path.getsize(v) for k, v in exes.items()}
    aot_sizes = {k: os.path.getsize(v) for k, v in variants.items()}
    patch_reports = {m: json.load(open(os.path.join(pkg, 'ota_patch_report.json')))
                     for m, pkg in patched.items()}
    report = {
        'dart': run([DART, '--version']).stdout.strip(),
        'instrument': instr_out,
        'instrument_fast': noleaf_out,
        'patch_reports': patch_reports,
        'instrumented_equals_plain': instr_same,
        'cases': rows,
        'summary': summary,
        'h2': {'slots_total': len(all_slots), 'checks_kept_with_marker': len(kept_pragma),
               'checks_kept_without_marker': len(kept_nopragma)},
        'perf_min_us': perf,
        'aot_snapshot_sizes': aot_sizes,
        'tiny_leaves_skipped': leaves,
        'sizes': sizes,
    }
    with open(os.path.join(OUT, 'shot1_results.json'), 'w') as f:
        json.dump(report, f, indent=1)

    md = ['# Shot 1 / 1b results (local, real Dart AOT)', '', f"Dart: `{report['dart']}`", '',
          '## Correctness', '',
          f"- Store build with checks behaves exactly like the plain build: **{instr_same}**"]
    for m, sm in summary.items():
        lvl = patch_reports[m]['metrics']['level']
        md.append(f"- Patch mode **{m}** (level {lvl}): {sm['match']} / {len(cases)} cases match v2"
                  + (f"; differ: {', '.join(sm['differ'])}" if sm['differ'] else ''))
    md += ['- `c43_isolate`: runs code in a background isolate. Here the patch is linked in, so a '
           'background isolate can see patched code; on a device this depends on the loader (Shot 2).',
           '', '| Case | v1 | v2 (oracle) | ' + ' | '.join(patched) + ' |',
           '|---' * (3 + len(patched)) + '|']
    md += ['| ' + ' | '.join(r) + ' |' for r in rows]
    md += ['', '## Patch levels and size', '', '| Mode | level | files | lines +/- | functions interpreted '
           '| class copies | side fields | re-pointed |', '|---|---|---|---|---|---|---|---|']
    for m, pr in patch_reports.items():
        x = pr['metrics']
        md.append(f"| {m} | {x['level']} | {x['files_changed']} | +{x['lines_added']}/-{x['lines_removed']} "
                  f"| {x['interpreted_functions']} | {x['copied_classes']} | {x['side_fields']} "
                  f"| {x['repointed']} |")
    md += ['', '## Optimizer check (H2)', '',
           f"- Functions and initializers with a redirect check: {len(all_slots)}",
           f"- Checks still present after AOT optimization, **with** markers: {len(kept_pragma)}",
           f"- Checks still present, **without** markers (control): {len(kept_nopragma)}",
           '- (Code the optimizer removes as unused, and initializer checks folded into their '
           'field access, are not counted separately.)',
           '', '## Performance (minimum of 7 interleaved runs, change vs plain; lower is better)', '']
    base = perf['plain store build (no OTA)']
    names = list(base.keys())
    md += ['| Variant | ' + ' | '.join(names) + ' | compiled size |',
           '|---' * (len(names) + 2) + '|']
    p0 = aot_sizes['plain store build (no OTA)']
    for label, t in perf.items():
        cells = [f'{(t[n] - base[n]) / base[n] * 100:+.1f}%' for n in names]
        md.append(f'| {label} | ' + ' | '.join(cells) +
                  f' | {aot_sizes[label]:,} ({(aot_sizes[label] - p0) / p0 * 100:+.0f}%) |')
    md += ['', f'Tiny leaves without a check in fast mode ({len(leaves)}): ' +
           ', '.join(k.split('::', 1)[1] for k in leaves),
           '', '## Executable size (dart compile exe)', '', '| Build | bytes | vs plain |',
           '|---|---|---|']
    for k, v in sizes.items():
        md.append(f"| {k} | {v:,} | {(v - sizes['v1_plain']) / sizes['v1_plain'] * 100:+.1f}% |")
    for m, out in patch_out.items():
        md += ['', f'## Patch tool output: {m}', '', '```', out.strip(), '```']
    with open(os.path.join(OUT, 'shot1_report.md'), 'w') as f:
        f.write('\n'.join(md) + '\n')
    log('done: out/shot1_report.md')
    print('\n'.join(md[:12]))


if __name__ == '__main__':
    main()
