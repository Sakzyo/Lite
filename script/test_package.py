#!/usr/bin/env python3
"""Catch missing Bluetooth privacy metadata before shipping the app bundle."""
import os
import subprocess
import pathlib
import plistlib
import unittest
import hashlib
import json
from unittest import mock
from package import bundle_identity, test_signing_identity
from test_processes import window_failure

root = pathlib.Path(__file__).resolve().parents[1]
app = pathlib.Path(os.environ.get('LITE_PACKAGE_APP', root/'dist/Lite.app'))


class PackagePrivacyTests(unittest.TestCase):
    def test_content_blocking_resources(self):
        for directory in [root/'resources/ContentBlocking', app/'Contents/Resources/ContentBlocking']:
            with self.subTest(directory=str(directory)):
                metadata = json.loads((directory/'provenance.json').read_text())
                for name, digest in metadata['sha256'].items():
                    self.assertEqual(hashlib.sha256((directory/name).read_bytes()).hexdigest(), digest, name)
                self.assertTrue((directory/'NOTICE.txt').is_file())
                self.assertTrue((directory/'COPYING-uBOL.txt').is_file())
                self.assertTrue((directory/'youtube.js').read_text().strip())
                rules = json.loads((directory/'network.json').read_text())
                self.assertEqual(len(rules), metadata['networkRules'])
                self.assertTrue(all(r['action']['type'] in ['block', 'allow'] for r in rules))

    def test_complete_bundle_and_architecture(self):
        info = plistlib.loads((app/'Contents/Info.plist').read_bytes())
        executable = app/'Contents/MacOS/Lite'
        arch = subprocess.check_output(['lipo', '-archs', str(executable)], text=True).strip()
        self.assertIn(arch, ('arm64', 'x86_64'))
        self.assertEqual(info['LTArchitecture'], arch)
        from fetch_cef import VERSION
        from fetch_sparkle import VERSION as SPARKLE_VERSION
        self.assertIn('#define CEF_VERSION "' + VERSION + '"', (app/'Contents/Resources/CEF-SDK.txt').read_text())
        sparkle_info = plistlib.loads((app/'Contents/Frameworks/Sparkle.framework/Resources/Info.plist').read_bytes())
        self.assertEqual(sparkle_info['CFBundleShortVersionString'], SPARKLE_VERSION)
        framework = app/'Contents/Frameworks/Chromium Embedded Framework.framework'
        self.assertEqual(subprocess.check_output(['lipo', '-archs', str(framework/'Chromium Embedded Framework')], text=True).strip(), arch)
        for name in ['icudtl.dat', 'resources.pak', 'chrome_100_percent.pak', 'chrome_200_percent.pak']:
            self.assertTrue((framework/'Resources'/name).is_file(), name)
        self.assertTrue(list((framework/'Resources').glob('v8_context_snapshot*.bin')))
        for suffix in ['', ' (Alerts)', ' (GPU)', ' (Plugin)', ' (Renderer)']:
            name = 'Lite Helper' + suffix
            helper = app/'Contents/Frameworks'/(name+'.app')/'Contents'
            self.assertEqual(subprocess.check_output(['lipo', '-archs', str(helper/'MacOS'/name)], text=True).strip(), arch)
            self.assertEqual(plistlib.loads((helper/'Info.plist').read_bytes())['CFBundleVersion'], info['CFBundleVersion'])
        self.assertTrue((app/'Contents/Frameworks/Sparkle.framework/Sparkle').is_file())
        for binary in [executable, framework/'Chromium Embedded Framework']:
            dependencies = subprocess.check_output(['otool', '-L', str(binary)], text=True).splitlines()[1:]
            for dependency in dependencies:
                path = dependency.strip().split(' (', 1)[0]
                self.assertTrue(path.startswith(('/usr/lib/', '/System/Library/', '@rpath/', '@loader_path/', '@executable_path/')), path)
        for path in app.rglob('*'):
            if path.is_symlink():
                self.assertTrue(path.resolve().is_relative_to(app.resolve()), str(path))

    def test_updater_fails_closed(self):
        info = plistlib.loads((app/'Contents/Info.plist').read_bytes())
        self.assertIs(info['SUVerifyUpdateBeforeExtraction'], True)
        self.assertIs(info['SURequireSignedFeed'], True)
        self.assertEqual(info['SUSignedFeedFailureExpirationInterval'], 0)
        self.assertGreaterEqual(info['SUScheduledCheckInterval'], 86400)
        self.assertIs(info['SUAllowsAutomaticUpdates'], False)
        self.assertIs(info['SUEnableSystemProfiling'], False)
        if info['LTUpdatesEnabled']:
            from package import release_configuration
            release_configuration(dict(info), info.get('SUFeedURL'), info.get('SUPublicEDKey'), info.get('CFBundleVersion'))
        else:
            self.assertNotIn('SUFeedURL', info)
            self.assertNotIn('SUPublicEDKey', info)

    def test_test_code_is_only_in_test_bundles(self):
        markers = [b'LTSmoke', b'LTNativeSmoke', b'--lite-', b'LITE_START_URL', b'ForTesting']
        main = (app/'Contents/MacOS/Lite').read_bytes()
        if plistlib.loads((app/'Contents/Info.plist').read_bytes())['LiteDistribution'] == 'Test':
            # A marker that vanished from the test build would make the release check meaningless.
            self.assertEqual([marker for marker in markers if marker not in main], [])
            return
        binaries = [main] + [path.read_bytes() for path in (app/'Contents/Frameworks').glob('Lite Helper*.app/Contents/MacOS/*')]
        self.assertEqual(len(binaries), 6)
        for binary in binaries:
            self.assertEqual([marker for marker in markers if marker in binary], [])

    def test_crash_reports_never_upload_automatically(self):
        for path in [root/'resources/crash_reporter.cfg', app/'Contents/Resources/crash_reporter.cfg']:
            with self.subTest(path=str(path)):
                settings = [line.partition('=')[0].strip().lower() for line in path.read_text().splitlines()]
                self.assertIn('productname', settings)
                self.assertNotIn('serverurl', settings)
        info = plistlib.loads((app/'Contents/Info.plist').read_bytes())
        if 'LTCrashUploadURL' in info:
            from package import crash_configuration
            self.assertEqual(info['LiteDistribution'], 'DeveloperID')
            crash_configuration({}, info['LTCrashUploadURL'])

    def test_entitlements_do_not_weaken_library_validation(self):
        for path in (root/'resources/entitlements').glob('*.plist'):
            entitlements = plistlib.loads(path.read_bytes())
            self.assertNotIn('com.apple.security.cs.disable-library-validation', entitlements)
            self.assertNotIn('com.apple.security.cs.allow-unsigned-executable-memory', entitlements)
            self.assertNotIn('com.apple.security.get-task-allow', entitlements)

    def test_bluetooth_usage_description(self):
        for path in [root/'resources/Info.plist', app/'Contents/Info.plist']:
            with self.subTest(plist=str(path)):
                with path.open('rb') as f:
                    info = plistlib.load(f)
                description = info.get('NSBluetoothAlwaysUsageDescription')
                self.assertIsInstance(description, str)
                self.assertTrue(description.strip(), 'Bluetooth usage description must not be empty')


