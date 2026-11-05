#!/usr/bin/env python3
"""Point fetch_cef.py at the newest stable CEF build published for both macOS architectures."""
import argparse
import json
import os
import pathlib
import re
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parents[1]
INDEX_URL = 'https://cef-builds.spotifycdn.com/index.json'
ARCHITECTURES = ('macosarm64', 'macosx64')
VERSION_FORMAT = re.compile(r'(\d+)\.(\d+)\.(\d+)\+g[0-9a-f]+\+chromium-(\d+)\.(\d+)\.(\d+)\.(\d+)')
DIGEST_FORMAT = re.compile(r'[0-9a-f]{40}')


def version_key(version):
    match = VERSION_FORMAT.fullmatch(version)
    if not match:
        raise ValueError('Unrecognized CEF version: ' + repr(version))
    return tuple(int(part) for part in match.groups())


def stable_builds(index, architecture):
    """Map each well-formed stable version to its minimal archive's SHA-1 digest."""
    builds = {}
    for build in index[architecture]['versions']:
        version = build.get('cef_version', '')
        if build.get('channel') != 'stable' or not VERSION_FORMAT.fullmatch(version):
            continue
        for artifact in build.get('files', []):
            if artifact.get('type') == 'minimal' and DIGEST_FORMAT.fullmatch(artifact.get('sha1', '')):
                builds[version] = artifact['sha1']
    return builds


def newest_stable(index):
    """Choose by version, not index order. Intel builds publish later than arm64,
    so a version counts only once both architectures have it."""
    builds = {architecture: stable_builds(index, architecture) for architecture in ARCHITECTURES}
    shared = set.intersection(*(set(found) for found in builds.values()))
    if not shared:
        raise ValueError('The CEF index has no stable build for both macOS architectures')
    version = max(shared, key=version_key)
    return version, {architecture: builds[architecture][version] for architecture in ARCHITECTURES}


def pinned(source):
    version = re.search(r"^VERSION = '([^']+)'$", source, re.M)
    digests = re.search(r"^DIGESTS = (\{.*\})$", source, re.M)
    if not version or not digests:
        raise ValueError('fetch_cef.py no longer has the expected VERSION and DIGESTS lines')
    return version.group(1), digests.group(1)


def repin(source, version, digests):
    current_version, current_digests = pinned(source)
    return source.replace(f"VERSION = '{current_version}'", f"VERSION = '{version}'", 1).replace(
        f'DIGESTS = {current_digests}', 'DIGESTS = ' + repr(digests), 1)


def update(index, path):
    """Rewrite the pin only for a newer release. Returns the new version, or None."""
    source = path.read_text()
    current = pinned(source)[0]
    version, digests = newest_stable(index)
    if version_key(version) <= version_key(current):
        return None
    path.write_text(repin(source, version, digests))
    return version


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--index', type=pathlib.Path, help='read this index file instead of downloading it')
    args = parser.parse_args()
    if args.index:
        index = json.loads(args.index.read_text())
    else:
        with urllib.request.urlopen(INDEX_URL, timeout=60) as response:
            index = json.load(response)
    version = update(index, ROOT / 'script/fetch_cef.py')
    print(f'Pinned CEF {version}.' if version else 'CEF is already on the newest stable release.')
    if version and os.environ.get('GITHUB_OUTPUT'):
        with open(os.environ['GITHUB_OUTPUT'], 'a') as output:
            output.write(f'version={version}\nshort={version.split("+")[0]}\n')


if __name__ == '__main__':
    main()
