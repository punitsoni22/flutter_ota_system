#!/usr/bin/env python3
# Copyright 2026 The Punit Authors
# SPDX-License-Identifier: Apache-2.0
"""Shot 2 report: reads the files run_shot2.sh wrote to a results folder and prints Markdown.

  report_shot2.py <results-folder> <mode>

Also writes <results-folder>/summary.json (all numbers, for compare_shot2.py).
"""
import json
import os
import re
import statistics
import sys

OUT, MODE = sys.argv[1], sys.argv[2]
PATCH_MODES = {'redirect', 'redirect-fast', 'redirect-narrow'}
# Known limit H4: slots are per isolate, so code that runs in a background isolate keeps the
# store version unless the patch is also installed there. c43b runs the same function on the
# main isolate (control).
ISOLATE_CASES = {
    'c43_isolate': 'Isolate.run with a closure',
    'c43c_isolate_run_tearoff': 'Isolate.run with a top-level function (like compute())',
    'c43d_isolate_spawn': 'Isolate.spawn (long-lived worker)',
}


def read(name):
    path = os.path.join(OUT, name)
    return open(path, encoding='utf-8', errors='replace').read() if os.path.exists(path) else ''


def load_json(name):
    try:
        return json.loads(read(name) or '{}')
    except ValueError:
        return {}


def cases_of(text, prefix=''):
    out = {}
    for line in text.splitlines():
        if prefix:
            if not line.startswith(prefix):
                continue
            line = line[len(prefix):]
        parts = line.split('\t', 1)
        if len(parts) == 2 and re.match(r'^c\d\d[a-z]?_', parts[0]):
            out[parts[0]] = parts[1]
    return out


def device_cases(name):
    return cases_of(read(name), '[shot2] case ')


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
        if m and m.group(1) != 'sink':
            out[m.group(1)] = int(m.group(2))
    return out


def pss_kb(text):
    m = re.search(r'TOTAL PSS:\s+([\d,]+)', text) or re.search(r'^\s*TOTAL\s+([\d,]+)', text, re.M)
    return int(m.group(1).replace(',', '')) if m else None


def stat(xs):
    xs = [x for x in xs if x is not None]
    return {'median': statistics.median(xs), 'min': min(xs), 'max': max(xs), 'n': len(xs)} if xs else None


def starts(label):
    rows = [start_line(l) for l in read(f'{label}_starts.txt').splitlines() if l.strip()]
    rows = [r for r in rows if r]
    if not rows:
        return None
    pss = [pss_kb(read(f'{label}_start{i}.meminfo.txt')) for i in range(1, 50) if read(f'{label}_start{i}.meminfo.txt')]
    return {
        'init_ms': stat([r.get('init_ms') for r in rows]),
        'total_ms': stat([r.get('total_ms') for r in rows]),
        'pss_kb': stat(pss),
        'statuses': sorted({r.get('status') for r in rows}),
    }


def compare(device, oracle, allowed=()):
    same = [n for n in oracle if device.get(n) == oracle[n]]
    diff = [n for n in oracle if device.get(n) != oracle[n]]
    return same, diff, [n for n in diff if n not in allowed]


def sdk_events(name):
    """SDK and app lines of one start, with seconds since its first line."""
    rows = []
    for line in read(f'{name}.epoch.log').splitlines():
        m = re.match(r'^\s*([\d.]+)\s+\d+\s+\d+\s+\w\s+flutter\s*:\s?(.*)$', line)
        if m and (m.group(2).startswith('[flutter_ota]') or m.group(2).startswith('[shot2] start')
                  or m.group(2).startswith('[shot2] cases_done') or 'shot2: uncaught' in m.group(2)):
            rows.append((float(m.group(1)), m.group(2)))
    if not rows:
        return []
    t0 = rows[0][0]
    return [(round(t - t0, 2), msg[:160]) for t, msg in rows]


