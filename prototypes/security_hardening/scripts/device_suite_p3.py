# Copyright 2026 The Punit Authors
# SPDX-License-Identifier: Apache-2.0
"""Phase 3 physical-device security suite (Android, adb). Standard library only.

    python3 -I scripts/device_suite_p3.py --baseline <dir> --artifacts <dir> --results <dir>
        [--serial S] [--suites install,crash,corpus] [--release2-apk <apk>] [--no-install]

Every test is PASS / FAIL / BLOCKED / NOT_TESTED. A rejection only passes when (1) the expected
reason was logged, (2) the main process is still alive, and (3) the previously active patch (or
the baseline) is still the one in use. App state is reset with the host's test-only RESET_STORE
marker (`pm clear` is refused on the test phone; reinstalling triggers Play Protect).
"""
import argparse
import hashlib
import json
import pathlib
import re
import subprocess
import time

PKG = 'io.github.punitsoni22.compat_host'
ACTIVITY = f'{PKG}/.MainActivity'
FILES = f'/sdcard/Android/data/{PKG}/files'
INBOX = f'{FILES}/inbox'
RES = f'{FILES}/results'


class Device:
    def __init__(self, serial):
        self.serial = serial

    def adb(self, *a, timeout=180, text=True):
        return subprocess.run(['adb', '-s', self.serial, *a], capture_output=True, text=text, timeout=timeout)

    def sh(self, cmd, timeout=180):
        return self.adb('shell', cmd, timeout=timeout).stdout

    def push(self, local, remote):
        self.sh(f'mkdir -p {remote.rsplit("/", 1)[0]}')
        r = self.adb('push', str(local), remote)
        if r.returncode:
            raise RuntimeError(r.stderr)

    def touch(self, name):
        self.sh(f'mkdir -p {INBOX} && touch {INBOX}/{name}')

    def reset(self):
        self.sh(f'am force-stop {PKG}')
        self.sh(f'rm -rf {INBOX} {RES}')
        self.sh(f'mkdir -p {INBOX} && echo home > {INBOX}/mode && touch {INBOX}/RESET_STORE')

    def start(self, wait=6.0):
        self.sh(f'am force-stop {PKG}')
        self.sh(f'rm -rf {RES}')
        self.adb('logcat', '-c')
        out = self.sh(f'am start -W -n {ACTIVITY}')
        time.sleep(wait)
        m = re.search(r'TotalTime:\s*(\d+)', out)
        return int(m.group(1)) if m else None

    def log(self):
        out = self.adb('logcat', '-d', '-v', 'brief').stdout
        keep = [l for l in out.splitlines() if '[compat]' in l or ('Fatal signal' in l and PKG[-12:] in l)]
        return '\n'.join(re.sub(r'^.*?\[compat\]', '[compat]', l) for l in keep)

    def wait_log(self, marker, timeout):
        end = time.time() + timeout
        while time.time() < end:
            l = self.log()
            if marker in l:
                return l
            time.sleep(1)
        return self.log()

    def result(self, name):
        r = self.adb('exec-out', f'cat {RES}/{name}.json')
        try:
            return json.loads(r.stdout)
        except json.JSONDecodeError:
            return None

    def main_pid(self):
        out = self.sh(f'pidof {PKG}').split()
        return out[0] if out else None

    def apk_hash(self):
        path = self.sh(f'pm path {PKG}').strip().replace('package:', '')
        return self.sh(f'sha256sum {path}').split(' ')[0]


