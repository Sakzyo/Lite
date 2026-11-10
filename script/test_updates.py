#!/usr/bin/env python3
"""Disposable SDK transaction tests and real Sparkle Ed25519 signature regressions."""
import base64
import errno
import hashlib
import io
import os
import pathlib
import platform
import struct
import subprocess
import tarfile
import tempfile
import unittest
import urllib.error
from unittest import mock
import fetch_cef
import update_cef
from sdk_support import digest, download, extract_tar, recover, replace_directory, valid_receipt
from package import crash_configuration, filter_configuration, release_configuration

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
        # lipo names x86_64 only with CPU_SUBTYPE_X86_64_ALL (3); arm64's ALL subtype is 0.
        cpu, subtype = (0x0100000c, 0) if ARCH == 'macosarm64' else (0x01000007, 3)
        binary = struct.pack('<8I', 0xfeedfacf, cpu, subtype, 6, 0, 0, 0, 0)
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

    def server_error(self, code):
        return urllib.error.HTTPError('https://fixture.invalid/archive', code, 'fixture', {}, None)

    def test_transient_server_error_is_retried(self):
        archive = self.directory / 'retried.zip'
        expected = hashlib.sha256(b'payload').hexdigest()
        with mock.patch('urllib.request.urlopen', side_effect=[self.server_error(504), io.BytesIO(b'payload')]) as urlopen, \
                mock.patch('time.sleep') as sleep, mock.patch('sys.stderr', io.StringIO()):
            download('https://fixture.invalid/archive', archive, expected)
        self.assertEqual(urlopen.call_count, 2)
        sleep.assert_called_once_with(2)
        self.assertEqual(archive.read_bytes(), b'payload')

    def test_persistent_server_error_stops_after_bounded_retries(self):
        archive = self.directory / 'unavailable.zip'
        with mock.patch('urllib.request.urlopen', side_effect=self.server_error(503)) as urlopen, \
                mock.patch('time.sleep') as sleep, mock.patch('sys.stderr', io.StringIO()):
            with self.assertRaises(urllib.error.HTTPError):
                download('https://fixture.invalid/archive', archive, '0' * 64)
        self.assertEqual(urlopen.call_count, 4)
        self.assertEqual([call.args[0] for call in sleep.call_args_list], [2, 4, 8])
        self.assertFalse(archive.exists())

    def test_client_error_is_not_retried(self):
        with mock.patch('urllib.request.urlopen', side_effect=self.server_error(404)) as urlopen, mock.patch('time.sleep') as sleep:
            with self.assertRaises(urllib.error.HTTPError):
                download('https://fixture.invalid/archive', self.directory / 'missing.zip', '0' * 64)
        self.assertEqual(urlopen.call_count, 1)
        sleep.assert_not_called()

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


class CrashConfigurationTests(unittest.TestCase):
    def test_only_sentry_https_endpoints_are_accepted(self):
        info = {}
        crash_configuration(info, None)
        self.assertEqual(info, {})
        url = 'https://o1.ingest.de.sentry.io/api/2/minidump/?sentry_key=public'
        crash_configuration(info, url)
        self.assertEqual(info['LTCrashUploadURL'], url)
        for value in ['http://o1.ingest.sentry.io/api/2/minidump/', 'https://evil-sentry.io/', 'https://sentry.io.evil.test/',
                      'https://user:secret@o1.ingest.sentry.io/', 'not a url']:
            with self.assertRaises(ValueError, msg=value):
                crash_configuration({}, value)