def patch_info(name):
    pj = load_json(name)
    if not pj:
        return None
    metrics = (pj.get('redirect_report') or {}).get('metrics') or {}
    manifest = pj.get('manifest') or {}
    return {'patch_id': manifest.get('patch_id'), 'sequence': manifest.get('sequence'),
            'module_bytes': (manifest.get('module') or {}).get('size'), **metrics}


v1, v2, v3 = (cases_of(read(f'oracle_{v}.txt')) for v in ('v1', 'v2', 'v3'))
allowed = set(ISOLATE_CASES)
summary = {'mode': MODE, 'phone': read('phone.txt').strip().splitlines(), 'cases': len(v2),
           'failed_stages': read('failures.txt').split()}
md = [f'# Shot 2 report ({MODE})', '', *[f'- {l}' for l in summary['phone']], '']
if summary['failed_stages']:
    md += [f'**Stages that failed:** {", ".join(summary["failed_stages"])} (see steps.log and the stage logs).', '']

# ---- store build
run1 = read('run1_store.log')
store = device_cases('run1_store.log')
same, diff, _ = compare(store, v1)
st1 = start_line(run1)
summary['store_equals_v1'] = {'match': len(same), 'total': len(v1), 'diff': diff, 'status': st1.get('status')}
md += ['## 1. Store build behaves like v1', '',
       f'**{len(same)} / {len(v1)}** cases equal the local v1 run (OTA status `{st1.get("status")}`).', '']
md += [f'- `{n}`: device `{store.get(n)}`, v1 `{v1[n]}`' for n in diff]

# ---- patch v1 -> v2
if MODE in PATCH_MODES:
    patched_log = read('run3_patched.log')
    st = start_line(patched_log)
    patched = device_cases('run3_patched.log')
    same, diff, unexpected = compare(patched, v2, allowed)
    summary['patched'] = {'status': st.get('status'), 'patch': st.get('patch'), 'match': len(same),
                          'total': len(v2), 'diff': diff, 'unexpected_diff': unexpected}
    md += ['', '## 2. Patched app behaves like v2', '']
    if not patched_log:
        md.append('No patched start (see failures above and patch.log).')
    else:
        md += [f'Start after the download: status `{st.get("status")}`, patch `{st.get("patch")}`.', '',
               f'**{len(same)} / {len(v2)}** cases equal the local v2 run; **{len(unexpected)} unexpected** '
               'difference(s) (background-isolate cases are reported in section 6).', '']
        md += [f'- `{n}`: device `{patched.get(n)}`, v2 `{v2[n]}`, v1 `{v1.get(n)}` **UNEXPECTED**' for n in unexpected]
    p1 = patch_info('patch.json')
    summary['patch1'] = p1
    if p1:
        md += ['', f'Patch 1: level **{p1.get("level")}**, {p1.get("files_changed")} files, '
               f'+{p1.get("lines_added")}/-{p1.get("lines_removed")} lines, {p1.get("interpreted_functions")} functions '
               f'interpreted, {p1.get("copied_classes")} class copies, {p1.get("side_fields")} side fields, '
               f'{p1.get("repointed")} re-pointed; bytecode module **{p1.get("module_bytes")} bytes**.']
    for label, name in [('download', 'run2_download'), ('patched start', 'run3_patched')]:
        ev = sdk_events(name)
        if ev:
            md += ['', f'SDK timeline, {label} (seconds since the first line):', '', '```',
                   *[f'{t:7.2f}  {m}' for t, m in ev], '```']
            summary.setdefault('timeline', {})[name] = ev

# ---- start-up and memory
md += ['', '## 3. Start-up and memory (cold starts)', '',
       '| State | init ms median (min-max) | SDK total ms median | memory PSS MB median (min-max) | n |',
       '|---|---|---|---|---|']
