# Copyright 2026 The Punit Authors
# SPDX-License-Identifier: Apache-2.0
"""Turns device-suite results into Markdown tables (no hand-copied numbers in the reports).

    python3 -I scripts/summarize_results.py <run-dir> [<perf-dir>] [<modules.tsv>] > tables.md
"""
import json
import pathlib
import sys


def esc(v) -> str:
    return str(v).replace('|', '\\|').replace('\n', ' ')


def table(headers, rows) -> str:
    out = ['| ' + ' | '.join(headers) + ' |', '|' + '---|' * len(headers)]
    out += ['| ' + ' | '.join(esc(c) for c in r) + ' |' for r in rows]
    return '\n'.join(out) + '\n'


def load(p: pathlib.Path):
    try:
        return json.loads(p.read_text())
    except (OSError, json.JSONDecodeError):
        return None


def main() -> None:
    run = pathlib.Path(sys.argv[1])
    perf = pathlib.Path(sys.argv[2]) if len(sys.argv) > 2 else None
    modules = pathlib.Path(sys.argv[3]) if len(sys.argv) > 3 else None
    print('## Test results\n')
    rows = load(run / 'results.json') or []
    print(table(['ID', 'Part', 'Status', 'Test', 'Detail'], [[r['id'], r['part'], r['status'], r['title'], r['detail'][:160]] for r in rows]))
    counts = {s: sum(r['status'] == s for r in rows) for s in ('PASS', 'FAIL', 'BLOCKED', 'NOT_TESTED')}
    print(f'Totals: {counts}\n')

    lang = load(run / 'probes' / '01_probe_lang.json')
    if lang and lang.get('result'):
        print('## Dart language features (interpreted copy vs host AOT)\n')
        print(table(['Feature', 'Compiles', 'Loads', 'Executes', 'Same result as AOT', 'Interpreted result'],
                    [[k, 'yes', 'yes', 'yes' if v['executes'] else 'NO', 'yes' if v['matches_aot'] else 'NO', v['interpreted'][:60]]
                     for k, v in lang['result'].items()]))

    for name, title in [('02_probe_state', 'Shared state and class identity'), ('03_probe_ui', 'Flutter framework types from bytecode'),
                        ('04_probe_plugins', 'Plugins'), ('05_probe_assets', 'Assets'), ('08_probe_multi_b', 'Multiple modules (module B uses module A)'),
                        ('10_probe_multi_prefixed', 'Multiple modules: --prefix-library-uris'), ('11_probe_dynamic', 'Dynamic calls (opt-in experiment)')]:
        r = load(run / 'probes' / f'{name}.json')
        if r and r.get('result') is not None:
            print(f'## {title}\n')
            print(f"Module {r.get('module_bytes')} bytes, loaded in {r.get('load_ms')} ms.\n")
            print(table(['Check', 'Observed'], [[k, json.dumps(v, ensure_ascii=False)[:150]] for k, v in r['result'].items()]))

    if modules and modules.exists():
        print('## Modules\n')
        lines = [l.split('\t') for l in modules.read_text().splitlines()]
        print(table(lines[0], lines[1:]))

    if perf:
        print('## Performance\n')
        for f in sorted(perf.glob('startup_*.json')):
            d = load(f) or {}
            vals = [v for v in d.get('am_start_total_ms', []) if v]
            ff = [v for v in d.get('main_to_first_frame_ms', []) if v]
            ld = [v for v in d.get('module_load_ms', []) if v]
            print(f"- **{f.stem}**: am start TotalTime ms {stat(vals)}; main→first frame ms {stat(ff)}; "
                  f"module load ms {stat(ld)}; PSS kB {d.get('total_pss_kb')}")
        print()
        fr = [(f.stem, load(f) or {}) for f in sorted(perf.glob('frames_*.json'))]
        if fr:
            hdr = ['Run', 'Frames', 'Refresh Hz', 'Build median/p90/p99/worst ms', 'Raster median/p90/p99/worst ms', 'Missed budget', 'Over 16.7 ms']
            print(table(hdr, [[n, d.get('frames'), round(d.get('refresh_hz', 0)), q(d.get('build_ms')), q(d.get('raster_ms')),
                               d.get('missed_budget_frames'), d.get('missed_16ms_frames')] for n, d in fr]))
        b = load(perf / 'bench.json')
        if b and b.get('result'):
            print(table(['Kernel', 'AOT median ms', 'AOT p90/p99/worst', 'Interpreted median ms', 'Interpreted p90/p99/worst', 'Slowdown (median)', 'Same checksum'],
                        [[k, f"{v['aot_ms']['median']:.3f}", f"{v['aot_ms']['p90']:.3f} / {v['aot_ms']['p99']:.3f} / {v['aot_ms']['worst']:.3f}",
                          f"{v['interpreted_ms']['median']:.2f}", f"{v['interpreted_ms']['p90']:.2f} / {v['interpreted_ms']['p99']:.2f} / {v['interpreted_ms']['worst']:.2f}",
                          f"{v['slowdown_median']:.1f}x", 'yes' if v['checksums_equal'] else 'NO'] for k, v in b['result'].items()]))


def stat(v):
    if not v:
        return '-'
    s = sorted(v)
    p = lambda x: s[round(x / 100 * (len(s) - 1))]
    return f"n={len(s)} avg {sum(s) / len(s):.1f}, median {p(50):.1f}, p90 {p(90):.1f}, worst {s[-1]:.1f}"


def q(d):
    if not d or not d.get('count'):
        return '-'
    return f"{d['median']:.2f} / {d['p90']:.2f} / {d['p99']:.2f} / {d['worst']:.2f}"


if __name__ == '__main__':
    main()