class FilterConfigurationTests(unittest.TestCase):
    KEY = 'MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE/eSuEG+xnhiwzt/9ax1u2hlYz8uMubIwYTbssz6EQUClaHRCycC6W3t4pgLebt7gR/pp45H1RxSTWhu81utj0Q=='

    def test_feed_and_key_are_both_required_and_checked(self):
        info = {}
        filter_configuration(info, None, None, production=True)
        self.assertEqual(info, {})
        filter_configuration(info, 'https://filters.example/lite/', self.KEY, production=True)
        self.assertEqual(info, dict(LTFilterFeedURL='https://filters.example/lite/', LTFilterPublicKey=self.KEY))
        point = base64.b64encode(base64.b64decode(self.KEY)[26:]).decode()
        filter_configuration({}, 'https://filters.example/', point, production=True)
        filter_configuration({}, 'http://127.0.0.1:18743/filters/', self.KEY)
        for feed, key, production in [('https://filters.example/', None, True), (None, self.KEY, True),
                                      ('http://filters.example/', self.KEY, False), ('http://127.0.0.1/filters/', self.KEY, True),
                                      ('https://user:pw@filters.example/', self.KEY, True), ('https://filters.example/?a=1', self.KEY, True),
                                      ('https://filters.example/', base64.b64encode(b'\x04' + b'\0' * 31).decode(), True),
                                      ('https://filters.example/', 'not base64!', True)]:
            with self.subTest(feed=feed, key=key, production=production), self.assertRaises(ValueError):
                filter_configuration({}, feed, key, production)


class CEFPinTests(unittest.TestCase):
    OLD = '154.0.23+g062ebe4+chromium-154.0.8037.17'
    NEW = '156.0.15+gcf671c0+chromium-156.0.8078.80'
    NEWER = '156.0.16+gabc1234+chromium-156.0.8078.90'
    SOURCE = f"ROOT = 1\nVERSION = '{OLD}'\nDIGESTS = {{'macosarm64': '{'a' * 40}', 'macosx64': '{'b' * 40}'}}\n"

    @staticmethod
    def build(version, digest='c' * 40, channel='stable'):
        return dict(cef_version=version, channel=channel, files=[dict(type='standard', sha1='0' * 40), dict(type='minimal', sha1=digest)])

    def update(self, arm, intel):
        index = dict(macosarm64=dict(versions=arm), macosx64=dict(versions=intel))
        with tempfile.TemporaryDirectory(prefix='lite-pin-test-') as temporary:
            path = pathlib.Path(temporary) / 'fetch_cef.py'
            path.write_text(self.SOURCE)
            return update_cef.update(index, path), path.read_text()

    def test_writes_each_architecture_minimal_digest(self):
        version, source = self.update([self.build(self.NEW, 'c' * 40)], [self.build(self.NEW, 'd' * 40)])
        self.assertEqual(version, self.NEW)
        self.assertEqual(update_cef.pinned(source)[0], self.NEW)
        namespace = {}
        exec(source, namespace)
        self.assertEqual(namespace['DIGESTS'], {'macosarm64': 'c' * 40, 'macosx64': 'd' * 40})

    def test_ignores_beta_and_chooses_by_version_not_index_order(self):
        builds = [self.build(self.NEW), self.build(self.NEWER), self.build('157.0.1+g1234567+chromium-157.0.8100.1', channel='beta')]
        self.assertEqual(self.update(builds, builds)[0], self.NEWER)

    def test_waits_for_both_architectures(self):
        self.assertEqual(self.update([self.build(self.NEW), self.build(self.NEWER)], [self.build(self.NEW)])[0], self.NEW)

    def test_does_not_rewrite_current_or_older_pin(self):
        builds = [self.build(self.OLD), self.build('153.0.9+g1234567+chromium-153.0.7900.1')]
        version, source = self.update(builds, builds)
        self.assertIsNone(version)
        self.assertEqual(source, self.SOURCE)

    def test_rejects_unexpected_index_values(self):
        unsafe = [self.build(self.NEW + "'\nimport os"), self.build(self.NEW, "' + evil + '")]
        self.assertIsNone(self.update(unsafe + [self.build(self.OLD)], unsafe + [self.build(self.OLD)])[0])
        with self.assertRaises(ValueError):
            self.update([self.build(self.NEW)], [])

    def test_real_pin_can_be_read(self):
        self.assertEqual(update_cef.pinned((ROOT / 'script/fetch_cef.py').read_text())[0], fetch_cef.VERSION)


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