summary['startup'] = {}
for label in ['store', 'patched']:
    s = starts(label)
    if not s:
        continue
    summary['startup'][label] = s
    i, t, m = s['init_ms'], s['total_ms'], s['pss_kb']
    fi = f'{i["median"]:.0f} ({i["min"]:.0f}-{i["max"]:.0f})' if i else '-'
    ft = f'{t["median"]:.1f}' if t else '-'
    fm = f'{m["median"] / 1024:.1f} ({m["min"] / 1024:.1f}-{m["max"] / 1024:.1f})' if m else '-'
    md.append(f'| {label} | {fi} | {ft} | {fm} | {i["n"] if i else 0} |')

# ---- check cost
summary['bench'] = {'store': bench_of(run1)}
if MODE in PATCH_MODES and read('run4_patched_bench.log'):
    summary['bench']['patched'] = bench_of(read('run4_patched_bench.log'))
md += ['', '## 4. Check cost (bench in unchanged code, median of 7, microseconds)', '',
       '| Bench | ' + ' | '.join(summary['bench']) + ' |', '|---|' + '---|' * len(summary['bench'])]
for name in summary['bench']['store']:
    md.append(f'| {name} | ' + ' | '.join(str(b.get(name, '')) for b in summary['bench'].values()) + ' |')
md += ['', 'compare_shot2.py puts these next to the `stock` and `plain` runs on the same phone.']

# ---- sizes
sizes = dict(l.split() for l in read('sizes.txt').splitlines() if len(l.split()) == 2)
summary['sizes'] = sizes
md += ['', '## 5. Sizes', '', *[f'- {k}: {v}' for k, v in sizes.items()]]

# ---- background isolates
if MODE in PATCH_MODES and read('run3_patched.log'):
    patched = device_cases('run3_patched.log')
    md += ['', '## 6. Background isolates (known limit H4)', '',
           '| Case | How | Device | v1 | v2 | Runs patched code? |', '|---|---|---|---|---|---|']
    iso = {}
    for n, how in {'c43b_same_fn_main_isolate': 'main isolate (control)', **ISOLATE_CASES}.items():
        d = patched.get(n)
        verdict = 'yes' if d == v2.get(n) else ('no (store code)' if d == v1.get(n) else 'other')
        iso[n] = verdict
        md.append(f'| `{n}` | {how} | `{d}` | `{v1.get(n)}` | `{v2.get(n)}` | {verdict} |')
    summary['isolates'] = iso

# ---- A: patch chain and rollback
if read('patch2_v3.json'):
    p2 = patch_info('patch2_v3.json')
    c3 = device_cases('chain_v3.log')
    st3 = start_line(read('chain_v3.log'))
    same3, _, unexp3 = compare(c3, v3, allowed)
    cr = device_cases('chain_rollback.log')
    strb = start_line(read('chain_rollback.log'))
    samerb, _, unexprb = compare(cr, v2, allowed)
    p1id = (summary.get('patch1') or {}).get('patch_id')
    summary['chain'] = {'patch2': p2, 'v3_match': len(same3), 'v3_unexpected': unexp3,
                        'running_after_patch2': st3.get('patch'),
                        'after_rollback_patch': strb.get('patch'), 'after_rollback_is_patch1': strb.get('patch') == p1id,
                        'after_rollback_match_v2': len(samerb), 'after_rollback_unexpected': unexprb}
    md += ['', '## 7. Patch chain and rollback (A)', '',
           f'- Patch 2 (v2 + one line, cumulative from the store build): level {p2.get("level")}, '
           f'{p2.get("module_bytes")} bytes. The phone ran `{st3.get("patch")}`: **{len(same3)} / {len(v3)}** '
           f'cases equal v3, {len(unexp3)} unexpected.',
           f'- After `flutter_ota rollback` of patch 2: the phone runs `{strb.get("patch")}` '
           f'({"patch 1, as expected" if strb.get("patch") == p1id else "NOT patch 1"}): **{len(samerb)} / {len(v2)}** '
           f'cases equal v2, {len(unexprb)} unexpected.']

