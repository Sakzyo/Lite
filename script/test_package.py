#!/usr/bin/env python3
"""Catch missing Bluetooth privacy metadata before shipping the app bundle."""
import pathlib
import plistlib
import unittest
import hashlib
import json

root = pathlib.Path(__file__).resolve().parents[1]


class PackagePrivacyTests(unittest.TestCase):
    def test_content_blocking_resources(self):
        for directory in [root/'resources/ContentBlocking', root/'dist/Lite.app/Contents/Resources/ContentBlocking']:
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

    def test_bluetooth_usage_description(self):
        for path in [root/'resources/Info.plist', root/'dist/Lite.app/Contents/Info.plist']:
            with self.subTest(plist=str(path)):
                with path.open('rb') as f:
                    info = plistlib.load(f)
                description = info.get('NSBluetoothAlwaysUsageDescription')
                self.assertIsInstance(description, str)
                self.assertTrue(description.strip(), 'Bluetooth usage description must not be empty')


if __name__ == '__main__':
    unittest.main()
