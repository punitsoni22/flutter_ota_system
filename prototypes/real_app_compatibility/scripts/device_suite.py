# Copyright 2026 The Punit Authors
# SPDX-License-Identifier: Apache-2.0
"""Phase 2 physical-device acceptance suite (Android, adb). Standard library only.

    python3 -I scripts/device_suite.py --baseline <baseline-dir> --otp <modules-dir> \
        --results <dir> [--suites ui,probes,crash,perf,compat] [--serial <adb-serial>] \
        [--release2-apk <apk of a second full release>]

Every test ends as PASS, FAIL, BLOCKED (could not run) or NOT_TESTED, with evidence files
(logcat lines, the app's result JSON, screenshots) in the results directory. A test that did not
run is never reported as passed. Between tests the app's data is cleared with `pm clear`; the
installed APK is never replaced (its hash is checked at the end).
"""
import argparse
import hashlib
import json
import pathlib
import re
import shutil
import statistics
import subprocess
import sys
import time

PKG = 'io.github.punitsoni22.compat_host'
ACTIVITY = f'{PKG}/.MainActivity'
FILES = f'/sdcard/Android/data/{PKG}/files'
INBOX = f'{FILES}/inbox'
RES = f'{FILES}/results'


class Device:
    def __init__(self, serial: str):
        self.serial = serial

    def adb(self, *args, timeout=180, text=True):
        return subprocess.run(['adb', '-s', self.serial, *args], capture_output=True, text=text, timeout=timeout)

    def sh(self, cmd: str, timeout=180) -> str:
        return self.adb('shell', cmd, timeout=timeout).stdout

    def push(self, local, remote: str):
        self.sh(f'mkdir -p {remote.rsplit("/", 1)[0]}')
        r = self.adb('push', str(local), remote)
        if r.returncode != 0:
            raise RuntimeError(f'adb push failed: {r.stderr}')

    def touch(self, remote: str):
        self.sh(f'mkdir -p {INBOX} && touch {remote}')

    def set_mode(self, mode: str):
        self.sh(f'mkdir -p {INBOX} && echo {mode} > {INBOX}/mode')

    apk = None  # the baseline APK; set by main()

    def reset(self):
        """Fresh patch state for the next start, without reinstalling.

        `pm clear` is refused from adb on the test phone (SecurityException) and repeated
        reinstalls trigger a Play Protect prompt, so the host has a test-only RESET_STORE marker:
        on the next start it wipes its private patch store before anything else.
        """
        self.sh(f'am force-stop {PKG}')
        self.sh(f'rm -rf {INBOX} {RES}')
        self.sh(f'mkdir -p {INBOX} && touch {INBOX}/RESET_STORE')

    def install(self):
        self.adb('uninstall', PKG)
        r = self.adb('install', str(self.apk), timeout=300)
        if r.returncode != 0:
            raise RuntimeError(f'install failed: {r.stderr}')
        if self.apk_hash() != self.expected_hash:
            raise RuntimeError('installed APK hash differs from the baseline APK')

    expected_hash = None

    def apk_hash(self) -> str:
        path = self.sh(f'pm path {PKG}').strip().replace('package:', '')
        return self.sh(f'sha256sum {path}').split(' ')[0]

    def apk_state(self) -> str:
        path = self.sh(f'pm path {PKG}').strip().replace('package:', '')
        digest = self.sh(f'sha256sum {path}').split(' ')[0]
        updated = re.search(r'lastUpdateTime=(.*)', self.sh(f'dumpsys package {PKG}'))
        return f'{digest} {updated.group(1).strip() if updated else "?"}'

    def start(self, wait: float = 0.0):
        """Cold start. Returns (TotalTime ms from `am start -W`, or None)."""
        self.sh(f'am force-stop {PKG}')
        # Results of earlier starts must never be read as this start's results (pm clear does
        # not remove the app's external files directory).
        self.sh(f'rm -rf {RES}')
        self.adb('logcat', '-c')
        out = self.sh(f'am start -W -n {ACTIVITY}')
        m = re.search(r'TotalTime:\s*(\d+)', out)
        if wait:
            time.sleep(wait)
        return int(m.group(1)) if m else None

    def log(self) -> str:
        out = self.adb('logcat', '-d', '-v', 'brief').stdout
        keep = [l for l in out.splitlines() if '[compat]' in l or 'Fatal signal' in l or 'FATAL' in l]
        return '\n'.join(re.sub(r'^.*?\[compat\]', '[compat]', l) for l in keep)

    def result(self, name: str):
        r = self.adb('exec-out', f'cat {RES}/{name}.json')
        try:
            return json.loads(r.stdout)
        except (json.JSONDecodeError, TypeError):
            return None

    def wait_result(self, name: str, timeout: float):
        end = time.time() + timeout
        while time.time() < end:
            v = self.result(name)
            if v is not None:
                return v
            time.sleep(0.5)
        return None

    def wait_log(self, marker: str, timeout: float) -> str:
        end = time.time() + timeout
        while time.time() < end:
            log = self.log()
            if marker in log:
                return log
            time.sleep(1)
        return self.log()

    def screenshot(self, path: pathlib.Path):
        r = self.adb('exec-out', 'screencap -p', text=False)
        path.write_bytes(r.stdout)

    def tap(self, xy):
        self.sh(f'input tap {xy[0]} {xy[1]}')


