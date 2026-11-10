#!/usr/bin/env python3
"""Stage, sign and verify a complete Lite bundle; production additionally notarizes.

--test stages dist/LiteTest.app from the LiteTestApp target for the Chromium and
native-window suites. It is never a distribution build. LITE_TEST_SIGNING_IDENTITY
optionally signs that bundle with a local identity, so macOS camera and microphone
consent survives rebuilds; see docs/build-macos.md.
"""
import argparse
import base64
import json
import os
import pathlib
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.parse
from sdk_support import digest, installation_lock, recover, replace_directory

ROOT = pathlib.Path(__file__).resolve().parents[1]


def run(*args, **kwargs):
    return subprocess.run([str(arg) for arg in args], check=True, **kwargs)


def signing_identity(requested):
    text = subprocess.check_output(['security', 'find-identity', '-v', '-p', 'codesigning'], text=True)
    identities = re.findall(r'\b([A-F0-9]{40}) "(Developer ID Application:[^"]+)"', text)
    choices = [digest for digest, name in identities if not requested or requested in (digest, name)]
    if len(choices) != 1:
        raise ValueError('Production requires one selected valid Developer ID Application identity; set LITE_SIGNING_IDENTITY when more than one is configured')
    return choices[0]


def test_signing_identity(requested):
    """Resolve the opt-in local identity for dist/LiteTest.app; ad hoc without one."""
    if not requested:
        return '-'
    text = subprocess.check_output(['security', 'find-identity', '-p', 'codesigning'], text=True)
    # Without -v the listing includes a self-signed identity, which is usable for
    # signing but never trusted. Trust is not needed: macOS binds consent to the
    # certificate hash, and an expired or revoked identity must not be used.
    identities = re.findall(r'^\s*\d+\) ([A-F0-9]{40}) "([^"]+)"(?: \(CSSMERR_TP_NOT_TRUSTED\))?$', text, re.M)
    choices = {digest for digest, name in identities if requested in (digest, name)}
    if len(choices) != 1:
        raise ValueError('LITE_TEST_SIGNING_IDENTITY must name exactly one usable code-signing identity; found ' + str(len(choices)) + '. If two share a name, use the SHA-1 hash from: security find-identity -p codesigning')
    return choices.pop()


def bundle_identity(production, test):
    if production:
        return signing_identity(os.environ.get('LITE_SIGNING_IDENTITY'))
    return test_signing_identity(os.environ.get('LITE_TEST_SIGNING_IDENTITY')) if test else '-'


def stable_requirement(app):
    """An ad hoc designated requirement is a cdhash, which every rebuild changes."""
    signature = subprocess.run(['codesign', '-d', '-r-', str(app)], capture_output=True, text=True, check=True)
    return 'cdhash' not in signature.stdout + signature.stderr


def release_configuration(info, feed, key, build):
    url = urllib.parse.urlsplit(feed or '')
    try:
        decoded = base64.b64decode(key or '', validate=True)
    except ValueError:
        decoded = b''
    if url.scheme != 'https' or not url.hostname or url.username or url.password or len(decoded) != 32:
        raise ValueError('Production requires LITE_UPDATE_FEED_URL (HTTPS) and LITE_UPDATE_PUBLIC_KEY (32-byte base64 Ed25519 key)')
    if not build or not re.fullmatch(r'[1-9][0-9]{0,14}', build):
        raise ValueError('Production requires a monotonically increasing integer LITE_BUILD_NUMBER')
    info.update(SUFeedURL=feed, SUPublicEDKey=key, LTUpdatesEnabled=True, CFBundleVersion=build)


P256_SPKI_HEADER = bytes.fromhex('3059301306072a8648ce3d020106082a8648ce3d030107034200')


def filter_configuration(info, feed, key, production=False):
    """Filter updates are optional: a build without both settings never checks for them."""
    if not feed and not key:
        return
    url = urllib.parse.urlsplit(feed or '')
    local = url.hostname in ('127.0.0.1', 'localhost', '::1')
    try:
        decoded = base64.b64decode(key or '', validate=True)
    except ValueError:
        decoded = b''
    point = decoded[len(P256_SPKI_HEADER):] if decoded.startswith(P256_SPKI_HEADER) else decoded
    if (not url.hostname or url.username or url.password or url.query or url.fragment or
            not (url.scheme == 'https' or (url.scheme == 'http' and local and not production)) or
            len(point) != 65 or point[0] != 4):
        raise ValueError('Filter updates need both LITE_FILTER_FEED_URL (HTTPS) and LITE_FILTER_PUBLIC_KEY '
                         '(the P-256 key printed by script/sign_filters.py key)')
    info.update(LTFilterFeedURL=feed, LTFilterPublicKey=key)


