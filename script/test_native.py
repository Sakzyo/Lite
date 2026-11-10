#!/usr/bin/env python3
"""Exercise real Lite windows and controls using a disposable browser profile."""
import base64
import hashlib
import json
import os
import pathlib
import shutil
import signal
import sqlite3
import subprocess
import sys
import time
import urllib.request
import uuid

from test_processes import stop_app, window_failure

ROOT = pathlib.Path(__file__).resolve().parents[1]
REQUIRED = ['nativeMainWindow', 'nativeAccessibleNavigation', 'nativeFixtureSeeded',
            'nativeExtensionsPanel', 'nativeExtensionPopup', 'nativeExtensionPopupClosed', 'nativeExtensionsHiddenInPrivate',
            'nativeSplitPrimaryFocused', 'nativeSplitFocusForward', 'nativeSplitFocusBackward',
            'nativeSidebarCollapsed', 'nativeFullScreenChrome', 'nativeFullScreenRestored',
            'nativeSidebarRevealed', 'nativeSidebarFollowsSaves', 'nativeCommandShortcutAndNames',
            'nativeCommandArrowNavigation', 'nativeCommandHistoryPrefix', 'nativeCommandSearchSuggestions', 'nativeCommandEscape',
            'nativeSettingsAccessibleControls', 'nativeSettingsSearchEngines', 'nativeSettingsExportControls', 'nativeExportSavePanel', 'nativePrivateSearchEngine', 'nativePrivateCommandWithoutSuggestions',
            'nativeDownloadsAccessibleControls', 'nativeWindowCloseDialog',
            'nativeWindowCancelPreservesEveryPage', 'nativeBeforeUnloadDialog',
            'nativeBeforeUnloadCancelPreservesTab', 'nativeCanceledPageStateIntact',
            'nativeMultipleRegularWindows', 'nativePrivateWindow', 'nativePrivateStorageIsolated',
            'nativeRegularStorageSharedWithoutPrivateLeak', 'nativeQuitCancelDialog',
            'nativeQuitCancelPreservesAllWindows', 'nativePrivateWindowClosure',
            'nativePrivateClearConfirmation', 'nativePrivateClearCancelPreservesSession',
            'nativePrivateClearClosesOldContext', 'nativePrivateClearFreshWindow',
            'nativePrivateClearStorageEmpty', 'nativePrivateClearPreservesRegularData',
            'nativeRegularWindowClosure', 'nativeTabClosure', 'nativeClosedTabRecorded',
            'nativeClosedWindowRecorded', 'nativeReopenClosedTab', 'nativeReopenClosedWindow', 'nativeAuthenticationDialog',
            'nativeAuthenticationSucceeded', 'nativeCrashPromptDisclosure', 'nativeCrashPromptDefaultsToDecline',
            'nativeFilterUpdateControls', 'nativeFilterUpdateInstalled',
            'nativeCustomFilterEditor', 'nativeCustomFilterApply', 'nativeCustomFilterCancel',
            'nativeCustomFilterRejectsWholeDraft', 'nativePrivateCustomFiltersCopied',
            'nativePrivateCustomFilterEditsIsolated']


def publish_test_filters(profile):
    """Sign a filter set with one extra rule, blocking filter-update.test, with a key made for this run.
    The fixture server serves it at /filters/. Returns the public key."""
    feed = ROOT / '.build/native-filter-feed'
    shutil.rmtree(feed, ignore_errors=True)
    source = profile / 'filter-source'
    shutil.copytree(ROOT / 'resources/ContentBlocking', source)
    rules = json.loads((source / 'network.json').read_text())
    rules.append({'action': {'type': 'block'}, 'condition': {'urlFilter': '||filter-update.test^'}, 'priority': 1})
    (source / 'network.json').write_text(json.dumps(rules, separators=(',', ':')))
    provenance = json.loads((source / 'provenance.json').read_text())
    provenance['sha256']['network.json'] = hashlib.sha256((source / 'network.json').read_bytes()).hexdigest()
    provenance['networkRules'] = len(rules)
    (source / 'provenance.json').write_text(json.dumps(provenance))
    script = [sys.executable, str(ROOT / 'script/sign_filters.py')]
    created = subprocess.run(script + ['key', str(profile / 'filter-key.pem')], check=True, capture_output=True, text=True).stdout
    subprocess.run(script + ['serial', '--source', str(source)], check=True, capture_output=True)
    subprocess.run(script + ['publish', str(feed), '--key', str(profile / 'filter-key.pem'), '--source', str(source)], check=True, capture_output=True)
    return next(line.split('=', 1)[1] for line in created.splitlines() if line.startswith('LITE_FILTER_PUBLIC_KEY='))


