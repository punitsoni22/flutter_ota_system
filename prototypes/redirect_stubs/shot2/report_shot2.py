#!/usr/bin/env python3
# Copyright 2026 The Punit Authors
# SPDX-License-Identifier: Apache-2.0
"""Shot 2 report: reads the files run_shot2.sh wrote to a results folder and prints Markdown.

  report_shot2.py <results-folder> <mode>

Also writes <results-folder>/summary.json (all numbers, for comparing modes and phones).
"""
import json
import os
import re
import statistics
import sys

OUT, MODE = sys.argv[1], sys.argv[2]
# Known limit H4: slots are per isolate, so code that runs in a background isolate keeps the
# store version unless the patch is also installed there.
KNOWN = {'c43_isolate'}


def read(name):
    path = os.path.join(OUT, name)
    return open(path, encoding='utf-8', errors='replace').read() if os.path.exists(path) else ''


def cases_of(text, prefix=''):
    out = {}
    for line in text.splitlines():
        if prefix:
            if not line.startswith(prefix):
                continue
            line = line[len(prefix):]
        parts = line.split('\t', 1)
        if len(parts) == 2 and re.match(r"^c\d\d[a-z]?_", parts[0]):
            out[parts[0]] = parts[1]
    return out


def start_line(text):
    lines = [l for l in text.splitlines() if l.startswith('[shot2] start')]
    if not lines:
        return {}
    fields = dict(re.findall(r'(\w+)=(\S+)', lines[-1]))
    fields.update({k: float(v) for k, v in re.findall(r'(\w+_ms)=([\d.]+)', lines[-1])})
    return fields


def bench_of(text):
    out = {}
    for line in text.splitlines():
        m = re.match(r'^\[shot2\] bench (\w+)\t(\d+)$', line)
        if m:
            out[m.group(1)] = int(m.group(2))
    return out


def starts(label):
    rows = [start_line(l) for l in read(f'{label}_starts.txt').splitlines() if l.strip()]
    rows = [r for r in rows if r]
    if not rows:
        return None
    def stat(key):
        xs = [r[key] for r in rows if isinstance(r.get(key), float)]
        return {'median': statistics.median(xs), 'min': min(xs), 'max': max(xs), 'n': len(xs)} if xs else None
    return {'init_ms': stat('init_ms'), 'total_ms': stat('total_ms'), 'statuses': sorted({r.get('status') for r in rows})}


def compare(device, oracle):
    names = list(oracle)
    same = [n for n in names if device.get(n) == oracle[n]]
    diff = [n for n in names if device.get(n) != oracle[n]]
    return same, diff


v1, v2 = cases_of(read('oracle_v1.txt')), cases_of(read('oracle_v2.txt'))
run1 = read('run1_store.log')
summary = {'mode': MODE, 'phone': read('phone.txt').strip().splitlines(), 'cases': len(v2)}
md = [f'# Shot 2 report ({MODE})', '', *[f'- {l}' for l in summary['phone']], '']

store_cases = cases_of(run1, '[shot2] case ')
same, diff = compare(store_cases, v1)
summary['store_equals_v1'] = {'match': len(same), 'total': len(v1), 'diff': diff}
md += ['## Store build behaves like v1', '',
       f'**{len(same)} / {len(v1)}** cases equal the local v1 run (instrumentation must not change behaviour).', '']
for n in diff:
    md.append(f'- `{n}`: device `{store_cases.get(n)}`, v1 `{v1[n]}`')

if MODE != 'plain':
    patched_log = read('run3_patched.log')
    st = start_line(patched_log)
    patched = cases_of(patched_log, '[shot2] case ')
    same, diff = compare(patched, v2)
    unexpected = [n for n in diff if n not in KNOWN]
    summary['patched'] = {'status': st.get('status'), 'patch': st.get('patch'), 'match': len(same),
                          'total': len(v2), 'diff': diff, 'unexpected_diff': unexpected}
    md += ['', '## Patched app behaves like v2', '',
           f'Start after the download: status `{st.get("status")}`, patch `{st.get("patch")}`.', '',
           f'**{len(same)} / {len(v2)}** cases equal the local v2 run; '
           f'{len(unexpected)} unexpected difference(s).', '']
    for n in diff:
        tag = ' (known: background isolate, H4)' if n in KNOWN else ' **UNEXPECTED**'
        md.append(f'- `{n}`: device `{patched.get(n)}`, v2 `{v2[n]}`, v1 `{v1.get(n)}`{tag}')
    try:
        pj = json.loads(read('patch.json') or '{}')
    except ValueError:
        pj = {}
    rep = pj.get('redirect_report') or {}
    metrics = rep.get('metrics') or {}
    module = (pj.get('manifest') or {}).get('module') or {}
    summary['patch_metrics'] = metrics
    summary['module_bytes'] = module.get('size')
    md += ['', '## The patch', '',
           f'- level **{metrics.get("level")}**: {metrics.get("files_changed")} files, '
           f'+{metrics.get("lines_added")}/-{metrics.get("lines_removed")} lines',
           f'- {metrics.get("interpreted_functions")} functions interpreted, {metrics.get("copied_classes")} class copies, '
           f'{metrics.get("side_fields")} side fields, {metrics.get("repointed")} re-pointed',
           f'- bytecode module {module.get("size")} bytes']

md += ['', '## Start-up (FlutterOta.initialize, cold starts)', '', '| State | init ms median (min-max) | SDK total ms median | n |', '|---|---|---|---|']
summary['startup'] = {}
for label in ['store', 'patched']:
    s = starts(label)
    if not s:
        continue
    summary['startup'][label] = s
    i, t = s['init_ms'], s['total_ms']
    md.append(f'| {label} | {i["median"]:.0f} ({i["min"]:.0f}-{i["max"]:.0f}) | '
              f'{t["median"]:.1f} | {i["n"]} |' if i and t else f'| {label} | {i} | {t} | |')

md += ['', '## Check cost (bench in unchanged code, median of 7, microseconds)', '']
summary['bench'] = {'store': bench_of(run1)}
if MODE != 'plain':
    summary['bench']['patched'] = bench_of(read('run4_patched_bench.log'))
md += ['| Bench | ' + ' | '.join(summary['bench']) + ' |', '|---|' + '---|' * len(summary['bench'])]
for name in summary['bench']['store']:
    md.append(f'| {name} | ' + ' | '.join(str(b.get(name, '')) for b in summary['bench'].values()) + ' |')
md += ['', 'Compare with the `plain` mode run on the same phone for the cost of the checks.']

sizes = dict(l.split() for l in read('sizes.txt').splitlines() if len(l.split()) == 2)
summary['sizes'] = sizes
md += ['', '## Sizes (bytes)', '', *[f'- {k}: {v}' for k, v in sizes.items()]]

with open(os.path.join(OUT, 'summary.json'), 'w', encoding='utf-8') as f:
    json.dump(summary, f, indent=1)
print('\n'.join(md))
