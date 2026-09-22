#!/usr/bin/env python3
"""Catch missing Bluetooth privacy metadata before shipping the app bundle."""
import pathlib
import plistlib
import unittest

root = pathlib.Path(__file__).resolve().parents[1]


class PackagePrivacyTests(unittest.TestCase):
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
