#!/usr/bin/env python3
"""Run the staged application's Chromium integration tests in a unique profile."""
import base64, hashlib, json, os, pathlib, platform, plistlib, signal, subprocess, sys, time, urllib.request, uuid
from test_processes import stop_app, window_failure
root = pathlib.Path(__file__).resolve().parents[1]
app = pathlib.Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else root/'dist/LiteTest.app'
def interrupted(signum, frame):
    raise KeyboardInterrupt
signal.signal(signal.SIGTERM, interrupted)
server = None
tls_server = None
profile_created = False
blocking_only = os.environ.get('LITE_BLOCKING_ONLY') == '1'
readiness_only = os.environ.get('LITE_READINESS_ONLY') == '1'
try:
    try:
        with urllib.request.urlopen('http://127.0.0.1:18743/echo', timeout=1) as response:
            if response.read() != b'lite-ok':
                raise RuntimeError('Port 18743 belongs to a different service')
    except OSError:
        server = subprocess.Popen([sys.executable, str(root/'script/test_server.py')])
        time.sleep(0.3)
    profile = pathlib.Path(os.environ.get('LITE_TEST_PROFILE', root/'.build'/('engine-test-'+uuid.uuid4().hex[:8]))).resolve()
    if profile.parent != (root/'.build').resolve() or not profile.name.startswith(('engine-test-', 'endurance-')):
        raise RuntimeError('The test profile must be a fresh engine-test- or endurance- directory inside .build')
    profile.mkdir(parents=True)
    profile_created = True
    # YouTube is HSTS-preloaded. Pin only this ephemeral fixture key in this
    # disposable process. No system trust or regular-profile settings are changed.
    cert, key = profile/'fixture.pem', profile/'fixture-key.pem'
    subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
                    '-subj', '/CN=www.youtube.com', '-keyout', str(key), '-out', str(cert)],
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    public = subprocess.check_output(['openssl', 'x509', '-in', str(cert), '-pubkey', '-noout'])
    der = subprocess.run(['openssl', 'pkey', '-pubin', '-outform', 'DER'], input=public,
                         capture_output=True, check=True).stdout
    spki = base64.b64encode(hashlib.sha256(der).digest()).decode()
    tls_server = subprocess.Popen([sys.executable, str(root/'script/test_server.py'),
                                  '--port', '18744', '--cert', str(cert), '--key', str(key)])
    time.sleep(0.3)
    if tls_server.poll() is not None:
        raise RuntimeError('The local HTTPS fixture could not start')
    output = profile/'smoke-results.json'
    started = time.monotonic()
    # Synthetic profiles only: do not access the user's real cookie-encryption key.
    launch = ['open', '-n', str(app), '--stdout', str(profile/'stdout.log'), '--stderr', str(profile/'stderr.log'), '--args', '--lite-test-profile='+str(profile), '--lite-smoke', '--use-mock-keychain', '--host-resolver-rules=MAP www.youtube.com 127.0.0.1', '--ignore-certificate-errors-spki-list='+spki]
    # Fake tracks still require Lite's actual permission prompt; never auto-grant.
    launch += ['--use-fake-device-for-media-stream']
    subprocess.run(launch + (['--lite-blocking-smoke'] if blocking_only else []) + (['--lite-readiness-smoke'] if readiness_only else []), check=True)
    # The app allows 140 s after its first page loads; leave room for a cold engine start.
    while not output.exists() and time.monotonic()-started < 240:
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
    if not blocking_only and result.get('siteStorageAbsentAfterReload'):
        for phase, flag in [('reopen', '--lite-storage-reopen'), ('reset', '--lite-storage-reset-check')]:
            output.rename(profile / ('smoke-before-' + phase + '.json'))
            if phase == 'reset':
                # The same checked marker consumed by production startup, only in
                # this runner's disposable profile after the engine exited.
                (profile / 'preserved-synthetic-data.txt').write_text('preserve-me')
                (profile / 'ClearWebsiteData.pending').write_text('Lite website data reset v1\n')
            subprocess.run(launch + [flag], check=True)
            deadline = time.monotonic() + 30
            while not output.exists() and time.monotonic() < deadline:
                time.sleep(.1)
            if not output.exists():
                raise RuntimeError('Restart verification timed out; inspect ' + str(profile))
            reopened = json.loads(output.read_text())
            deadline = time.monotonic() + 10
            while True:
                try:
                    os.kill(reopened['processID'], 0)
                except ProcessLookupError:
                    break
                if time.monotonic() > deadline:
                    raise RuntimeError('Restart test process did not close gracefully')
                time.sleep(.1)
            for key in ['siteStorageAbsentAfterRestart', 'permissionPersistedAfterRestart', 'allSiteStorageSeeded', 'allSiteStorageAbsentAfterRestart', 'allSitePermissionReset']:
                if key in reopened:
                    result[key] = reopened[key]
            result[phase + 'ProcessSeconds'] = reopened['elapsedSeconds']
        result['allSitePreservedOtherData'] = (profile / 'preserved-synthetic-data.txt').read_text() == 'preserve-me'
    if not blocking_only and result.get('downloadArtifact'):
        try:
            artifact = result['downloadArtifact']
            result['downloadQuarantined'] = bool(subprocess.check_output(['xattr', '-p', 'com.apple.quarantine', artifact]))
            origins = plistlib.loads(bytes.fromhex(subprocess.check_output(['xattr', '-px', 'com.apple.metadata:kMDItemWhereFroms', artifact], text=True)))
            result['downloadOriginMetadata'] = 'http://127.0.0.1:18743/download-fixture' in origins
        except (OSError, ValueError, plistlib.InvalidFileException, subprocess.CalledProcessError):
            result['downloadOriginMetadata'] = False
    required = ['backNavigation', 'forwardNavigation', 'privateIsolation', 'independentChromiumPages', 'formProtectionSignal', 'dirtyTabNotFrozen', 'backgroundFreeze', 'backgroundResume', 'discardReleasedBrowser', 'discardRestore', 'restoredCookies', 'webPlatformEvaluation']
    required += ['permissionExactOriginAndCapability', 'permissionDenied', 'permissionGranted', 'permissionRevoked', 'permissionNavigationCanceled', 'authenticationNavigationCanceled']
    required += ['repeatedBrowsingCycles']
    required += ['historyDiscardProtected', 'discardScrollRestored', 'httpBasicAuthentication', 'httpDigestAuthentication', 'proxyAuthentication', 'storageSeeded', 'siteStorageDeletionCompleted', 'siteStorageAbsentAfterReload', 'downloadCompleted', 'downloadQuarantined']
    required += ['taskManagerReportsTasks', 'taskManagerMeasurements', 'taskManagerProtectsBrowser', 'taskManagerEndProcess', 'taskManagerReloadAfterEnd']
    blocking_checks = ['blockingEnabled', 'blockingSitePause', 'blockingResumed', 'blockingGlobalPause', 'blockingCounter', 'blockingPrivateIsolation']
    blocking_checks += ['youtubeEnabled', 'youtubeSitePause', 'youtubeResumed', 'youtubeGlobalPause', 'youtubePrivateIsolation']
    blocking_checks += ['youtubeLivePause', 'youtubeLiveResume', 'devToolsOpenClose']
    required = blocking_checks if blocking_only else required + blocking_checks
    if readiness_only:
        required = ['httpBasicAuthentication', 'httpDigestAuthentication', 'proxyAuthentication', 'siteStorageDeletionCompleted', 'siteStorageAbsentAfterReload', 'downloadCompleted', 'downloadQuarantined', 'permissionExactOriginAndCapability', 'permissionDenied', 'permissionGranted', 'permissionRevoked', 'permissionNavigationCanceled', 'authenticationNavigationCanceled', 'repeatedBrowsingCycles']
    if not blocking_only:
        required += ['httpAuthenticationRetry', 'authenticationClosureCanceled']
        required += ['webAudioProtected', 'webAudioProtectionReleased']
        required += ['combinedMediaExactOriginAndCapabilities', 'combinedMediaDenied', 'combinedMediaGranted', 'combinedMediaProtected', 'combinedMediaStopped', 'combinedMediaNavigationCanceled', 'combinedMediaClosureCanceled']
        required += ['pointerInteractionProtected', 'keyboardInteractionProtected', 'inputInteractionProtected', 'changeInteractionProtected', 'interactionGuardResetOnNavigation']
        required += ['lifecycleBridgeHidden', 'lifecycleAttacksExecuted', 'lifecycleSelfProtectionRejected', 'lifecycleClosureUnreachable', 'lifecycleStrictCSP']
        required += ['lifecycleMediaElementPlaying', 'lifecycleMediaElementProtected', 'lifecycleMediaElementReleased', 'lifecyclePictureInPictureProtected', 'lifecyclePictureInPictureReleased']
        required += ['downloadOriginMetadata']
        required += ['downloadDuplicateFilename', 'downloadProtectsDiscard', 'downloadPaused', 'downloadResumed', 'downloadCanceled', 'downloadNetworkInterrupted', 'downloadClosureStopsMetadata']
        required += ['permissionRestartSeeded', 'siteStorageAbsentAfterRestart', 'permissionPersistedAfterRestart', 'allSiteStorageSeeded', 'allSiteStorageAbsentAfterRestart', 'allSitePermissionReset', 'allSitePreservedOtherData']
    system_media = result.get('systemMediaAuthorization', {})
    media_consent = system_media and all(value == 'authorized' for value in system_media.values())
    skipped = []
    if os.environ.get('CI') == 'true' and system_media and not media_consent:
        # Hosted runners cannot answer macOS camera/microphone consent for a fresh
        # ad hoc signature. Local release runs still require these checks.
        skipped = [key for key in ['combinedMediaGranted', 'combinedMediaProtected', 'combinedMediaStopped'] if key in required]
        required = [key for key in required if key not in skipped]
    failures = [key for key in required if result.get(key) is not True]
    if system_media and not media_consent and not skipped and 'combinedMediaGranted' in required:
        print('NOTE: this test bundle lacks macOS camera and microphone consent (systemMediaAuthorization: ' + json.dumps(system_media) + '). See "Camera and microphone consent" in docs/build-macos.md.')
    login_checks = ['loginFill', 'loginNoSubmit', 'loginCrossSiteRejected', 'loginNewPasswordRejected', 'loginHiddenRejected', 'loginWrongOriginRejected']
    login_checks += ['loginBridgeHidden', 'loginSubmissionUnsafeRejected', 'loginSubmissionCaptured', 'loginSubmissionPrivateRejected']
    if not blocking_only and not readiness_only:
        failures += [key for key in login_checks if result.get(key) is not True]
        platform_checks = ['chromium','dom','indexedDB','wasm','webgl','fetch','cookie']
        if os.environ.get('CI') == 'true' and platform.machine() == 'x86_64' and result.get('webPlatform',{}).get('webgl') is not True:
            # Hosted Intel macOS runners are GPU-less VMs, so Chromium offers no WebGL2.
            platform_checks.remove('webgl')
            skipped.append('webPlatform.webgl (no GPU on hosted Intel runner)')
        failures += ['webPlatform.'+key for key in platform_checks if result.get('webPlatform',{}).get(key) is not True]
    if result.get('timeout'):
        failures.append('timeout')
    if not blocking_only and not readiness_only and result.get('memory1',{}).get('processes',0) < 3:
        failures.append('incomplete Chromium process-family sample')
    if failures and window_failure(result):
        failures.insert(0, window_failure(result))
        print('NOTE: another app affected the test window. Run again with Lite left in front before treating this as a regression; see docs/build-macos.md.')
    result['totalVerificationSeconds'] = time.monotonic() - started
    result['profile'] = str(profile)
    target = root/'test-results'
    target.mkdir(exist_ok=True)
    (target/('blocking.json' if blocking_only else 'engine.json')).write_text(json.dumps(result, indent=2)+'\n')
    print(json.dumps(result, indent=2))
    if skipped:
        print('SKIPPED on hosted runner (camera/microphone consent: ' + json.dumps(system_media) + '): ' + ', '.join(skipped))
    print('FAIL: '+', '.join(failures) if failures else f'PASS: {len(required) + (0 if blocking_only or readiness_only else len(login_checks) + len(platform_checks))} bundled Chromium checks')
    raise SystemExit(bool(failures))
finally:
    if profile_created:
        stop_app(app, profile)
    if tls_server:
        tls_server.terminate()
        tls_server.wait(timeout=5)
    if server:
        server.terminate()
        server.wait(timeout=5)
