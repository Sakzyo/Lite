#!/usr/bin/env python3
"""Disposable SDK transaction tests and real Sparkle Ed25519 signature regressions."""
import base64
import errno
import io
import os
import pathlib
import platform
import struct
import subprocess
import tarfile
import tempfile
import unittest
from unittest import mock
import fetch_cef
from sdk_support import digest, download, extract_tar, recover, replace_directory, valid_receipt
from package import release_configuration

ROOT = pathlib.Path(__file__).resolve().parents[1]
ARCH = 'macosarm64' if platform.machine() == 'arm64' else 'macosx64'


class SDKTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='lite-sdk-test-')
        self.directory = pathlib.Path(self.temporary.name)
        self.vendor = self.directory / 'vendor'
        self.vendor.mkdir()
        self.name = f'cef_binary_{fetch_cef.VERSION}_{ARCH}_minimal'
        self.archive = self.vendor / (self.name + '.tar.bz2')
        self.sdk = self.vendor / 'cef'
        # A minimal real Mach-O header lets lipo inspect CPU type without a compiler.
        cpu = 0x0100000c if ARCH == 'macosarm64' else 0x01000007
        binary = struct.pack('<8I', 0xfeedfacf, cpu, 0, 6, 0, 0, 0, 0)
        files = {'include/cef_version.h': f'#define CEF_VERSION "{fetch_cef.VERSION}"\n'.encode(),
                 'include/cef_app.h': b'fixture', 'CMakeLists.txt': b'fixture', 'LICENSE.txt': b'fixture',
                 'Release/Chromium Embedded Framework.framework/Chromium Embedded Framework': binary}
        with tarfile.open(self.archive, 'w:bz2') as archive:
            for name, content in files.items():
                member = tarfile.TarInfo(self.name + '/' + name)
                member.size = len(content)
                archive.addfile(member, io.BytesIO(content))
        self.expected = digest(self.archive, 'sha1')
        self.digests = mock.patch.dict(fetch_cef.DIGESTS, {ARCH: self.expected})
        self.digests.start()

    def tearDown(self):
        self.digests.stop()
        self.temporary.cleanup()

    def test_correct_sdk_reused_without_network(self):
        fetch_cef.fetch(self.vendor, ARCH)
        with mock.patch('urllib.request.urlopen', side_effect=AssertionError('unexpected network')):
            fetch_cef.fetch(self.vendor, ARCH)
        self.assertTrue(fetch_cef.sdk_matches(self.sdk, ARCH))

    def test_header_only_and_wrong_version_replaced(self):
        (self.sdk / 'include').mkdir(parents=True)
        (self.sdk / 'include/cef_version.h').write_text('#define CEF_VERSION "old"\n')
        fetch_cef.fetch(self.vendor, ARCH)
        self.assertTrue(fetch_cef.sdk_matches(self.sdk, ARCH))

    def test_wrong_architecture_is_rejected(self):
        fetch_cef.fetch(self.vendor, ARCH)
        other = 'macosx64' if ARCH == 'macosarm64' else 'macosarm64'
        self.assertFalse(fetch_cef.sdk_matches(self.sdk, other))

    def test_installed_corruption_repaired_from_verified_archive(self):
        fetch_cef.fetch(self.vendor, ARCH)
        (self.sdk / 'LICENSE.txt').write_text('corrupted')
        fetch_cef.fetch(self.vendor, ARCH)
        self.assertEqual((self.sdk / 'LICENSE.txt').read_text(), 'fixture')

    def test_corrupt_archive_and_interrupted_download_preserve_sdk(self):
        fetch_cef.fetch(self.vendor, ARCH)
        (self.sdk / 'LICENSE.txt').write_text('old intact data')
        self.archive.write_bytes(b'corrupt archive')
        class BrokenResponse(io.BytesIO):
            def read(self, size=-1):
                raise ConnectionResetError('fixture download interrupted')
        with mock.patch('urllib.request.urlopen', return_value=BrokenResponse(b'data')):
            with self.assertRaises(ConnectionResetError):
                fetch_cef.fetch(self.vendor, ARCH)
        self.assertEqual((self.sdk / 'LICENSE.txt').read_text(), 'old intact data')
        self.assertFalse(self.archive.with_name(self.archive.name + '.partial').exists())

    def test_wrong_download_digest_is_rejected(self):
        with mock.patch('urllib.request.urlopen', return_value=io.BytesIO(b'bad archive')):
            with self.assertRaisesRegex(ValueError, 'checksum'):
                download('https://fixture.invalid/archive', self.archive, '0' * 40, 'sha1')
        self.assertEqual(digest(self.archive, 'sha1'), self.expected)

    def test_interrupted_replacement_recovers_old_installation(self):
        self.sdk.mkdir()
        (self.sdk / 'original').write_text('preserved')
        self.sdk.rename(self.vendor / '.cef.previous')
        recover(self.sdk)
        self.assertEqual((self.sdk / 'original').read_text(), 'preserved')

    def test_disk_full_and_validation_failure_roll_back(self):
        self.sdk.mkdir()
        (self.sdk / 'original').write_text('preserved')
        staged = self.directory / 'candidate'
        staged.mkdir()
        rename = pathlib.Path.rename
        def full_disk(path, target):
            if path == staged:
                raise OSError(errno.ENOSPC, 'synthetic disk full')
            return rename(path, target)
        with mock.patch.object(pathlib.Path, 'rename', full_disk):
            with self.assertRaises(OSError):
                replace_directory(staged, self.sdk, lambda _: True)
        self.assertEqual((self.sdk / 'original').read_text(), 'preserved')
        checks = iter([True, False])
        with self.assertRaises(ValueError):
            replace_directory(staged, self.sdk, lambda _: next(checks))
        self.assertEqual((self.sdk / 'original').read_text(), 'preserved')

    def test_unsafe_archive_paths_and_links_rejected(self):
        for name, target in [('../outside', None), ('sdk/link', '../../outside'), ('sdk/hard', '../../outside')]:
            with self.subTest(name=name):
                archive = self.directory / 'unsafe.tar'
                with tarfile.open(archive, 'w') as tar:
                    entry = tarfile.TarInfo(name)
                    if target:
                        entry.type = tarfile.LNKTYPE if 'hard' in name else tarfile.SYMTYPE
                        entry.linkname = target
                    tar.addfile(entry)
                with self.assertRaises(ValueError):
                    extract_tar(archive, self.directory / 'extracted')
                self.assertFalse((self.directory.parent / 'outside').exists())


