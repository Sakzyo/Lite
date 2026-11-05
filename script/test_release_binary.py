#!/usr/bin/env python3
"""Launch the release bundle with test flags in a disposable profile and confirm they do nothing."""
import os
import pathlib
import shutil
import subprocess
import sys
import time
import uuid
from test_processes import stop_app

ROOT = pathlib.Path(__file__).resolve().parents[1]


def main():
    app = pathlib.Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else ROOT / 'dist/Lite.app'
    root = ROOT / '.build' / ('release-binary-' + uuid.uuid4().hex[:8])
    profile, ignored = root / 'profile', root / 'ignored'
    root.mkdir(parents=True)
    failures = []
    try:
        environment = {**os.environ, 'LITE_PROFILE_DIR': str(profile)}
        process = subprocess.Popen([str(app / 'Contents/MacOS/Lite'), '--lite-test-profile=' + str(ignored),
                                    '--lite-smoke', '--lite-native-smoke', '--use-mock-keychain'],
                                   env=environment, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        deadline = time.monotonic() + 30
        while not (profile / 'Lite.sqlite').exists() and process.poll() is None and time.monotonic() < deadline:
            time.sleep(.2)
        if not (profile / 'Lite.sqlite').exists():
            failures.append('the application did not open its normal profile')
        # The test paths would have written their results within this window.
        time.sleep(5)
        if process.poll() is not None:
            failures.append('the application exited instead of running normally')
        if ignored.exists():
            failures.append('--lite-test-profile selected a profile')
        if (profile / 'smoke-results.json').exists() or (profile / 'native-results.json').exists():
            failures.append('a test suite ran')
    finally:
        stop_app(app, ignored)
        shutil.rmtree(root, ignore_errors=True)
    print('FAIL: ' + ', '.join(failures) if failures else 'PASS: the release bundle ignores test flags')
    return bool(failures)


if __name__ == '__main__':
    raise SystemExit(main())
