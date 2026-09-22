#!/usr/bin/env python3
"""Fetch an exact official CEF SDK; verify the upstream digest before extraction."""
import hashlib, os, pathlib, platform, shutil, tarfile, urllib.request
ROOT = pathlib.Path(__file__).resolve().parents[1]
VERSION = '154.0.23+g062ebe4+chromium-154.0.8037.17'
ARCH = 'macosarm64' if platform.machine() == 'arm64' else 'macosx64'
SHA1 = {'macosarm64': '9fdef241a8c682d98743c9fc6b27f5e54045551e', 'macosx64': 'ae3b583f32a980f373d32e82e120eac45848d1fb'}[ARCH]
vendor = ROOT / 'vendor'
if (vendor / 'cef/include/cef_version.h').exists():
    raise SystemExit(0)
vendor.mkdir(exist_ok=True)
name = f'cef_binary_{VERSION}_{ARCH}_minimal'
archive = vendor / f'{name}.tar.bz2'
if not archive.exists():
    print('Downloading official Chromium/CEF SDK (about 132–138 MB)…', flush=True)
    partial = archive.with_suffix('.partial')
    urllib.request.urlretrieve('https://cef-builds.spotifycdn.com/' + name.replace('+', '%2B') + '.tar.bz2', partial)
    partial.rename(archive)
with archive.open('rb') as f:
    digest = hashlib.file_digest(f, 'sha1').hexdigest()
if digest != SHA1:
    raise SystemExit('CEF archive checksum mismatch. Remove the archive and retry.')
with tarfile.open(archive, 'r:bz2') as tar:
    for entry in tar.getmembers():
        if not (vendor / entry.name).resolve().is_relative_to(vendor.resolve()):
            raise SystemExit('Unsafe archive path')
        if entry.issym() and not (vendor / entry.name).parent.joinpath(entry.linkname).resolve().is_relative_to(vendor.resolve()):
            raise SystemExit('Unsafe archive link')
    tar.extractall(vendor)
(vendor / name).rename(vendor / 'cef')
print('CEF SDK verified and ready.')
