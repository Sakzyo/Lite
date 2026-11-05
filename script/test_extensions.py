#!/usr/bin/env python3
"""Load the fixture extension through a disposable profile's extension list and verify it in Chromium."""
import base64, hashlib, json, os, pathlib, signal, subprocess, sys, time, urllib.request, uuid
from test_processes import stop_app
root = pathlib.Path(__file__).resolve().parents[1]
app = pathlib.Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else root/'dist/LiteTest.app'
fixture = (root/'lite/tests/fixtures/extension').resolve()
def interrupted(signum, frame):
    raise KeyboardInterrupt
signal.signal(signal.SIGTERM, interrupted)
server = None
profile = (root/'.build'/('engine-test-extensions-'+uuid.uuid4().hex[:8])).resolve()
profile_created = False
try:
    try:
        with urllib.request.urlopen('http://127.0.0.1:18743/echo', timeout=1) as response:
            if response.read() != b'lite-ok':
                raise RuntimeError('Port 18743 belongs to a different service')
    except OSError:
        server = subprocess.Popen([sys.executable, str(root/'script/test_server.py')])
        time.sleep(0.3)
    key = base64.b64decode(json.loads((fixture/'manifest.json').read_text())['key'])
    extension_id = ''.join(chr(97 + int(c, 16)) for c in hashlib.sha256(key).hexdigest()[:32])
    (profile/'Extensions').mkdir(parents=True)
    profile_created = True
    # The same registry format the Extensions panel writes when a folder is added.
    (profile/'Extensions/Extensions.json').write_text(json.dumps({'version': 1, 'extensions': [
        {'id': extension_id, 'path': str(fixture), 'source': 'unpacked', 'enabled': True}]}))
    output = profile/'smoke-results.json'
    started = time.monotonic()
    subprocess.run(['open', '-n', str(app), '--stdout', str(profile/'stdout.log'), '--stderr', str(profile/'stderr.log'),
                    '--args', '--lite-test-profile='+str(profile), '--lite-smoke', '--use-mock-keychain',
                    '--lite-extension-smoke='+extension_id], check=True)
    while not output.exists() and time.monotonic()-started < 90:
        time.sleep(0.2)
    if not output.exists():
        raise RuntimeError('Extension test timed out; inspect '+str(profile))
    result = json.loads(output.read_text())
    required = ['extensionContentScript', 'extensionWorkerMessaging', 'extensionPageAPIs', 'extensionPopupAutoResize', 'extensionNotInPrivate']
    failures = [key for key in required if result.get(key) is not True]
    if result.get('timeout'):
        failures.append('timeout')
    result['profile'] = str(profile)
    target = root/'test-results'
    target.mkdir(exist_ok=True)
    (target/'extensions.json').write_text(json.dumps(result, indent=2)+'\n')
    print(json.dumps({key: result.get(key) for key in required + ['extensionContentScriptState', 'extensionPopupSize', 'extensionTimeoutStage', 'extensionPageTitle', 'extensionPageError']}, indent=2))
    print('FAIL: '+', '.join(failures) if failures else f'PASS: {len(required)} extension checks')
    raise SystemExit(bool(failures))
finally:
    if profile_created:
        stop_app(app, profile)
    if server:
        server.terminate()
        server.wait(timeout=5)