# ---- F: bad patches
if read('patch3_f1.json'):
    f1 = patch_info('patch3_f1.json')
    f1_starts = [start_line(read(n)) for n in ('f1_running.log', 'f1_again1.log', 'f1_again2.log')]
    f1_text = ''.join(read(n) for n in ('f1_running.log', 'f1_again1.log', 'f1_again2.log'))
    still = [s.get('patch') == f1['patch_id'] for s in f1_starts if s]
    summary['bad_dart_error'] = {
        'patch_id': f1['patch_id'], 'starts_still_on_it': sum(still), 'starts': len(still),
        'errors_seen': f1_text.count('shot2: uncaught error'), 'sdk_patch_error_lines': f1_text.count('PATCH_ERROR'),
    }
    md += ['', '## 8. Crash protection with redirect patches (F)', '',
           f'- **Dart error** (patch {f1["patch_id"][:8]}): errors in the log: '
           f'{summary["bad_dart_error"]["errors_seen"]}; SDK `PATCH_ERROR` lines: '
           f'{summary["bad_dart_error"]["sdk_patch_error_lines"]}; still running it after {len(still)} starts: '
           f'{sum(still)}. (Expected today: not counted, because the SDK counts Dart errors only after a '
           'feature slot was used.)']
if read('patch4_f2.json'):
    f2 = patch_info('patch4_f2.json')
    outcomes = [l.split() for l in read('crash_starts.txt').splitlines() if len(l.split()) == 2]
    f2_text = ''.join(read(f'{n}.log') for n, _ in outcomes)
    last = start_line(read(f'{outcomes[-1][0]}.log')) if outcomes else {}
    sdk = [l for l in f2_text.splitlines() if re.search(r'SESSION_END|FAILURE_COUNT|ROLLED_BACK|BLACKLIST|LAST_EXIT', l)]
    summary['bad_process_crash'] = {'patch_id': f2['patch_id'], 'starts': outcomes,
                                    'final_patch': last.get('patch'), 'rolled_back': last.get('patch') not in (None, f2['patch_id'])}
    md += [f'- **Process crash** (patch {f2["patch_id"][:8]}): starts '
           + ', '.join(f'{o}' for _, o in outcomes)
           + f'; the last start runs `{last.get("patch")}` '
           + ('(**rolled back**)' if summary['bad_process_crash']['rolled_back'] else '(NOT rolled back)') + '.',
           '', '```', *sdk[:20], '```']

# ---- B: size ladder
ladder = [l.split() for l in read('ladder.txt').splitlines() if len(l.split()) == 3]
if ladder:
    md += ['', '## 9. Patch size follows the change (B)', '',
           '| Change | Level | Files | Lines +/- | Functions interpreted | Module bytes | Signed patch bytes | Build s |',
           '|---|---|---|---|---|---|---|---|']
    rows = []
    for name, secs, otp in ladder:
        p = patch_info(f'ladder_{name}.json') or {}
        rows.append({'name': name, 'build_s': int(secs), 'otp_bytes': int(otp), **p})
        md.append(f'| {name} | {p.get("level")} | {p.get("files_changed")} | +{p.get("lines_added")}/-{p.get("lines_removed")} | '
                  f'{p.get("interpreted_functions")} | {p.get("module_bytes")} | {otp} | {secs} |')
    p1 = summary.get('patch1')
    if p1:
        md.append(f'| full v2 (patch 1) | {p1.get("level")} | {p1.get("files_changed")} | +{p1.get("lines_added")}/-{p1.get("lines_removed")} | '
                  f'{p1.get("interpreted_functions")} | {p1.get("module_bytes")} | {sizes.get("patch.otp", "")} | |')
    summary['ladder'] = rows

with open(os.path.join(OUT, 'summary.json'), 'w', encoding='utf-8') as f:
    json.dump(summary, f, indent=1)
print('\n'.join(md))
