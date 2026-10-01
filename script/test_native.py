#!/usr/bin/env python3
"""Exercise real Lite windows and controls using a disposable browser profile."""
import json
import os
import pathlib
import signal
import sqlite3
import subprocess
import sys
import time
import urllib.request
import uuid

from test_processes import stop_app

ROOT = pathlib.Path(__file__).resolve().parents[1]
REQUIRED = ['nativeMainWindow', 'nativeAccessibleNavigation', 'nativeFixtureSeeded',
            'nativeSplitPrimaryFocused', 'nativeSplitFocusForward', 'nativeSplitFocusBackward',
            'nativeSidebarCollapsed', 'nativeSidebarRevealed', 'nativeCommandShortcutAndNames',
            'nativeCommandArrowNavigation', 'nativeCommandEscape', 'nativeSettingsAccessibleControls',
            'nativeDownloadsAccessibleControls', 'nativeWindowCloseDialog',
            'nativeWindowCancelPreservesEveryPage', 'nativeBeforeUnloadDialog',
            'nativeBeforeUnloadCancelPreservesTab', 'nativeCanceledPageStateIntact',
            'nativeMultipleRegularWindows', 'nativePrivateWindow', 'nativePrivateStorageIsolated',
            'nativeRegularStorageSharedWithoutPrivateLeak', 'nativeQuitCancelDialog',
            'nativeQuitCancelPreservesAllWindows', 'nativePrivateWindowClosure',
            'nativePrivateClearConfirmation', 'nativePrivateClearCancelPreservesSession',
            'nativePrivateClearClosesOldContext', 'nativePrivateClearFreshWindow',
            'nativePrivateClearStorageEmpty', 'nativePrivateClearPreservesRegularData',
            'nativeRegularWindowClosure', 'nativeTabClosure', 'nativeAuthenticationDialog',
            'nativeAuthenticationSucceeded']


def main():
    def interrupted(signum, frame):
        raise KeyboardInterrupt
    signal.signal(signal.SIGTERM, interrupted)
    app = pathlib.Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else ROOT / 'dist/Lite.app'
    profile = pathlib.Path(os.environ['LITE_TEST_PROFILE']).resolve() if os.environ.get('LITE_TEST_PROFILE') else ROOT / '.build' / ('native-test-' + uuid.uuid4().hex[:8])
    if profile.parent != ROOT / '.build' or not profile.name.startswith(('native-test-', 'endurance-')):
        raise ValueError('Native verification requires a fresh synthetic profile under .build')
    profile.mkdir(parents=True)
    data = dict(version=1, spaces=[dict(id='native-space', name='Personal', selected='')], nodes=[],
                activeSpace='native-space', settings=dict(performance='Efficient', search='DuckDuckGo',
                externalMini=True, onboarded=True), windows=[])
    with sqlite3.connect(profile / 'Lite.sqlite') as db:
        db.execute('CREATE TABLE profile (id INTEGER PRIMARY KEY CHECK(id=1),json BLOB NOT NULL)')
        db.execute('INSERT INTO profile VALUES (1,?)', (json.dumps(data).encode(),))
        db.execute('PRAGMA user_version=1')
    server = None
    output = profile / 'native-results.json'
    try:
        try:
            with urllib.request.urlopen('http://127.0.0.1:18743/echo', timeout=1) as response:
                if response.read() != b'lite-ok':
                    raise RuntimeError('Port 18743 belongs to a different service')
        except OSError:
            server = subprocess.Popen([sys.executable, str(ROOT / 'script/test_server.py')])
            time.sleep(.3)
            if server.poll() is not None:
                raise RuntimeError('Native loopback fixture failed to start')
        subprocess.run(['open', '-n', str(app), '--stdout', str(profile / 'stdout.log'), '--stderr',
                        str(profile / 'stderr.log'), '--args', '--lite-test-profile=' + str(profile),
                        '--lite-native-smoke', '--use-mock-keychain'], check=True)
        deadline = time.monotonic() + 115
        while not output.exists() and time.monotonic() < deadline:
            time.sleep(.2)
        if not output.exists():
            raise RuntimeError('Native UI test timed out; inspect ' + str(profile))
        result = json.loads(output.read_text())
        result['profile'] = str(profile)
        failures = [key for key in REQUIRED if result.get(key) is not True]
        if 'timeoutStage' in result:
            failures.append('timeoutStage=' + str(result['timeoutStage']))
        pid = result['processID']
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                result['gracefulExit'] = True
                break
            time.sleep(.1)
        if not result.get('gracefulExit'):
            failures.append('native test app did not exit gracefully')
        result['failures'] = failures
        (ROOT / 'test-results').mkdir(exist_ok=True)
        (ROOT / 'test-results/native.json').write_text(json.dumps(result, indent=2) + '\n')
        print(json.dumps(result, indent=2))
        print('FAIL: ' + ', '.join(failures) if failures else f'PASS: {len(REQUIRED)} actual native-window checks')
        return bool(failures)
    finally:
        # A failed native regression must not leave synthetic renderers running.
        # Scope cleanup to this exact app/profile pair; normal user instances and
        # other test processes never match. Any forced stop remains a test failure.
        stop_app(app, profile)
        if server:
            server.terminate()
            server.wait(timeout=5)


if __name__ == '__main__':
    raise SystemExit(main())