class Suite:
    def __init__(self, dev, art, out):
        self.d, self.art, self.out, self.rows = dev, art, out, []
        out.mkdir(parents=True, exist_ok=True)

    def record(self, tid, part, title, status, detail=''):
        self.rows.append({'id': tid, 'part': part, 'title': title, 'status': status, 'detail': detail})
        print(f'{status:11} {tid:34} {title}' + (f' :: {detail}' if detail else ''), flush=True)

    def check(self, tid, part, title, conds):
        bad = [k for k, ok in conds.items() if not ok]
        self.record(tid, part, title, 'FAIL' if bad else 'PASS', ('failed: ' + '; '.join(bad)) if bad else '')

    def save(self, name, text):
        p = self.out / name
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(text if isinstance(text, str) else json.dumps(text, indent=2))

    def push(self, name, as_name='patch.otp'):
        self.d.push(self.art / f'{name}.otp', f'{INBOX}/{as_name}')

    def run(self, tid, n=1, wait=7.0, push=None, before=None):
        """n cold starts; `push` is pushed before the first one. Returns the list of logs."""
        logs = []
        for i in range(n):
            if i == 0 and push:
                self.push(push)
            if i == 0 and before:
                before()
            self.d.start(wait)
            logs.append(self.d.log())
            self.save(f'{tid}/start_{i + 1}.txt', logs[-1])
        return logs

    def slot(self, log):
        m = re.findall(r'APPLIED (.*)', log)
        loaded = re.findall(r'LOADED patch #(\d+) (\w+)', log)
        return (loaded[-1][0] if loaded else 'baseline')

    def ensure_v2_active(self, tid):
        self.d.reset()
        self.run(f'{tid}/setup', push='v1')
        l = self.run(f'{tid}/setup2', push='v2')[0]
        return 'LOADED patch #2' in l and 'CONFIRMED' in l

    # --- install path ----------------------------------------------------------------------------
    def suite_install(self):
        d = self.d
        d.reset()
        l1 = self.run('p3_01_signed_patch', push='v1')[0]
        self.check('p3_01_signed_patch', '12.1, 3.2', 'normal signed patch: verified, isolated load OK, activated', {
            'isolated verification OK': 'ISOLATED_VERIFY status=OK' in l1,
            'installed + loaded + confirmed': all(x in l1 for x in ('INSTALLED patch #1', 'LOADED patch #1', 'CONFIRMED')),
            'states DOWNLOADED -> VERIFIED -> PROBATIONARY -> ACTIVE': all(f'-> {x}' in l1 for x in ('DOWNLOADED', 'VERIFIED', 'PROBATIONARY', 'ACTIVE')),
        })
        # Phase 3C isolation evidence (probes recorded by the verifier process before loading).
        iso = re.search(r'ISOLATION process=(\S+) probes="([^"]*)"', l1)
        probes = dict(kv.split('=', 1) for kv in iso.group(2).split(';') if '=' in kv) if iso else {}
        self.save('p3_isolation/probes.json', {'process': iso and iso.group(1), 'probes': probes,
                                               'fallback': 'ISOLATION_FALLBACK' in l1})
        self.check('p3_isolation', '3C-isolation', 'verifier ran in an Android isolated process without app data access', {
            'isolated process used (no fallback)': iso is not None and iso.group(1) == 'otaverify_iso' and 'ISOLATION_FALLBACK' not in l1,
            'separate UID': probes.get('uid') not in (None, probes.get('app_uid')),
            'Process.isIsolated() true': probes.get('is_isolated') == 'true',
            'cannot read the private patch store': probes.get('read_private_state', '').startswith('DENIED'),
            'cannot write the private patch store': probes.get('write_private_store', '').startswith('DENIED'),
            'cannot read the app external inbox': probes.get('read_external_inbox', '').startswith('DENIED'),
            'cannot create a network socket': probes.get('network_socket', '').startswith('DENIED'),
        })
        l = self.run('p3_02_cold_restart', n=2)
        self.check('p3_02_cold_restart', '12.13', 'repeated activation / cold restarts re-verify and load', {
            'loaded on both starts': all('LOADED patch #1' in x and 'CONFIRMED' in x for x in l),
            'no re-install': all('INSTALLED' not in x for x in l)})
        l = self.run('p3_03_upgrade', push='v2')[0]
        self.check('p3_03_upgrade', '13', 'newer patch v2 replaces v1', {'v2 active': 'LOADED patch #2' in l})

        negatives = [
            ('neg_tampered_module', '12.2, 3.3', 'tampered patch (bytecode changed after signing)', 'bad_hash'),
            ('neg_wrong_key', '12.3', 'wrong signature (trusted key id, other private key)', 'bad_signature'),
            ('neg_untrusted_key', '3.3', 'signing key not trusted by this build', 'unknown_key'),
            ('neg_wrong_baseline', '12.4', 'built for another libapp.so (baseline)', 'wrong_baseline'),
            ('neg_wrong_engine', '3.3', 'built for another engine revision', 'wrong_runtime'),
            ('neg_expired', '3.3', 'expired patch', 'expired'),
            ('neg_partial_download', '8.12', 'half download, cut inside the module', 'wrong_size'),
            ('neg_partial_header', '8.12', 'half download, cut inside the manifest', 'truncated'),
            ('v1', '3.3, 11', 'replayed older patch (v1 while v2 active)', 'replay'),
            ('malformed_signed', '4, 12.7', 'validly signed MALFORMED bytecode (install path)', 'isolated_'),
            ('ffi_unguarded_signed', '5, 12.5', 'validly signed FFI module (guard bypassed)', 'isolated_'),
            ('crash_throw_init', '12.8', 'module throws during initialisation', 'isolated_rejected'),
            ('crash_abort_in_entry', '12.8', 'module aborts the process during initialisation', 'isolated_crashed'),
        ]
        for name, part, title, code in negatives:
            pid_before = None
            d.start(5)  # v2 running
            pid_before = d.main_pid()
            l = self.run(f'p3_neg_{name}', push=name, wait=9)[0]
            pid_after = d.main_pid()
            self.check(f'p3_neg_{name}', part, f'{title}: rejected safely', {
                # exact code, or a prefix such as 'isolated_' (any isolated outcome)
                f'rejected [{code}]': f'REJECTED incoming patch [{code}' + ('' if code.endswith('_') else ']') in l,
                'main process alive after the check': pid_after is not None and 'FIRST_FRAME' in l,
                'previous patch v2 still active': 'LOADED patch #2' in l,
                'no install of the bad patch': 'INSTALLED' not in l,
            })
        l = self.run('p3_neg_blacklisted_again', push='malformed_signed', wait=8)[0]
        self.check('p3_neg_blacklisted_again', '8.15', 'blacklisted patch delivered again', {
            'refused as blacklisted (no isolated run)': 'blacklisted' in l and 'ISOLATED_VERIFY' not in l,
            'v2 still active': 'LOADED patch #2' in l})

        # Revocation of the active patch (signed list): falls back to the previous confirmed patch.
        l = self.run('p3_revocation', push=None, before=lambda: self.push('revoke_v2', 'revocations.otp'))[0]
        self.check('p3_revocation', '3.3, 9', 'signed revocation list revokes the active patch v2', {
            'list applied': 'REVOCATIONS applied' in l,
            'v2 refused at re-verification': 'STORED_PATCH_INVALID [revoked]' in l,
            'previous confirmed patch v1 restored': 'RESTORED_PREVIOUS' in l and 'LOADED patch #1' in l})
        l = self.run('p3_revocation_replay', push=None, before=lambda: self.push('revoke_v2', 'revocations.otp'))[0]
        self.check('p3_revocation_replay', '3.3', 'revocation list replayed', {'refused as replay': 'REJECTED revocation list [replay]' in l})

        # 8.10 Process killed during activation (after staging, before activation).
        d.reset()
        self.run('p3_kill_setup', push='v1')
        l1 = self.run('p3_kill_during_activation', push='v3_for_kill', before=lambda: d.touch('KILL_DURING_ACTIVATION'), wait=8)[0]
        l2 = self.run('p3_kill_during_activation_after', wait=7)[0]
        self.check('p3_kill_during_activation', '8.10', 'process killed during activation', {
            'killed after staging': 'TEST_HOOK killing the process during activation' in l1 and 'FIRST_FRAME' not in l1,
            'leftover cleaned on next start': 'LEFTOVER staging.otp' in l2,
            'previous patch v1 still active': 'LOADED patch #1' in l2,
        })
        l3 = self.run('p3_kill_then_new_patch', push='v4_after_kill')[0]
        self.check('p3_kill_then_new_patch', '8.10', 'a newer patch installs normally afterwards', {'v4 active': 'LOADED patch #4' in l3})

        # 8.12 stored patch torn on disk.
        l = self.run('p3_stored_torn', before=lambda: d.touch('STORE_TRUNCATE'))[0]
        self.check('p3_stored_torn', '8.12', 'stored active patch truncated on disk', {
            'detected': 'STORED_PATCH_INVALID' in l, 'previous confirmed patch v1 restored': 'RESTORED_PREVIOUS' in l and 'LOADED patch #1' in l})

        # 12.11/12.12 rollback and cold restart after rollback.
        l = self.run('p3_rollback', n=3, before=lambda: d.touch('ROLLBACK'))
        self.check('p3_rollback', '12.11, 12.12', 'rollback, then cold restarts', {
            'rollback logged': 'ROLLBACK requested' in l[0],
            'baseline on every start': all('NO_PATCH' in x and 'FIRST_FRAME' in x for x in l)})

    # --- crash guard (patches that pass verification and fail at runtime) -------------------------
    def suite_crash(self):
        d = self.d
        for name, part, title, needs_after in [
            ('crash_abort_when_logged_in', '12.9', 'crash before the first frame (state-dependent bug)', False),
            ('crash_abort_after_frame', '12.10', 'crash after the first frame, before confirmation', True),
            ('crash_throw_when_logged_in', '8.7', 'exception in build() (state-dependent bug)', False),
        ]:
            ok = self.ensure_v2_active(f'p3_{name}')
            l = self.run(f'p3_{name}', n=4, push=name, wait=8)
            text = '\n'.join(l)
            self.check(f'p3_{name}', part, f'{title}: passes verification, crash guard rolls back', {
                'v2 active before': ok,
                'passed isolated verification and installed': 'ISOLATED_VERIFY status=OK' in l[0] and 'INSTALLED patch #' in l[0],
                'counted 1/2 then 2/2': 'count=1/2' in text and 'count=2/2' in text,
                'blacklisted': 'BLACKLISTED' in text,
                'previous confirmed patch v2 restored and running': 'RESTORED_PREVIOUS' in text and 'LOADED patch #2' in l[-1],
                'no crash loop (last start stable)': 'FIRST_FRAME' in l[-1] and 'TEST_CRASH' not in l[-1],
            })
        # Phase 3C: failures AFTER the start was confirmed (health check passed).
        for name, title, mode in [
            ('crash_abort_after_confirm', 'crash after health confirmation', 'home'),
            ('crash_abort_on_navigation', 'crash after navigation (catalogue opened)', 'catalog'),
            ('crash_abort_in_async', 'crash during async work after confirmation', 'home'),
        ]:
            ok = self.ensure_v2_active(f'p3c_{name}')
            d.sh(f'echo {mode} > {INBOX}/mode')
            l = self.run(f'p3c_{name}', n=4, push=name, wait=14)
            d.sh(f'echo home > {INBOX}/mode')
            text = '\n'.join(l)
            self.check(f'p3c_{name}', '3C-crash', f'{title}: attributed, repeated crash rolls back', {
                'v2 active before': ok,
                'first start confirmed (ACTIVE) before the crash': '-> ACTIVE' in l[0] and 'TEST_CRASH' in l[0],
                'crash attributed after confirmation': 'after confirmation' in text and 'kind=crash' in text,
                'SUSPECTED_FAILURE then ROLLED_BACK then BLACKLISTED': all(f'-> {x}' in text for x in ('SUSPECTED_FAILURE', 'ROLLED_BACK', 'BLACKLISTED')),
                'previous confirmed patch v2 restored': 'RESTORED_PREVIOUS' in text and 'LOADED patch #2' in l[-1],
                'restart after rollback stable': 'FIRST_FRAME' in l[-1] and 'TEST_CRASH' not in l[-1] and 'TEST_CRASH' not in l[-2],
            })
        # OS eviction after confirmation: SIGKILL from outside (as the low-memory killer does).
        ok = self.ensure_v2_active('p3c_os_eviction')
        # Needs a userdebug/emulator image ('su'); never restarts adbd as root (that would make the
        # app's external test folders root-owned).
        if 'uid=0' not in d.sh('su 0 id 2>&1'):
            self.record('p3c_os_eviction', '3C-crash', 'process killed by the system (SIGKILL) after confirmation',
                        'NOT_TESTED', 'no root (su) on this device: SIGKILL from outside cannot be simulated')
        else:
            d.start(7)
            pid = d.main_pid()
            d.sh(f'su 0 kill -9 {pid}')
            time.sleep(2)
            l = self.run('p3c_os_eviction', wait=7)[0]
            self.check('p3c_os_eviction', '3C-crash', 'process killed by the system (SIGKILL) after confirmation', {
                'v2 active before': ok, 'attributed as eviction, not counted': 'kind=osEviction' in l and 'FAILURE_COUNT' not in l,
                'v2 still active': 'LOADED patch #2' in l})
        # Force-stop after confirmation is not counted either.
        l = self.run('p3c_force_stop', wait=7)[0]
        self.check('p3c_force_stop', '3C-crash', 'force-stop after confirmation', {
            'attributed as force-stop, not counted': 'kind=forceStop' in l and 'FAILURE_COUNT' not in l,
            'v2 still active': 'LOADED patch #2' in l})
        # 12.5 killed before confirmation (user force-stop) is not counted.
        d.reset()
        self.push('crash_ok')
        d.start(0)
        # Stop the app inside the window between LOADED and CONFIRMED (confirmation is 3 s later).
        l1 = d.wait_log('LOADED patch', 30)
        d.sh(f'am force-stop {PKG}')
        d.start(7)
        l2 = d.log()
        self.save('p3_killed_before_confirm/start_1.txt', l1)
        self.save('p3_killed_before_confirm/start_2.txt', l2)
        self.check('p3_killed_before_confirm', '12.5', 'app force-stopped before confirmation', {
            'not counted': 'not counted' in l2 and 'FAILURE_COUNT' not in l2, 'patch confirmed next start': 'CONFIRMED' in l2})
        self.record('p3_device_restart', '8.11', 'device restarts during activation', 'NOT_TESTED',
                    'phone reboot tests are excluded by the owner; staging/attempt files are written with fsync + rename')

    # --- Phase 3C certificates, rotation, revocation, toolchain ----------------------------------
    def suite_cert(self):
        d = self.d
        d.reset()
        l = self.run('p3c_cert_signed', push='cert_v1_signer_a')[0]
        self.check('p3c_cert_signed', '3C-signing', 'patch signed by a root-certified key', {
            'installed + loaded + confirmed': all(x in l for x in ('INSTALLED patch #1', 'LOADED patch #1', 'CONFIRMED'))})
        for name, code, title in [
            ('cert_neg_other_env', 'wrong_environment', 'certificate for another environment'),
            ('cert_neg_other_root', 'bad_certificate_signature', 'certificate signed by another root key'),
            ('cert_neg_unauthorised_rotation', 'untrusted_root', 'unauthorised rotation (signer key certifies a key)'),
            ('cert_neg_no_cert', 'unknown_key', 'new key without a certificate'),
            ('tc_neg_other_compiler', 'wrong_toolchain', 'patch built with another compiler (consistent record)'),
            ('tc_neg_forged_id', 'bad_toolchain', 'toolchain id does not match its fields'),
        ]:
            l = self.run(f'p3c_{name}', push=name, wait=8)[0]
            self.check(f'p3c_{name}', '3C-signing', f'{title}: rejected', {
                # exact code, or a prefix such as 'isolated_' (any isolated outcome)
                f'rejected [{code}]': f'REJECTED incoming patch [{code}' + ('' if code.endswith('_') else ']') in l,
                'never reached the verifier process or loader': 'ISOLATED_VERIFY' not in l,
                'previous patch #1 still active': 'LOADED patch #1' in l and 'FIRST_FRAME' in l})
        l = self.run('p3c_rotation', push='cert_v2_rotated_signer_b')[0]
        self.check('p3c_rotation', '3C-signing', 'key rotation: newly certified key accepted without a new store build', {
            'v2 by signer-b active': 'LOADED patch #2' in l and 'CONFIRMED' in l})
        l = self.run('p3c_old_key_revoked', push='cert_neg_old_key_revoked',
                     before=lambda: self.push('revoke_cert_101', 'revocations.otp'), wait=8)[0]
        self.check('p3c_old_key_revoked', '3C-signing', 'old key after rotation + root-signed revocation of its certificate', {
            'root-signed revocation applied': 'REVOCATIONS applied' in l and 'cert_serials=1' in l,
            'old key refused [revoked_certificate]': 'REJECTED incoming patch [revoked_certificate]' in l,
            'rotated patch #2 still active': 'LOADED patch #2' in l})
        l = self.run('p3c_revocation_replay', before=lambda: self.push('revoke_cert_101', 'revocations.otp'))[0]
        self.check('p3c_revocation_replay', '3C-signing', 'replayed revocation list', {
            'refused as replay': 'REJECTED revocation list [replay]' in l})

    # --- malformed bytecode / security corpus (verify-only, never activated) -----------------------
    def suite_corpus(self):
        d = self.d
        corpus = self.art / 'corpus' / 'otp'
        files = sorted(corpus.glob('*.otp'))
        d.reset()
        for f in files:
            d.push(f, f'{INBOX}/verify/{f.name}')
        d.start(3)
        boot = None
        for _ in range(20):
            boot = d.result('boot')
            if boot:
                break
            time.sleep(1)
        log = d.wait_log('VERIFY_ONLY_DONE', 900)
        self.save('corpus/log.txt', log)
        res = (d.result('verify_results') or {})
        self.save('corpus/verify_results.json', res)
        results = res.get('results', {})
        meta = json.loads((self.art / 'corpus' / 'bc' / 'corpus.json').read_text())
        alive = d.main_pid()
        same = boot and str(boot.get('pid')) == str(res.get('pid')) and str(res.get('pid')) == str(alive)
        self.check('p3_corpus_main_alive', '4, 10', f'main process survived all {len(files)} corpus files (verify-only)', {
            'all files processed': len(results) == len(files) and 'VERIFY_ONLY_DONE' in log,
            'same main pid from start to end': bool(same),
        })
        expect_crypto = {'A01_untrusted_key': 'unknown_key', 'A02_wrong_app': 'wrong_app', 'A03_wrong_baseline': 'wrong_baseline',
                         'A04_wrong_engine': 'wrong_runtime', 'A05_expired': 'expired', 'A07_tampered_module': 'bad_hash',
                         'A08_tampered_manifest': 'bad_signature', 'A09_truncated_download': 'wrong_size', 'A10_trusted_id_wrong_key': 'bad_signature'}
        for name, r in sorted(results.items()):
            if name in ('A00_control_valid', 'A06_second_trusted_key'):
                self.check(f'corpus:{name}', '3', f'{name}: accepted', {'crypto OK + isolated OK': r.get('crypto') == 'OK' and r.get('status') == 'OK'})
            elif name in expect_crypto:
                self.check(f'corpus:{name}', '3.3', f'{name}: rejected before any load', {
                    f'crypto rejected [{expect_crypto[name]}]': r.get('crypto') == 'REJECTED' and r.get('code') == expect_crypto[name],
                    'never loaded': r.get('status') == 'NOT_RUN'})
            elif name.startswith('R'):
                # Phase 3C permanent regression: refused by the in-VM bytecode verifier (clean
                # error, verifier process alive until it reports), never CRASHED.
                self.check(f'corpus:{name}', '3C', f'{name}: dangerous module refused by the VM verifier', {
                    'crypto OK (validly signed)': r.get('crypto') == 'OK',
                    'isolated REJECTED (not CRASHED)': r.get('status') == 'REJECTED',
                    'reason is bytecode verification': 'Bytecode verification failed' in str(r.get('detail'))})
            else:
                # B*/C*: validly signed, malformed or unsupported. Must never be accepted as OK.
                st = r.get('status')
                status = 'PASS' if (r.get('crypto') == 'OK' and st in ('CRASHED', 'REJECTED', 'TIMEOUT')) else 'FAIL'
                self.record(f'corpus:{name}', '4', f'{name}: signed but malformed -> refused safely',
                            status, f"isolated={st}; {str(r.get('detail'))[:120]}")
        self.save('corpus/meta.json', meta)

    def suite_release(self, apk2, apk1):
        d = self.d
        if not apk2 or not apk2.exists():
            self.record('p3_new_store_release', '12.14', 'new store release over an active patch', 'BLOCKED', 'no --release2-apk')
            return
        ok = self.ensure_v2_active('p3_new_store_release')
        r = d.adb('install', '-r', str(apk2), timeout=300)
        l = self.run('p3_new_store_release', wait=7)[0]
        self.check('p3_new_store_release', '12.14, 8.16', 'new store release installed while a patch is active', {
            'v2 active before': ok, 'update installed (data kept)': r.returncode == 0,
            'old patch refused for the new release': 'STORED_PATCH_INVALID [wrong_release]' in l,
            'new release runs its own code': 'NO_PATCH' in l and 'FIRST_FRAME' in l})
        d.adb('install', '-r', str(apk1), timeout=300)

    def finish(self):
        self.save('results.json', self.rows)
        self.save('results.tsv', 'id\tpart\tstatus\ttitle\tdetail\n' + ''.join(
            f"{r['id']}\t{r['part']}\t{r['status']}\t{r['title']}\t{r['detail']}\n" for r in self.rows))
        c = {s: sum(r['status'] == s for r in self.rows) for s in ('PASS', 'FAIL', 'BLOCKED', 'NOT_TESTED')}
        print('SUMMARY', json.dumps(c))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--baseline', required=True)
    ap.add_argument('--artifacts', required=True)
    ap.add_argument('--results', required=True)
    ap.add_argument('--serial')
    ap.add_argument('--suites', default='install,crash,corpus,cert')
    ap.add_argument('--release2-apk')
    ap.add_argument('--no-install', action='store_true')
    a = ap.parse_args()
    serial = a.serial or subprocess.run(['adb', 'get-serialno'], capture_output=True, text=True).stdout.strip()
    d = Device(serial)
    base = pathlib.Path(a.baseline)
    apk = base / 'app-release.apk'
    want = hashlib.sha256(apk.read_bytes()).hexdigest()
    if not a.no_install:
        r = d.adb('install', '-r', str(apk), timeout=300)
        if r.returncode:
            raise SystemExit(f'install failed: {r.stderr}')
    s = Suite(d, pathlib.Path(a.artifacts), pathlib.Path(a.results))
    s.save('device.json', {'model': d.sh('getprop ro.product.model').strip(), 'android': d.sh('getprop ro.build.version.release').strip(),
                           'abi': d.sh('getprop ro.product.cpu.abi').strip(), 'baseline': json.loads((base / 'baseline.json').read_text()),
                           'apk_sha256_installed': d.apk_hash()})
    for name in a.suites.split(','):
        if name == 'release':
            s.suite_release(pathlib.Path(a.release2_apk) if a.release2_apk else None, apk)
        else:
            getattr(s, f'suite_{name}')()
    final = d.apk_hash()
    s.record('apk_unchanged', '-', 'installed APK byte-identical to the baseline APK (patches never modify it)',
             'PASS' if final == want else 'FAIL', final[:16])
    s.finish()


if __name__ == '__main__':
    main()