class UpdateSigningTests(unittest.TestCase):
    def test_sparkle_valid_and_invalid_signatures(self):
        tool = ROOT / 'vendor/sparkle/bin/sign_update'
        self.assertTrue(tool.is_file(), 'Fetch pinned Sparkle before running release verification')
        with tempfile.TemporaryDirectory(prefix='lite-update-signature-') as temporary:
            directory = pathlib.Path(temporary)
            key = directory / 'synthetic-key'
            key.write_bytes(base64.b64encode(os.urandom(32)))
            key.chmod(0o600)
            archive = directory / 'update.zip'
            archive.write_bytes(b'synthetic complete-bundle archive fixture')
            signature = subprocess.check_output([str(tool), '-f', str(key), '-p', str(archive)], text=True).strip()
            subprocess.run([str(tool), '--verify', '-f', str(key), str(archive), signature], check=True, capture_output=True)
            archive.write_bytes(archive.read_bytes() + b'tampered')
            self.assertNotEqual(subprocess.run([str(tool), '--verify', '-f', str(key), str(archive), signature], capture_output=True).returncode, 0)
            # Feed verification uses Sparkle's embedded XML-signature format.
            feed = directory / 'appcast.xml'
            feed.write_text('<?xml version="1.0"?><rss version="2.0"><channel><title>Test</title></channel></rss>')
            subprocess.run([str(tool), '-f', str(key), str(feed)], check=True, capture_output=True)
            subprocess.run([str(tool), '--verify', '-f', str(key), str(feed)], check=True, capture_output=True)
            feed.write_text(feed.read_text().replace('<title>Test</title>', '<title>Tampered</title>'))
            self.assertNotEqual(subprocess.run([str(tool), '--verify', '-f', str(key), str(feed)], capture_output=True).returncode, 0)

    def test_release_requires_feed_key_and_increasing_build_format(self):
        key = base64.b64encode(b'\0' * 32).decode()
        for feed, public, build in [('', key, '2'), ('http://invalid.test/feed', key, '2'), ('https://invalid.test/feed', 'bad', '2'), ('https://invalid.test/feed', key, '0'), ('https://invalid.test/feed', key, '2junk')]:
            with self.subTest(feed=feed, build=build), self.assertRaises(ValueError):
                release_configuration({}, feed, public, build)
        info = {}
        release_configuration(info, 'https://invalid.test/feed', key, '2')
        self.assertTrue(info['LTUpdatesEnabled'])


if __name__ == '__main__':
    unittest.main()
