#!/usr/bin/env python3
"""Fetch Sparkle's official, checksum-pinned binary distribution (build time only)."""
import pathlib
import shutil
import plistlib
import subprocess
import tempfile
from sdk_support import download, installation_lock, recover, replace_directory, valid_receipt, write_receipt

ROOT = pathlib.Path(__file__).resolve().parents[1]
VERSION = '2.10.0'
# Published by upstream in Package.swift at tag 2.10.0.
SHA256 = '17e28312b8e18ab7cdbbe09a6fb28cc55a5479ec6c371dbc07cdecd2a14fd959'
FRAMEWORK = 'Sparkle.framework'
IDENTITY = {'version': VERSION, 'sha256': SHA256}


def framework_matches(directory):
    try:
        info = plistlib.loads((directory / FRAMEWORK / 'Resources/Info.plist').read_bytes())
        return info['CFBundleShortVersionString'] == VERSION
    except (OSError, ValueError, KeyError):
        return False


def fetch():
    vendor = ROOT / 'vendor'
    destination = vendor / 'sparkle'
    validate = lambda path: framework_matches(path) and valid_receipt(path, IDENTITY)
    with installation_lock(vendor, 'sparkle'):
        for abandoned in vendor.glob('.sparkle-stage-*'):
            if abandoned.is_dir() and not abandoned.is_symlink():
                shutil.rmtree(abandoned)
        recover(destination)
        if validate(destination):
            print('Sparkle version and installed integrity verified.')
            return
        archive = vendor / ('Sparkle-' + VERSION + '.zip')
        download('https://github.com/sparkle-project/Sparkle/releases/download/' + VERSION + '/Sparkle-for-Swift-Package-Manager.zip', archive, SHA256)
        with tempfile.TemporaryDirectory(prefix='.sparkle-stage-', dir=vendor) as temporary:
            candidate = pathlib.Path(temporary) / 'sdk'
            candidate.mkdir()
            subprocess.run(['ditto', '-x', '-k', str(archive), str(candidate)], check=True)
            (candidate / FRAMEWORK).symlink_to('Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework')
            if not framework_matches(candidate):
                raise ValueError('Sparkle version mismatch')
            write_receipt(candidate, IDENTITY)
            replace_directory(candidate, destination, validate)
        print('Sparkle SDK verified and installed transactionally.')


if __name__ == '__main__':
    fetch()
