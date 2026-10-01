#!/usr/bin/env python3
"""Catch missing Bluetooth privacy metadata before shipping the app bundle."""
import os
import subprocess
import pathlib
import plistlib
import unittest
import hashlib
import json

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


if __name__ == '__main__':
    unittest.main()
