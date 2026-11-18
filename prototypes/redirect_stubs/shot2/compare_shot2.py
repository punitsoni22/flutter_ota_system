#!/usr/bin/env python3
# Copyright 2026 The Punit Authors
# SPDX-License-Identifier: Apache-2.0
"""Shot 2 combined report: every mode side by side, per phone.

  compare_shot2.py <results-folder>

Reads the newest <mode>-<time>/summary.json per mode and phone (written by report_shot2.py) and
prints Markdown. Percentages compare with the `stock` build (no OTA) and the `plain` build
(OTA with the full interface, no checks) on the same phone.
"""
import json
import os
import sys

ROOT = sys.argv[1]
ORDER = ['stock', 'plain', 'redirect-narrow', 'redirect', 'redirect-fast']

latest = {}
for d in sorted(os.listdir(ROOT)):
    p = os.path.join(ROOT, d, 'summary.json')
    if not os.path.isfile(p):
        continue
    with open(p, encoding='utf-8') as f:
        s = json.load(f)
    phone = next((l for l in s.get('phone', []) if l.startswith('phone:')), 'phone: ?')[7:]
    s['_folder'] = d
    latest[(phone, s['mode'])] = s  # sorted by name = by time: the newest wins

phones = sorted({k[0] for k in latest})
md = ['# Shot 2: all modes', '']
if not phones:
    print('No summary.json found in', ROOT)
    sys.exit(0)


def num(x):
    try:
        return float(x)
    except (TypeError, ValueError):
        return None


def pct(x, base):
    return f'{(x - base) / base * 100:+.1f}%' if x is not None and base else ''


def med(s, state, key):
    v = (((s.get('startup') or {}).get(state) or {}).get(key) or {})
    return v.get('median')


for phone in phones:
    runs = [(m, latest[(phone, m)]) for m in ORDER if (phone, m) in latest]
    md += [f'## {phone}', '', 'Folders: ' + ', '.join(f'`{s["_folder"]}`' for _, s in runs), '']

    md += ['### Correctness and cost', '',
           '| Mode | Store = v1 | Patched = v2 (unexpected) | Start-up ms store / patched | Memory MB store / patched | libapp.so MB | APK MB | Interface entries | Patch 1 bytes | Failed stages |',
           '|---|---|---|---|---|---|---|---|---|---|']
    for m, s in runs:
        sv = s.get('store_equals_v1') or {}
        pv = s.get('patched') or {}
        sz = s.get('sizes') or {}
        su = lambda st: f'{med(s, st, "init_ms"):.0f}' if med(s, st, 'init_ms') is not None else '-'
        mm = lambda st: f'{med(s, st, "pss_kb") / 1024:.0f}' if med(s, st, 'pss_kb') is not None else '-'
        lib, apk = num(sz.get('libapp.so')), num(sz.get('apk'))
        patched = f'{pv.get("match")}/{pv.get("total")} ({len(pv.get("unexpected_diff", []))})' if pv.get('status') else '-'
        md.append(f'| {m} | {sv.get("match")}/{sv.get("total")} | {patched} | {su("store")} / {su("patched")} | '
                  f'{mm("store")} / {mm("patched")} | {lib / 1e6:.2f} | {apk / 1e6:.2f} | {sz.get("interface_entries", "-")} | '
                  f'{(s.get("patch1") or {}).get("module_bytes", "-")} | {", ".join(s.get("failed_stages", [])) or "-"} |'
                  if lib and apk else f'| {m} | {sv.get("match")}/{sv.get("total")} | {patched} | | | | | | | |')

    base_stock = dict((latest.get((phone, 'stock')) or {}).get('bench', {}).get('store', {}))
    base_plain = dict((latest.get((phone, 'plain')) or {}).get('bench', {}).get('store', {}))
    names = sorted({n for _, s in runs for n in (s.get('bench') or {}).get('store', {})})
    md += ['', '### Speed of unchanged code in the store build (microseconds; vs stock / vs plain)', '',
           '| Mode | ' + ' | '.join(names) + ' |', '|---|' + '---|' * len(names)]
    for m, s in runs:
        b = (s.get('bench') or {}).get('store', {})
        md.append(f'| {m} | ' + ' | '.join(
            f'{b[n]} ({pct(b[n], base_stock.get(n)) or "-"} / {pct(b[n], base_plain.get(n)) or "-"})' if n in b else '-'
            for n in names) + ' |')
    lib_stock = num(((latest.get((phone, 'stock')) or {}).get('sizes') or {}).get('libapp.so'))
    if lib_stock:
        md += ['', 'libapp.so vs stock: ' + ', '.join(
            f'{m} {pct(num((s.get("sizes") or {}).get("libapp.so")), lib_stock)}' for m, s in runs if m != 'stock')]

    fast = latest.get((phone, 'redirect-fast'))
    if fast:
        md += ['', '### Extra stages (redirect-fast)', '']
        if fast.get('isolates'):
            md.append('- Background isolates run patched code: ' + ', '.join(f'`{k}` {v}' for k, v in fast['isolates'].items()))
        ch = fast.get('chain')
        if ch:
            md.append(f'- Patch chain: patch 2 = v3 on {ch["v3_match"]} cases ({len(ch["v3_unexpected"])} unexpected); '
                      f'after rollback the phone runs patch 1: {ch["after_rollback_is_patch1"]} '
                      f'({ch["after_rollback_match_v2"]} cases = v2, {len(ch["after_rollback_unexpected"])} unexpected)')
        de = fast.get('bad_dart_error')
        if de:
            md.append(f'- Dart error in a patch: still running it after {de["starts_still_on_it"]}/{de["starts"]} starts; '
                      f'SDK PATCH_ERROR lines {de["sdk_patch_error_lines"]}')
        pc = fast.get('bad_process_crash')
        if pc:
            md.append(f'- Process crash in a patch: starts {", ".join(o for _, o in pc["starts"])}; rolled back: {pc["rolled_back"]}')
        if fast.get('ladder'):
            md += ['', '| Change | Level | Lines +/- | Functions | Module bytes | Signed bytes | Build s |', '|---|---|---|---|---|---|---|']
            for r in fast['ladder']:
                md.append(f'| {r["name"]} | {r.get("level")} | +{r.get("lines_added")}/-{r.get("lines_removed")} | '
                          f'{r.get("interpreted_functions")} | {r.get("module_bytes")} | {r.get("otp_bytes")} | {r.get("build_s")} |')
    md.append('')

print('\n'.join(md))