class Suite:
    def __init__(self, dev: Device, otp: pathlib.Path, results: pathlib.Path):
        self.dev, self.otp, self.out = dev, otp, results
        self.rows = []
        results.mkdir(parents=True, exist_ok=True)

    # --- recording -------------------------------------------------------------------------------
    def record(self, tid: str, part: str, title: str, status: str, detail: str = ''):
        self.rows.append({'id': tid, 'part': part, 'title': title, 'status': status, 'detail': detail})
        print(f'{status:11} {tid:28} {title}' + (f' :: {detail}' if detail else ''), flush=True)

    def save(self, name: str, content):
        p = self.out / name
        p.parent.mkdir(parents=True, exist_ok=True)
        if isinstance(content, (dict, list)):
            p.write_text(json.dumps(content, indent=2, ensure_ascii=False))
        else:
            p.write_text(content or '')
        return p

    def otp_file(self, name: str) -> pathlib.Path:
        return self.otp / f'{name}.otp'

    def have(self, *names) -> bool:
        return all(self.otp_file(n).exists() for n in names)

    def push_patch(self, name: str):
        self.dev.push(self.otp_file(name), f'{INBOX}/patch.otp')

    def run_ui(self, tid: str, mode: str, patch: str = None, reset=True):
        """Start in `mode` (optionally installing `patch` first); returns (log, ui_1 json)."""
        if reset:
            self.dev.reset()
        if patch:
            self.push_patch(patch)
        self.dev.set_mode(mode)
        self.dev.start()
        ui = self.dev.wait_result('ui_1', 20)
        log = self.dev.log()
        self.save(f'{tid}/log.txt', log)
        self.save(f'{tid}/ui_1.json', ui or {})
        self.dev.screenshot(self.out / tid / 'screen_1.png')
        return log, ui or {}

    def check(self, tid, part, title, conds: dict):
        """conds: description -> bool. PASS only if every condition held."""
        failed = [k for k, ok in conds.items() if not ok]
        self.record(tid, part, title, 'FAIL' if failed else 'PASS', ('failed: ' + '; '.join(failed)) if failed else '')

    @staticmethod
    def texts(ui) -> str:
        return '\n'.join(ui.get('texts', []))

    def dump_after_tap(self, tid: str, target: str, ui) -> dict:
        xy = (ui.get('tap_targets') or {}).get(target)
        if not xy:
            return {}
        self.dev.tap(xy)
        time.sleep(0.8)
        self.dev.touch(f'{INBOX}/DUMP')
        ui2 = self.dev.wait_result('ui_2', 10) or {}
        self.save(f'{tid}/ui_2.json', ui2)
        self.dev.screenshot(self.out / tid / 'screen_2.png')
        return ui2

    # --- suites ------------------------------------------------------------------------------------
    def suite_ui(self):
        ref_p1 = hashlib.sha1(b'p1').hexdigest()[:6]

        log, ui = self.run_ui('ui_01_baseline', 'home')
        t = self.texts(ui)
        self.check('ui_01_baseline', '3/8', 'baseline app, no patch (AOT)', {
            'NO_PATCH logged': 'NO_PATCH' in log,
            'price ₹499': 'Featured: Product price: ₹499\n' in t + '\n',
            'catalog slot aot': 'catalog slot: aot' in t,
            'bundled strings': 'Welcome (bundled strings v1)' in t,
            'bundled config': 'Shop (bundled config v1)' in t,
            'logo 4x4': 'logo 4x4' in t,
        })

        if not self.have('patch_v1'):
            self.record('ui_02_scenario_A_C', '4', 'Scenario A+C (patch v1)', 'BLOCKED', 'patch_v1.otp missing')
        else:
            log, ui = self.run_ui('ui_02_scenario_A_C', 'catalog', 'patch_v1')
            t = self.texts(ui)
            ui2 = self.dump_after_tap('ui_02_scenario_A_C', 'row-p1', ui)
            t2 = self.texts(ui2)
            self.check('ui_02_scenario_A_C', '4 A/C, 8', 'only feature_catalog patched; host app_models/shared_state/product_service reused', {
                'installed+loaded+confirmed': all(m in log for m in ('INSTALLED patch #1', 'LOADED patch #1', 'CONFIRMED')),
                'patched screen version': 'Catalogue (catalog v2 (patch 1) / product_service v1)' in t,
                'new widget (SaleBadge)': 'NEW: patched catalogue' in t,
                'unchanged dependency price ₹499': f'Flutter Handbook | Product price: ₹499 | ref {ref_p1}' in t,
                'tap callback -> host AppState cart + host globalCounter': 'selected (patch 1): Flutter Handbook, cart: 1, globalCounter: 1' in t2,
            })
            log2, ui3 = self.run_ui('ui_02b_restart_still_patched', 'home', reset=False)
            self.check('ui_02b_restart_still_patched', '4', 'cold restart keeps patch v1', {
                'slot from patch #1': 'catalog slot: patch #1 patch_v1' in self.texts(ui3),
            })

        if not self.have('patch_v2'):
            self.record('ui_03_scenario_B_price', '4 B, 8', 'Scenario B + UI price (patch v2)', 'BLOCKED', 'patch_v2.otp missing')
        else:
            log, ui = self.run_ui('ui_03_scenario_B_price', 'home', 'patch_v2')
            t = self.texts(ui)
            self.check('ui_03_scenario_B_price', '4 B, 8, 10', 'two interdependent packages patched together; ₹499 -> ₹399; asset overlay', {
                'loaded+confirmed': 'LOADED patch #2' in log and 'CONFIRMED' in log,
                'home price ₹399 (patched product_service via patched catalog)': 'Featured: Product price: ₹399' in t,
                'profile slot patched': 'profile slot: patch #2 patch_v2' in t,
                'overlay JSON (config) for unpatched widget': 'Shop (config from patch v2)' in t,
                'overlay localisation strings': 'Welcome (strings from patch v2)' in t,
                'overlay image replaced (8x2)': 'logo 8x2' in t,
            })
            log, ui = self.run_ui('ui_04_patched_screen_nav', 'catalog', reset=False)
            t = self.texts(ui)
            ui2 = self.dump_after_tap('ui_04_patched_screen_nav', 'row-p1', ui)
            t2 = self.texts(ui2)
            self.check('ui_04_patched_screen_nav', '8', 'patched StatefulWidget: FutureBuilder, StreamBuilder, animation, navigation', {
                'price ₹399 on catalogue': 'Flutter Handbook | Product price: ₹399' in t,
                'FutureBuilder resolved': 'p1 stock: in stock' in t,
                'StreamBuilder ticks': 'live ticks: 5' in t,
                'animated text present': 'Festival sale: 20% off books' in t,
                'patched navigation pushed detail route': ui2.get('route_stack_top') == 'detail (patch 2)',
                'detail content': 'Detail (patch 2): Flutter Handbook' in t2 and 'was ₹499, cart now 1' in t2,
            })
            log, ui = self.run_ui('ui_05_form_validation', 'profile', reset=False)
            t = self.texts(ui)
            self.check('ui_05_form_validation', '8', 'patched form validation', {
                'new rule': 'validate("ab")=Name must have at least 3 characters' in t,
                'valid name': 'validate("Asha")=null' in t,
            })

        if self.have('patch_v3'):
            log, ui = self.run_ui('ui_06_scenario_E', 'home', 'patch_v3')
            self.check('ui_06_scenario_E', '4 E', 'transitive change (patchable_utils) with its dependents', {
                'price ₹499.00': 'Featured: Product price: ₹499.00' in self.texts(ui),
            })
        else:
            self.record('ui_06_scenario_E', '4 E', 'transitive change', 'BLOCKED', 'patch_v3.otp missing')

        if self.have('patch_v3_stale'):
            log, ui = self.run_ui('ui_07_scenario_E_stale', 'home', 'patch_v3_stale')
            t = self.texts(ui) + '\n'
            self.check('ui_07_scenario_E_stale', '4 E', 'experiment: transitive change WITHOUT dependents stays invisible (stale)', {
                'module has new formatPrice': 'NOTE module formatPrice(49900)=₹499.00' in log,
                'screen still shows old price (stale host product_service)': 'Featured: Product price: ₹499\n' in t,
            })

        if self.have('patch_v4'):
            log, ui = self.run_ui('ui_08_scenario_D', 'catalog', 'patch_v4')
            t = self.texts(ui)
            self.check('ui_08_scenario_D', '4 D', 'third-party dependency crypto 3.0.6 -> 3.0.8 (renamed copy in module)', {
                'loaded': 'LOADED patch #4' in log,
                'module crypto copy works': 'NOTE module sha256("abc")=ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad' in log,
                'patched catalog with copied crypto': 'catalog (patch 4, crypto 3.0.8 copy)' in t and f'ref {ref_p1}' in t,
            })
            log2, ui2 = self.run_ui('ui_08b_host_crypto_after_D', 'home', reset=False)
            self.check('ui_08b_host_crypto_after_D', '4 D', "host's own crypto 3.0.6 (patch SHA-256 check) still works", {
                're-validated and loaded again': 'LOADED patch #4' in log2,
            })
        else:
            self.record('ui_08_scenario_D', '4 D', 'third-party dependency version change', 'BLOCKED', 'patch_v4.otp missing (did not compile)')

        if self.have('patch_v5'):
            log, ui = self.run_ui('ui_09_contract_change', 'home', 'patch_v5')
            self.check('ui_09_contract_change', '13.7', 'experiment: host contract (app_core) public API changed in a copy', {
                'slot refused (type mismatch)': 'catalog:IGNORED' in log,
                'host keeps AOT catalog': 'catalog slot: aot' in self.texts(ui),
            })

        # Part 13 sequences: A then B, back to A, rollback, repeated starts.
        if self.have('patch_v1', 'patch_v2'):
            seq = []
            _, ui = self.run_ui('seq_01', 'home', 'patch_v1'); seq.append(self.texts(ui))
            self.push_patch('patch_v2'); _, ui = self.run_ui('seq_02', 'home', reset=False); seq.append(self.texts(ui))
            self.push_patch('patch_v1'); _, ui = self.run_ui('seq_03', 'home', reset=False); seq.append(self.texts(ui))
            self.dev.touch(f'{INBOX}/ROLLBACK'); _, ui = self.run_ui('seq_04', 'home', reset=False); seq.append(self.texts(ui))
            _, ui = self.run_ui('seq_05', 'home', reset=False); seq.append(self.texts(ui))
            self.check('seq_13_patch_sequence', '13.1-13.3', 'v1 -> v2 (replaces, cumulative) -> v1 -> rollback -> restart', {
                'v1 active': 'catalog slot: patch #1' in seq[0],
                'v2 replaced v1': 'catalog slot: patch #2' in seq[1] and 'profile slot: patch #2' in seq[1],
                'back to v1 (v2 profile gone)': 'catalog slot: patch #1' in seq[2] and 'profile slot: aot' in seq[2],
                'rollback -> baseline': 'catalog slot: aot' in seq[3],
                'restart after rollback -> baseline': 'catalog slot: aot' in seq[4],
            })

    def suite_probes(self):
        names = ['probe_lang', 'probe_state', 'probe_ui', 'probe_plugins', 'probe_assets', 'probe_multi_a',
                 'probe_multi_a', 'probe_multi_b', 'probe_multi_dup', 'probe_multi_prefixed', 'probe_dynamic']
        self.dev.reset()
        self.dev.set_mode('home')
        pushed = []
        for i, n in enumerate(names, 1):
            if self.have(n):
                f = f'{i:02d}_{n}'
                self.dev.push(self.otp_file(n), f'{INBOX}/probes/{f}.otp')
                pushed.append(f)
            else:
                self.record(f'probe:{n}', '-', n, 'BLOCKED', 'module did not compile (see modules.tsv)')
        self.dev.start()
        log = self.dev.wait_log('PROBES_DONE', 300)
        self.save('probes/log.txt', log)
        self.dev.screenshot(self.out / 'probes' / 'screen.png')
        for f in pushed:
            r = self.dev.result(f'probe_{f}')
            self.save(f'probes/{f}.json', r or {})
            status = (r or {}).get('status')
            # Expected refusals (Scenario F): a second copy of a loaded module, and a different
            # module that defines an already-loaded library URI, must be refused safely.
            if f.startswith('07_') or f.endswith('multi_dup'):
                ok = status == 'LOAD_ERROR' and 'already loaded' in (r or {}).get('error', '')
                self.record(f'probe:{f}', '4 F', f'{f}: duplicate library refused safely (expected)', 'PASS' if ok else 'FAIL',
                            f'{status}: {(r or {}).get("error", "no result file")}')
                continue
            self.record(f'probe:{f}', '-', f'probe {f} ran', 'PASS' if status == 'RAN' else ('FAIL' if r else 'BLOCKED'),
                        '' if status == 'RAN' else f'{status}: {(r or {}).get("error", "no result file")}')
        # FFI alone: it may crash the process.
        if self.have('probe_ffi'):
            self.dev.reset(); self.dev.set_mode('home')
            self.dev.push(self.otp_file('probe_ffi'), f'{INBOX}/probes/01_probe_ffi.otp')
            self.dev.start()
            log = self.dev.wait_log('PROBES_DONE', 60)
            self.save('probes/ffi_log.txt', log)
            r = self.dev.result('probe_01_probe_ffi')
            self.save('probes/01_probe_ffi.json', r or {})
            self.record('probe:ffi', '9', 'FFI call from a bytecode module (process must survive)',
                        'PASS' if r and r.get('status') == 'RAN' else 'FAIL', json.dumps((r or {}).get('result', (r or {}).get('error')), ensure_ascii=False)[:300])

    def suite_crash(self):
        def steps(tid, patch, starts, wait=7.0, mode='home', push_at=0):
            self.dev.reset(); self.dev.set_mode(mode)
            logs = []
            for i in range(starts):
                if i == push_at and patch:
                    self.push_patch(patch)
                self.dev.start(wait)
                logs.append(self.dev.log())
                self.save(f'{tid}/start_{i + 1}.txt', logs[-1])
            return logs

        if not self.have('crash_ok'):
            self.record('crash_*', '12', 'crash suite', 'BLOCKED', 'crash modules missing')
            return
        L = steps('crash_01_valid', 'crash_ok', 2)
        self.check('crash_01_valid', '12.1', 'valid patch starts and is confirmed', {
            'loaded': 'LOADED patch #20' in L[0], 'confirmed': 'CONFIRMED' in L[0], 'no failure': 'FAILURE_COUNT' not in L[0] + L[1],
            'still active on restart': 'LOADED patch #20' in L[1]})

        L = steps('crash_02_throw_init', 'crash_throw', 4)
        self.push_patch('crash_throw'); self.dev.start(6); L.append(self.dev.log()); self.save('crash_02_throw_init/start_5_repush.txt', L[-1])
        self.check('crash_02_throw_init', '12.2, 12.8', 'module throws during initialisation', {
            'load failure caught, baseline runs': 'MODULE_LOAD_FAILED' in L[0] and 'FIRST_FRAME' in L[0],
            'count 1/2': 'count=1/2' in L[0], 'count 2/2 + rollback': 'count=2/2' in L[1] and 'ROLLED_BACK' in L[1],
            'then baseline': 'NO_PATCH' in L[2] and 'NO_PATCH' in L[3],
            'blacklisted on re-push': 'REJECTED' in L[4] and 'blacklisted' in L[4]})

        L = steps('crash_03_abort_before_frame', 'crash_abort_before_frame', 4)
        self.check('crash_03_abort_before_frame', '12.3, 12.10', 'process dies before first frame, repeatedly', {
            'start 1 died before first frame': 'TEST_CRASH' in L[0] and 'FIRST_FRAME' not in L[0],
            'start 2 detects unconfirmed start, counts 1/2, crashes again': 'UNCONFIRMED_START' in L[1] and 'count=1/2' in L[1] and 'FIRST_FRAME' not in L[1],
            'start 3 counts 2/2, blacklists, runs baseline': 'count=2/2' in L[2] and 'ROLLED_BACK' in L[2] and 'FIRST_FRAME' in L[2],
            'start 4 baseline (no loop)': 'NO_PATCH' in L[3] and 'FIRST_FRAME' in L[3]})
        exits = sorted(set(re.findall(r'LAST_EXIT (\S+)', '\n'.join(L))))
        self.record('crash_03b_exit_reasons', '12', 'Android exit reasons seen (ApplicationExitInfo)', 'PASS' if exits else 'FAIL', ', '.join(exits))

        L = steps('crash_04_abort_after_frame', 'crash_abort_after_frame', 4, wait=8)
        self.check('crash_04_abort_after_frame', '12.4', 'process dies after first frame, before confirmation', {
            'start 1 first frame then crash': 'FIRST_FRAME' in L[0] and 'TEST_CRASH' in L[0] and 'CONFIRMED' not in L[0],
            'count 1/2': 'count=1/2' in L[1], 'count 2/2 + rollback': 'count=2/2' in L[2] and 'ROLLED_BACK' in L[2],
            'baseline afterwards': 'NO_PATCH' in L[3]})

        L = steps('crash_05_build_error', 'crash_build_error', 3)
        ui = self.dev.result('ui_1')
        self.check('crash_05_build_error', '12.4', 'exception in build() of patched code', {
            'error caught + live fallback': 'LIVE_FALLBACK' in L[0] and 'count=1/2' in L[0],
            'second start: 2/2 + rollback': 'count=2/2' in L[1] and 'ROLLED_BACK' in L[1],
            'no double count of the same start': L[1].count('FAILURE_COUNT') == 1,
            'third start baseline': 'NO_PATCH' in L[2]})

        # 12.5 user/system kill before confirmation must not count as a failure.
        self.dev.reset(); self.dev.set_mode('home'); self.push_patch('crash_ok')
        self.dev.start(); time.sleep(1.0); self.dev.sh(f'am force-stop {PKG}')
        l1 = self.dev.log(); self.dev.start(7); l2 = self.dev.log()
        self.save('crash_06_killed_before_confirm/start_1.txt', l1); self.save('crash_06_killed_before_confirm/start_2.txt', l2)
        self.check('crash_06_killed_before_confirm', '12.5', 'app force-stopped before confirmation', {
            'first start loaded, not confirmed': 'LOADED patch #20' in l1 and 'CONFIRMED' not in l1,
            'second start: kill recognised, not counted': 'not counted' in l2 and 'FAILURE_COUNT' not in l2,
            'patch still active and confirmed': 'LOADED patch #20' in l2 and 'CONFIRMED' in l2})

        self.record('crash_07_device_restart', '12.6', 'device restarts during activation', 'NOT_TESTED',
                    "not run: would reboot the owner's personal phone; covered by design (attempt marker is fsync'ed)")

        variants = self.out / 'variants'
        if self.have('patch_v2'):
            subprocess.run([sys.executable, '-I', str(pathlib.Path(__file__).with_name('patch_variants.py')),
                            str(self.otp_file('patch_v2')), str(variants)], check=True, capture_output=True)
            for name, part, expect in [('partial_write', '12.7', 'REJECTED'), ('corrupt_manifest', '12.9', 'manifest is not valid JSON'),
                                       ('other_runtime', '13.9', 'module built for runtime'), ('other_baseline', '13.10', 'another baseline')]:
                self.dev.reset(); self.dev.set_mode('home')
                self.dev.push(variants / f'{name}.otp', f'{INBOX}/patch.otp'); self.dev.start(6); l = self.dev.log()
                self.save(f'crash_08_{name}/log.txt', l)
                self.check(f'crash_08_{name}', part, f'damaged/incompatible patch: {name}', {
                    'rejected with reason': 'REJECTED' in l and expect in l, 'baseline runs': 'NO_PATCH' in l and 'FIRST_FRAME' in l})
            L = steps('crash_09_unloadable_module', None, 0)
            self.dev.push(variants / 'unloadable_module.otp', f'{INBOX}/patch.otp')
            self.dev.start(6); l1 = self.dev.log(); self.dev.start(6); l2 = self.dev.log(); self.dev.start(6); l3 = self.dev.log()
            for i, l in enumerate((l1, l2, l3), 1):
                self.save(f'crash_09_unloadable_module/start_{i}.txt', l)
            self.check('crash_09a_unloadable_module_caught', '12.8', 'malformed bytecode (valid manifest): VM load error is catchable', {
                'VM load failure caught in Dart (no process abort)': 'MODULE_LOAD_FAILED' in l1 and 'FIRST_FRAME' in l1})
            self.check('crash_09b_unloadable_module_recovered', '12.8', 'malformed bytecode: crash guard recovers without a loop', {
                'counted': 'count=1/2' in l1 + l2, 'blacklisted after 2 failed starts': 'ROLLED_BACK' in l1 + l2 + l3,
                'baseline at the end': 'NO_PATCH' in l3 and 'FIRST_FRAME' in l3})
            # 12.7b torn write of the STORED patch (test hook truncates the private copy).
            self.dev.reset(); self.dev.set_mode('home'); self.push_patch('patch_v2'); self.dev.start(7)
            self.dev.touch(f'{INBOX}/STORE_TRUNCATE'); self.dev.start(6); l = self.dev.log()
            self.save('crash_10_stored_patch_torn/log.txt', l)
            self.check('crash_10_stored_patch_torn', '12.7', 'stored patch truncated (torn write)', {
                'detected at re-validation': 'STORED_PATCH_INVALID' in l, 'baseline runs': 'FIRST_FRAME' in l})
            # 12.11 rollback followed by repeated cold starts.
            self.dev.reset(); self.dev.set_mode('home'); self.push_patch('patch_v2'); self.dev.start(7)
            self.dev.touch(f'{INBOX}/ROLLBACK')
            ls = []
            for i in range(3):
                self.dev.start(6); ls.append(self.dev.log()); self.save(f'crash_11_rollback_restarts/start_{i + 1}.txt', ls[-1])
            self.check('crash_11_rollback_restarts', '12.11', 'rollback then 3 cold starts', {
                'rollback logged': 'ROLLBACK requested' in ls[0], 'baseline every start': all('NO_PATCH' in l and 'FIRST_FRAME' in l for l in ls)})

    def suite_perf(self):
        def starts(tid, patch, n=10):
            self.dev.reset(); self.dev.set_mode('home')
            if patch:
                self.push_patch(patch)
            self.dev.start(7)  # install + confirm, not measured
            total, ff, load = [], [], []
            for _ in range(n):
                t = self.dev.start()
                b = self.dev.wait_result('boot', 15) or {}
                total.append(t); ff.append(b.get('main_to_first_frame_ms')); load.append(b.get('module_load_ms'))
                time.sleep(4 if patch else 1)  # let the patched start confirm
            mem = self.dev.sh(f'dumpsys meminfo {PKG}')
            pss = re.search(r'TOTAL PSS:\s*(\d+)', mem) or re.search(r'TOTAL\s+(\d+)', mem)
            boot = self.dev.result('boot') or {}
            data = {'am_start_total_ms': total, 'main_to_first_frame_ms': ff, 'module_load_ms': load,
                    'total_pss_kb': int(pss.group(1)) if pss else None, 'app_memory': boot.get('memory')}
            self.save(f'perf/{tid}.json', data)
            ok = [v for v in total if v]
            self.record(f'perf:{tid}', '11', f'cold start x{n} ({tid})', 'PASS' if len(ok) == n else 'FAIL',
                        f'am start TotalTime median {statistics.median(ok) if ok else "?"} ms; PSS {data["total_pss_kb"]} kB')

        starts('startup_no_patch', None)
        if self.have('patch_v2'):
            starts('startup_patch_v2', 'patch_v2')
            # after rollback
            self.dev.touch(f'{INBOX}/ROLLBACK'); self.dev.start(5)
            total = []
            for _ in range(10):
                total.append(self.dev.start()); time.sleep(1)
            self.save('perf/startup_after_rollback.json', {'am_start_total_ms': total})
            self.record('perf:startup_after_rollback', '11', 'cold start x10 after rollback', 'PASS' if all(total) else 'FAIL',
                        f'median {statistics.median([t for t in total if t])} ms')

        size = re.search(r'(\d+)x(\d+)', self.dev.sh('wm size'))
        w, h = (int(size.group(1)), int(size.group(2))) if size else (720, 1600)

        def frames(tid, patch):
            self.dev.reset()
            if patch:
                self.push_patch(patch); self.dev.set_mode('home'); self.dev.start(7)
            self.dev.set_mode('feed:20')
            self.dev.start(2)
            end = time.time() + 18
            while time.time() < end:
                self.dev.sh(f'input swipe {w // 2} {int(h * 0.8)} {w // 2} {int(h * 0.25)} 120')
                time.sleep(0.25)
            r = self.dev.wait_result('frames', 15)
            self.save(f'perf/{tid}.json', r or {})
            self.record(f'perf:{tid}', '11', f'scrolling frame timings ({tid})', 'PASS' if r else 'FAIL',
                        json.dumps({k: (r or {}).get(k) for k in ('frames', 'missed_budget_frames', 'refresh_hz')}))

        frames('frames_no_patch', None)
        if self.have('patch_v2'):
            frames('frames_patch_v2', 'patch_v2')

        if self.have('probe_bench'):
            self.dev.reset(); self.dev.set_mode('home')
            self.dev.push(self.otp_file('probe_bench'), f'{INBOX}/probes/01_probe_bench.otp')
            self.dev.start()
            self.dev.wait_log('PROBES_DONE', 600)
            r = self.dev.result('probe_01_probe_bench')
            self.save('perf/bench.json', r or {})
            self.record('perf:bench', '11', 'execution benchmarks AOT vs interpreted', 'PASS' if r and r.get('status') == 'RAN' else 'FAIL',
                        '' if r and r.get('status') == 'RAN' else str((r or {}).get('error')))
        else:
            self.record('perf:bench', '11', 'execution benchmarks', 'BLOCKED', 'probe_bench did not compile')

    def suite_compat(self, release2: pathlib.Path, baseline_apk: pathlib.Path):
        """13.10: a new full release is installed over a patched install."""
        if not release2 or not release2.exists():
            self.record('compat_new_release', '13.10', 'new full release over an active patch', 'BLOCKED', 'no --release2-apk given')
            return
        self.dev.reset(); self.dev.set_mode('home'); self.push_patch('patch_v2'); self.dev.start(7)
        before = self.dev.log()
        r = self.dev.adb('install', '-r', str(release2), timeout=300)
        self.dev.set_mode('home'); self.dev.start(6); after = self.dev.log()
        self.save('compat_new_release/before.txt', before); self.save('compat_new_release/after.txt', after)
        self.check('compat_new_release', '13.10', 'new full release over an active patch', {
            'installed over (data kept)': r.returncode == 0, 'patch active before': 'LOADED patch #2' in before,
            'old patch refused after update': 'STORED_PATCH_INVALID' in after and 'another baseline' in after,
            'new release runs baseline': 'FIRST_FRAME' in after})
        # Restore the main baseline APK for any later run.
        self.dev.adb('install', '-r', str(baseline_apk), timeout=300)

    def finish(self):
        self.save('results.json', self.rows)
        lines = ['id\tpart\tstatus\ttitle\tdetail'] + [f"{r['id']}\t{r['part']}\t{r['status']}\t{r['title']}\t{r['detail']}" for r in self.rows]
        self.save('results.tsv', '\n'.join(lines) + '\n')
        counts = {s: sum(r['status'] == s for r in self.rows) for s in ('PASS', 'FAIL', 'BLOCKED', 'NOT_TESTED')}
        print('SUMMARY', json.dumps(counts))
        return counts


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--baseline', required=True)
    ap.add_argument('--otp', required=True)
    ap.add_argument('--results', required=True)
    ap.add_argument('--suites', default='ui,probes,crash,perf')
    ap.add_argument('--serial', default=None)
    ap.add_argument('--release2-apk', default=None)
    ap.add_argument('--no-install', action='store_true')
    a = ap.parse_args()
    serial = a.serial or subprocess.run(['adb', 'get-serialno'], capture_output=True, text=True).stdout.strip()
    dev = Device(serial)
    base = pathlib.Path(a.baseline)
    dev.apk = base / 'app-release.apk'
    dev.expected_hash = hashlib.sha256(dev.apk.read_bytes()).hexdigest()
    suite = Suite(dev, pathlib.Path(a.otp), pathlib.Path(a.results))
    info = {'serial': serial, 'model': dev.sh('getprop ro.product.model').strip(), 'android': dev.sh('getprop ro.build.version.release').strip(),
            'sdk': dev.sh('getprop ro.build.version.sdk').strip(), 'abi': dev.sh('getprop ro.product.cpu.abi').strip(),
            'baseline': json.loads((base / 'baseline.json').read_text()), 'started': time.strftime('%Y-%m-%d %H:%M:%S')}
    if not a.no_install:
        dev.install()
    info['apk_installed'] = dev.apk_state()
    suite.save('device.json', info)
    for s in a.suites.split(','):
        if s == 'compat':
            suite.suite_compat(pathlib.Path(a.release2_apk) if a.release2_apk else None, base / 'app-release.apk')
        else:
            getattr(suite, f'suite_{s}')()
    final = dev.apk_hash()
    if 'compat' not in a.suites:
        suite.record('apk_unchanged', '-', 'installed APK is byte-identical to the baseline APK after all tests (patches never modify it)',
                     'PASS' if final == dev.expected_hash else 'FAIL', final)
    suite.finish()


if __name__ == '__main__':
    main()
