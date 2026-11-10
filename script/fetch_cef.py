#!/usr/bin/env python3
"""Fetch the pinned CEF SDK, verifying its archive, version, architecture and files."""
import pathlib
import shutil
import platform
import re
import subprocess
import tempfile
from sdk_support import digest, download, extract_tar, installation_lock, recover, replace_directory, valid_receipt, write_receipt

ROOT = pathlib.Path(__file__).resolve().parents[1]
VERSION = '156.0.27+ga10dae3+chromium-156.0.8078.88'
DIGESTS = {'macosarm64': 'fe8d1915b99c5ad6ba00c4cc13f53af1ae289ff3', 'macosx64': 'f7894e013b16ee11eb62bef7de86b8cc92a1b337'}


def sdk_matches(directory, arch):
    try:
        header = (directory / 'include/cef_version.h').read_text()
        if re.search(r'^#define CEF_VERSION "([^"]+)"', header, re.M).group(1) != VERSION:
            return False
        framework = directory / 'Release/Chromium Embedded Framework.framework/Chromium Embedded Framework'
        actual = subprocess.check_output(['lipo', '-archs', str(framework)], text=True, stderr=subprocess.DEVNULL).split()
        expected = 'arm64' if arch == 'macosarm64' else 'x86_64'
        return actual == [expected] and all((directory / path).is_file() for path in ['CMakeLists.txt', 'LICENSE.txt', 'include/cef_app.h'])
    except (OSError, AttributeError, subprocess.CalledProcessError):
        return False


def fetch(vendor, arch):
    identity = {'version': VERSION, 'architecture': arch, 'sha1': DIGESTS[arch]}
    destination = vendor / 'cef'
    validate = lambda path: sdk_matches(path, arch) and valid_receipt(path, identity)
    with installation_lock(vendor, 'cef'):
        for abandoned in vendor.glob('.cef-stage-*'):
            if abandoned.is_dir() and not abandoned.is_symlink():
                shutil.rmtree(abandoned)
        recover(destination)
        if validate(destination):
            print('CEF SDK version, architecture and installed integrity verified.')
            return
        name = f'cef_binary_{VERSION}_{arch}_minimal'
        archive = vendor / f'{name}.tar.bz2'
        # Accept a legacy cache only after checking the pinned digest; never trust
        # a header-only existing install or create a receipt from untrusted files.
        legacy = vendor / ('cef-arm64.tar.bz2' if arch == 'macosarm64' else 'cef-x64.tar.bz2')
        if not archive.exists() and legacy.exists() and digest(legacy, 'sha1') == DIGESTS[arch]:
            archive = legacy
        download('https://cef-builds.spotifycdn.com/' + name.replace('+', '%2B') + '.tar.bz2', archive, DIGESTS[arch], 'sha1')
        with tempfile.TemporaryDirectory(prefix='.cef-stage-', dir=vendor) as temporary:
            staging = pathlib.Path(temporary)
            extract_tar(archive, staging)
            candidate = staging / name
            if not sdk_matches(candidate, arch):
                raise ValueError('CEF SDK version or architecture mismatch; existing installation preserved')
            write_receipt(candidate, identity)
            replace_directory(candidate, destination, validate)
        print('CEF SDK verified and installed transactionally.')


if __name__ == '__main__':
    machine = platform.machine()
    if machine not in ('arm64', 'x86_64'):
        raise SystemExit('Unsupported macOS architecture: ' + machine)
    fetch(ROOT / 'vendor', 'macosarm64' if machine == 'arm64' else 'macosx64')
