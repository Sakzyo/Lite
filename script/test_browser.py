#!/usr/bin/env python3
"""Run the staged application's Chromium integration tests in a unique profile."""
import json, os, pathlib, subprocess, sys, time, urllib.request, uuid
root = pathlib.Path(__file__).resolve().parents[1]
app = pathlib.Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else root/'dist/Lite.app'
server = None
blocking_only = os.environ.get('LITE_BLOCKING_ONLY') == '1'
try:
    try:
        with urllib.request.urlopen('http://127.0.0.1:18743/echo', timeout=1) as response:
            if response.read() != b'lite-ok':
                raise RuntimeError('Port 18743 belongs to a different service')
    except OSError:
        server = subprocess.Popen([sys.executable, str(root/'script/test_server.py')])
        time.sleep(0.3)
    profile = root/'.build'/('engine-test-'+uuid.uuid4().hex[:8])
    profile.mkdir(parents=True)
    output = profile/'smoke-results.json'
    started = time.monotonic()
    # Synthetic profiles only: do not access the user's real cookie-encryption key.
    subprocess.run(['open', '-n', str(app), '--stdout', str(profile/'stdout.log'), '--stderr', str(profile/'stderr.log'), '--args', '--lite-test-profile='+str(profile), '--lite-smoke', '--use-mock-keychain'] + (['--lite-blocking-smoke'] if blocking_only else []), check=True)
    while not output.exists() and time.monotonic()-started < 110:
        time.sleep(0.2)
    if not output.exists():
        raise RuntimeError('Browser test timed out; inspect '+str(profile))
    result = json.loads(output.read_text())
    if result.get('processID'):
        deadline = time.monotonic() + 10
        while True:
            try:
                os.kill(result['processID'], 0)
            except ProcessLookupError:
                break
            if time.monotonic() >= deadline:
                raise RuntimeError('The test browser did not close gracefully')
            time.sleep(0.1)
    required = ['backNavigation', 'forwardNavigation', 'privateIsolation', 'independentChromiumPages', 'formProtectionSignal', 'dirtyTabNotFrozen', 'backgroundFreeze', 'backgroundResume', 'discardReleasedBrowser', 'discardRestore', 'restoredCookies', 'webPlatformEvaluation']
    required += ['taskManagerReportsTasks', 'taskManagerMeasurements', 'taskManagerProtectsBrowser', 'taskManagerEndProcess', 'taskManagerReloadAfterEnd']
    blocking_checks = ['blockingEnabled', 'blockingSitePause', 'blockingResumed', 'blockingGlobalPause', 'blockingCounter', 'blockingPrivateIsolation']
    required = blocking_checks if blocking_only else required + blocking_checks
    failures = [key for key in required if result.get(key) is not True]
    login_checks = ['loginFill', 'loginNoSubmit', 'loginCrossSiteRejected', 'loginNewPasswordRejected', 'loginHiddenRejected', 'loginWrongOriginRejected']
    if not blocking_only:
        failures += [key for key in login_checks if result.get(key) is not True]
        failures += ['webPlatform.'+key for key in ['chromium','dom','indexedDB','wasm','webgl','fetch','cookie'] if result.get('webPlatform',{}).get(key) is not True]
    if result.get('timeout'):
        failures.append('timeout')
    if not blocking_only and result.get('memory1',{}).get('processes',0) < 3:
        failures.append('incomplete Chromium process-family sample')
    target = root/'test-results'
    target.mkdir(exist_ok=True)
    (target/('blocking.json' if blocking_only else 'engine.json')).write_text(json.dumps(result, indent=2)+'\n')
    print(json.dumps(result, indent=2))
    print('FAIL: '+', '.join(failures) if failures else f'PASS: {6 if blocking_only else 36} bundled Chromium checks')
    raise SystemExit(bool(failures))
finally:
    if server:
        server.terminate()
        server.wait(timeout=5)
