#!/usr/bin/env python3
"""Crash a sandboxed helper in a disposable profile and confirm Crashpad stores a report."""
import os
import pathlib
import shutil
import signal
import subprocess
import sys
import time
import uuid
from test_processes import stop_app

ROOT = pathlib.Path(__file__).resolve().parents[1]


def child_process(app, kind):
    rows = subprocess.check_output(['ps', '-ww', '-axo', 'pid=,command='], text=True).splitlines()
    for row in rows:
        pid, command = row.strip().split(None, 1)
        if str(app / 'Contents/Frameworks') in command and '--type=' + kind in command:
            return int(pid)
    return None


def main():
    app = pathlib.Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else ROOT / 'dist/LiteTest.app'
    profile = ROOT / '.build' / ('crash-capture-' + uuid.uuid4().hex[:8])
    profile.mkdir()
    failures = []
    try:
        subprocess.run(['open', '-n', str(app), '--args', '--lite-test-profile=' + str(profile), '--use-mock-keychain'], check=True)
        deadline = time.monotonic() + 30
        pid = None
        while not pid and time.monotonic() < deadline:
            time.sleep(.2)
            pid = child_process(app, 'gpu-process')
        if not pid:
            failures.append('no helper process started')
        else:
            os.kill(pid, signal.SIGSEGV)
        deadline = time.monotonic() + 15
        reports = []
        while pid and not reports and time.monotonic() < deadline:
            time.sleep(.2)
            reports = list(profile.glob('Chromium/pending/*.dmp')) + list(profile.glob('Chromium/completed/*.dmp'))
        if pid and not reports:
            failures.append('Crashpad stored no report')
    finally:
        stop_app(app, profile)
        shutil.rmtree(profile, ignore_errors=True)
    print('FAIL: ' + ', '.join(failures) if failures else 'PASS: a helper crash produced a stored report')
    return bool(failures)


if __name__ == '__main__':
    raise SystemExit(main())
