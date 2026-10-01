#!/usr/bin/env python3
"""Prepare and sign a full-bundle Sparkle feed; never uploads or publishes it."""
import argparse
import pathlib
import plistlib
import subprocess
import tempfile
import urllib.parse
import xml.etree.ElementTree as ET
from package import verify

ROOT = pathlib.Path(__file__).resolve().parents[1]
SPARKLE = 'http://www.andymatuschak.org/xml-namespaces/sparkle'
LITE = 'https://lite.app/xml-namespaces/updates'
ET.register_namespace('sparkle', SPARKLE)
ET.register_namespace('lite', LITE)


def prepare(directory, prefix, account):
    if urllib.parse.urlsplit(prefix).scheme != 'https':
        raise ValueError('Updates require an HTTPS download URL prefix')
    metadata = {}
    for archive in sorted(directory.glob('*.zip')):
        with tempfile.TemporaryDirectory(prefix='lite-appcast-') as temporary:
            subprocess.run(['ditto', '-x', '-k', str(archive), temporary], check=True)
            app = pathlib.Path(temporary) / 'Lite.app'
            verify(app, True)
            subprocess.run(['xcrun', 'stapler', 'validate', str(app)], check=True)
            info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
            build = info['CFBundleVersion']
            if build in metadata:
                raise ValueError('Use a separate feed directory for each architecture; duplicate build ' + build)
            metadata[build] = info
    if not metadata:
        raise ValueError('No production Lite ZIP archives found')
    architectures = {info['LTArchitecture'] for info in metadata.values()}
    if len(architectures) != 1:
        raise ValueError('Do not mix CPU architectures in one update feed directory')
    output = directory / 'appcast.xml'
    subprocess.run([str(ROOT / 'vendor/sparkle/bin/generate_appcast'), '--account', account,
                    '--maximum-deltas', '0', '--download-url-prefix', prefix,
                    '-o', str(output), str(directory)], check=True)
    tree = ET.parse(output)
    for item in tree.findall('./channel/item'):
        build = item.findtext('{' + SPARKLE + '}version')
        info = metadata.get(build)
        if info is None:
            raise ValueError('Appcast references a build with no validated local archive: ' + str(build))
        for key, value in [('minimumProfileSchema', info['LTMinimumReadableProfileSchema']),
                           ('maximumProfileSchema', info['LTProfileSchemaVersion']),
                           ('architecture', info['LTArchitecture'])]:
            tag = '{' + LITE + '}' + key
            element = item.find(tag)
            if element is None:
                element = ET.SubElement(item, tag)
            element.text = str(value)
        if item.find('{' + SPARKLE + '}deltas') is not None:
            raise ValueError('Lite only distributes complete application bundles')
    tree.write(output, encoding='utf-8', xml_declaration=True)
    # Re-sign after custom compatibility metadata changes; Sparkle implements all
    # cryptography and retains the private key in the specified Keychain account.
    sign = ROOT / 'vendor/sparkle/bin/sign_update'
    subprocess.run([str(sign), '--account', account, str(output)], check=True)
    subprocess.run([str(sign), '--verify', '--account', account, str(output)], check=True)
    print('Prepared signed feed (not published):', output)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=pathlib.Path)
    parser.add_argument('--download-url-prefix', required=True)
    parser.add_argument('--account', default='lite-updates')
    args = parser.parse_args()
    prepare(args.directory.resolve(), args.download_url_prefix, args.account)