class WindowFailureTests(unittest.TestCase):
    def test_uninterrupted_or_missing_samples_name_nothing(self):
        self.assertIsNone(window_failure({}))
        self.assertIsNone(window_failure({'windowState': {'samples': 40}}))

    def test_covered_or_inactive_window_is_named_with_its_counts(self):
        self.assertEqual(window_failure({'windowState': {'samples': 40, 'covered': 30}}), 'testWindowInterrupted(covered 30, inactive 0, of 40 samples)')
        self.assertEqual(window_failure({'windowState': {'samples': 40, 'inactive': 2}}), 'testWindowInterrupted(covered 0, inactive 2, of 40 samples)')


class TestSigningIdentityTests(unittest.TestCase):
    HASH = 'A' * 40
    LISTING = ('Policy: Code Signing\n  Matching identities\n'
               f'  1) {HASH} "Lite Local Test Signing" (CSSMERR_TP_NOT_TRUSTED)\n'
               f'  2) {"B" * 40} "Old Identity" (CSSMERR_TP_CERT_EXPIRED)\n'
               '     2 identities found\n\n  Valid identities only\n     0 valid identities found\n')

    def resolve(self, requested, listing=None):
        with mock.patch('subprocess.check_output', return_value=listing or self.LISTING):
            return test_signing_identity(requested)

    def test_unset_stays_ad_hoc(self):
        self.assertEqual(test_signing_identity(None), '-')
        self.assertEqual(test_signing_identity(''), '-')

    def test_self_signed_identity_matches_by_name_or_hash(self):
        self.assertEqual(self.resolve('Lite Local Test Signing'), self.HASH)
        self.assertEqual(self.resolve(self.HASH), self.HASH)

    def test_listing_an_identity_in_both_sections_is_not_ambiguous(self):
        valid = f'  Valid identities only\n  1) {self.HASH} "Lite Local Test Signing"\n'
        self.assertEqual(self.resolve('Lite Local Test Signing', self.LISTING + valid), self.HASH)

    def test_unusable_or_ambiguous_identities_fail_rather_than_fall_back(self):
        twin = f'  3) {"C" * 40} "Lite Local Test Signing" (CSSMERR_TP_NOT_TRUSTED)\n'
        for requested, listing in [('Missing', None), ('Old Identity', None), ('Lite Local Test Signing', self.LISTING + twin)]:
            with self.subTest(requested=requested), self.assertRaises(ValueError):
                self.resolve(requested, listing)

    def test_only_test_bundles_honor_the_test_identity(self):
        with mock.patch.dict(os.environ, {'LITE_TEST_SIGNING_IDENTITY': 'Lite Local Test Signing'}):
            self.assertEqual(bundle_identity(production=False, test=False), '-')
            with mock.patch('package.test_signing_identity', return_value=self.HASH):
                self.assertEqual(bundle_identity(production=False, test=True), self.HASH)
            with mock.patch('package.signing_identity', return_value='release') as production:
                self.assertEqual(bundle_identity(production=True, test=False), 'release')
                production.assert_called_once_with(os.environ.get('LITE_SIGNING_IDENTITY'))


if __name__ == '__main__':
    unittest.main()