def crash_configuration(info, value):
    """The consent dialog names Sentry, so a release must not send reports anywhere else."""
    if not value:
        return
    url = urllib.parse.urlsplit(value)
    host = url.hostname or ''
    if url.scheme != 'https' or url.username or url.password or not (host == 'sentry.io' or host.endswith('.sentry.io')):
        raise ValueError('LITE_CRASH_UPLOAD_URL must be an HTTPS sentry.io minidump endpoint')
    info['LTCrashUploadURL'] = value


def sign(path, identity, entitlements=None, production=False):
    args = ['codesign', '--force', '--sign', identity]
    if production:
        args += ['--options', 'runtime', '--timestamp']
    if entitlements and production:
        args += ['--entitlements', str(entitlements)]
    run(*args, path, capture_output=True)


def is_macho(path):
    if not path.is_file() or path.is_symlink():
        return False
    with path.open('rb') as source:
        return source.read(4) in (b'\xcf\xfa\xed\xfe', b'\xce\xfa\xed\xfe', b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca')


def sign_sparkle(framework, identity, production):
    # Embedded upstream XPC services have their own sandbox entitlements. Preserve
    # those entitlements while changing the team identity.
    for path in sorted(framework.rglob('*'), key=lambda p: len(p.parts), reverse=True):
        if path.is_symlink():
            continue
        if path.suffix in ('.xpc', '.app') or is_macho(path):
            args = ['codesign', '--force', '--sign', identity, '--preserve-metadata=entitlements']
            if production:
                args += ['--options', 'runtime', '--timestamp']
            run(*args, path, capture_output=True)
    sign(framework, identity, production=production)


def verify(app, production=False):
    run('codesign', '--verify', '--deep', '--strict', app)
    run(sys.executable, ROOT / 'script/test_package.py', env={**os.environ, 'LITE_PACKAGE_APP': str(app)})
    if production:
        details = subprocess.check_output(['codesign', '-dv', '--verbose=4', str(app)], stderr=subprocess.STDOUT, text=True)
        if 'Authority=Developer ID Application:' not in details or 'runtime' not in details:
            raise ValueError('Production signing or hardened runtime is missing')


def package(production=False, output=None, test=False):
    destination = (output or ROOT / ('dist/LiteTest.app' if test else 'dist/Lite.app')).resolve()
    executable = ROOT / ('.build/LiteTestApp' if test else '.build/Lite')
    identity = bundle_identity(production, test)
    info = plistlib.loads((ROOT / 'resources/Info.plist').read_bytes())
    info['LiteDistribution'] = 'Test' if test else 'DeveloperID' if production else 'Local'
    if test:
        # Keeps test runs out of the regular app's defaults domain.
        info['CFBundleIdentifier'] += '.test'
    info['LTArchitecture'] = subprocess.check_output(['lipo', '-archs', str(executable)], text=True).strip()
    if info['LTArchitecture'] not in ('arm64', 'x86_64'):
        raise ValueError('Each release must contain one matching CEF architecture')
    if production:
        release_configuration(info, os.environ.get('LITE_UPDATE_FEED_URL'), os.environ.get('LITE_UPDATE_PUBLIC_KEY'), os.environ.get('LITE_BUILD_NUMBER'))
        crash_configuration(info, os.environ.get('LITE_CRASH_UPLOAD_URL'))
        if not os.environ.get('LITE_NOTARY_PROFILE'):
            raise ValueError('Production requires LITE_NOTARY_PROFILE: an existing notarytool Keychain credential profile')
    filter_configuration(info, os.environ.get('LITE_FILTER_FEED_URL'), os.environ.get('LITE_FILTER_PUBLIC_KEY'), production)
    destination.parent.mkdir(parents=True, exist_ok=True)
    with installation_lock(destination.parent, 'package'), tempfile.TemporaryDirectory(prefix='.lite-package-', dir=destination.parent) as temporary:
        app = pathlib.Path(temporary) / 'Lite.app'
        contents = app / 'Contents'
        for part in ('MacOS', 'Frameworks', 'Resources'):
            (contents / part).mkdir(parents=True)
        shutil.copy2(executable, contents / 'MacOS/Lite')
        (contents / 'Info.plist').write_bytes(plistlib.dumps(info))
        framework = contents / 'Frameworks/Chromium Embedded Framework.framework'
        shutil.copytree(ROOT / 'vendor/cef/Release/Chromium Embedded Framework.framework', framework, symlinks=True)
        # CEF's current supported structure is versioned, matching Apple's bundle rules.
        if not (framework / 'Versions').exists():
            (framework / 'Versions/A').mkdir(parents=True)
            for path in list(framework.iterdir()):
                if path.name != 'Versions':
                    path.rename(framework / 'Versions/A' / path.name)
                    path.symlink_to('Versions/Current/' + path.name)
            (framework / 'Versions/Current').symlink_to('A')
        for path in sorted(framework.rglob('*'), key=lambda p: len(p.parts), reverse=True):
            if is_macho(path):
                sign(path, identity, production=production)
        sign(framework, identity, production=production)
        for suffix, bundle in [('', ''), (' (Alerts)', '.alerts'), (' (GPU)', '.gpu'), (' (Plugin)', '.plugin'), (' (Renderer)', '.renderer')]:
            name = 'Lite Helper' + suffix
            helper = contents / 'Frameworks' / (name + '.app') / 'Contents'
            (helper / 'MacOS').mkdir(parents=True)
            shutil.copy2(ROOT / '.build/LiteHelper', helper / 'MacOS' / name)
            helper_info = dict(CFBundleExecutable=name, CFBundleIdentifier='app.lite.browser.helper'+bundle, CFBundleName=name, CFBundlePackageType='APPL', CFBundleVersion=info['CFBundleVersion'], LSUIElement=True, LSMinimumSystemVersion='14.0')
            (helper / 'Info.plist').write_bytes(plistlib.dumps(helper_info))
            entitlement = 'renderer' if bundle in ('.renderer', '.gpu', '.plugin') else 'helper'
            sign(helper.parent, identity, ROOT / ('resources/entitlements/' + entitlement + '.plist'), production)
        sparkle = contents / 'Frameworks/Sparkle.framework'
        shutil.copytree((ROOT / 'vendor/sparkle/Sparkle.framework').resolve(), sparkle, symlinks=True)
        sign_sparkle(sparkle, identity, production)
        for source in ('LICENSE.txt', 'CREDITS.html'):
            shutil.copy2(ROOT / 'vendor/cef' / source, contents / 'Resources' / source)
        shutil.copy2(ROOT / 'vendor/sparkle/LICENSE', contents / 'Resources/Sparkle-LICENSE.txt')
        shutil.copy2(ROOT / 'vendor/cef/include/cef_version.h', contents / 'Resources/CEF-SDK.txt')
        shutil.copy2(ROOT / 'resources/crash_reporter.cfg', contents / 'Resources/crash_reporter.cfg')
        shutil.copytree(ROOT / 'resources/ContentBlocking', contents / 'Resources/ContentBlocking')
        if (ROOT / 'resources/Lite.icns').exists():
            shutil.copy2(ROOT / 'resources/Lite.icns', contents / 'Resources/Lite.icns')
        sign(app, identity, ROOT / 'resources/entitlements/browser.plist', production)
        verify(app, production)
        if identity != '-' and not stable_requirement(app):
            raise ValueError('The signed bundle still has a per-build designated requirement')
        if production:
            archive = pathlib.Path(temporary) / 'notarization.zip'
            run('ditto', '-c', '-k', '--keepParent', app, archive)
            run('xcrun', 'notarytool', 'submit', archive, '--keychain-profile', os.environ['LITE_NOTARY_PROFILE'], '--wait')
            run('xcrun', 'stapler', 'staple', app)
            run('xcrun', 'stapler', 'validate', app)
            run('spctl', '--assess', '--type', 'execute', '--verbose=2', app)
        recover(destination)
        replace_directory(app, destination, lambda p: subprocess.run(['codesign', '--verify', '--deep', '--strict', str(p)], capture_output=True).returncode == 0)
    if production:
        archive = destination.parent / f"Lite-{info['CFBundleVersion']}-{info['LTArchitecture']}.zip"
        partial = archive.with_suffix('.partial.zip')
        run('ditto', '-c', '-k', '--keepParent', destination, partial)
        # Re-extract and verify the exact distributed bytes, including its staple.
        with tempfile.TemporaryDirectory(prefix='.lite-artifact-', dir=destination.parent) as temporary:
            run('ditto', '-x', '-k', partial, temporary)
            extracted = pathlib.Path(temporary) / 'Lite.app'
            verify(extracted, True)
            run('xcrun', 'stapler', 'validate', extracted)
            run('spctl', '--assess', '--type', 'execute', extracted)
        partial.replace(archive)
        archive.with_suffix('.zip.sha256').write_text(digest(archive) + '  ' + archive.name + '\n')
        print('Developer ID signed, notarized, stapled, and verified:', archive)
    elif identity != '-':
        print('Test bundle (signed with the local test identity; not notarized):', destination)
    else:
        print('Local development bundle (ad hoc signed; not notarized):', destination)
    return destination


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--production', action='store_true')
    parser.add_argument('--test', action='store_true')
    parser.add_argument('--output', type=pathlib.Path)
    args = parser.parse_args()
    if args.production and args.test:
        parser.error('A test bundle cannot be a production build')
    try:
        package(args.production, args.output, args.test)
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        raise SystemExit(str(error))