def main():
    def interrupted(signum, frame):
        raise KeyboardInterrupt
    signal.signal(signal.SIGTERM, interrupted)
    app = pathlib.Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else ROOT / 'dist/LiteTest.app'
    profile = pathlib.Path(os.environ['LITE_TEST_PROFILE']).resolve() if os.environ.get('LITE_TEST_PROFILE') else ROOT / '.build' / ('native-test-' + uuid.uuid4().hex[:8])
    if profile.parent != ROOT / '.build' or not profile.name.startswith(('native-test-', 'endurance-')):
        raise ValueError('Native verification requires a fresh synthetic profile under .build')
    profile.mkdir(parents=True)
    data = dict(version=1, spaces=[dict(id='native-space', name='Personal', selected='')], nodes=[],
                activeSpace='native-space', settings=dict(performance='Efficient', search='Fixture Search',
                # Searches and suggestions go to the loopback fixture, never to a real search engine.
                searchEngines=[dict(name='Fixture Search', url='http://127.0.0.1:18743/search?q=%s',
                                    suggest='http://127.0.0.1:18743/suggest?q=%s')], searchSuggestions=True,
                externalMini=True, onboarded=True), windows=[])
    with sqlite3.connect(profile / 'Lite.sqlite') as db:
        db.execute('CREATE TABLE profile (id INTEGER PRIMARY KEY CHECK(id=1),json BLOB NOT NULL)')
        db.execute('INSERT INTO profile VALUES (1,?)', (json.dumps(data).encode(),))
        db.execute('PRAGMA user_version=1')
    # Register the fixture extension the way the Extensions panel's Add Folder does.
    fixture = (ROOT / 'lite/tests/fixtures/extension').resolve()
    key = base64.b64decode(json.loads((fixture / 'manifest.json').read_text())['key'])
    extension_id = ''.join(chr(97 + int(c, 16)) for c in hashlib.sha256(key).hexdigest()[:32])
    (profile / 'Extensions').mkdir()
    (profile / 'Extensions/Extensions.json').write_text(json.dumps({'version': 1, 'extensions': [
        dict(id=extension_id, path=str(fixture), source='unpacked', enabled=True)]}))
    # Synthetic reports: one to offer, one from a private run, one past retention.
    now = time.time()
    for folder, name, age in [('pending', 'offered', 3600), ('completed', 'private-run', 0), ('pending', 'expired', 8 * 86400)]:
        (profile / 'Chromium' / folder).mkdir(parents=True, exist_ok=True)
        dump = profile / 'Chromium' / folder / (name + '.dmp')
        dump.write_text('synthetic-' + name)
        os.utime(dump, (now - age, now - age))
    (profile / 'PrivateSession.marker').touch()
    os.utime(profile / 'PrivateSession.marker', (now - 60, now - 60))
    filter_key = publish_test_filters(profile)
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
                        '--lite-native-smoke', '--use-mock-keychain',
                        '--lite-crash-upload=http://127.0.0.1:18743/crash-upload',
                        '--lite-filter-feed=http://127.0.0.1:18743/filters/', '--lite-filter-key=' + filter_key], check=True)
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
        with urllib.request.urlopen('http://127.0.0.1:18743/crash-uploads', timeout=5) as response:
            uploads = json.load(response)
        with urllib.request.urlopen('http://127.0.0.1:18743/suggest-log', timeout=5) as response:
            suggested = json.load(response)
        with urllib.request.urlopen('http://127.0.0.1:18743/filter-log', timeout=5) as response:
            filter_requests = json.load(response)
        checks = {'nativeCrashUploadOnlyApprovedReport': len(uploads) == 1 and 'synthetic-offered' in uploads[0]['body'] and uploads[0]['contentType'].startswith('multipart/form-data'),
                  'nativeCrashUploadNoCookies': bool(uploads) and not uploads[0]['cookie'],
                  'nativeCrashReportsRemovedAfterHandling': not list(profile.glob('Chromium/*/*.dmp')),
                  'nativePrivateSessionRecorded': (profile / 'PrivateSession.marker').exists(),
                  # Not the page address the Command Bar opened with, not text replaced before
                  # typing paused, and nothing typed in the private window.
                  'nativeSuggestionsOnlyTypedSearch': [entry['query'] for entry in suggested] == ['lite fixt'],
                  'nativeSuggestionsNoCookies': bool(suggested) and not any(entry['cookie'] for entry in suggested),
                  # The manifest, its signature and the seven files, without cookies. A failed check is
                  # retried, so a path may be asked for more than once.
                  'nativeFilterUpdateRequests': len({e['path'] for e in filter_requests}) == 9 and
                      not any(e['cookie'] for e in filter_requests) and all(e['agent'] == 'Lite-Browser' for e in filter_requests)}
        result.update(checks)
        result['filterRequests'] = filter_requests
        failures += [key for key, passed in checks.items() if not passed]
        if failures and window_failure(result):
            failures.insert(0, window_failure(result))
            print('NOTE: another app affected the test window. Run again with Lite left in front before treating this as a regression; see docs/build-macos.md.')
        result['failures'] = failures
        (ROOT / 'test-results').mkdir(exist_ok=True)
        (ROOT / 'test-results/native.json').write_text(json.dumps(result, indent=2) + '\n')
        print(json.dumps(result, indent=2))
        print('FAIL: ' + ', '.join(failures) if failures else f'PASS: {len(REQUIRED) + len(checks)} actual native-window checks')
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
