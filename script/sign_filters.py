#!/usr/bin/env python3
"""Sign content-blocking filters for Lite's filter updates.

  sign_filters.py key PRIVATE.pem
      Create a P-256 signing key, readable only by you, and print the public key that a
      release build takes as LITE_FILTER_PUBLIC_KEY. Refuses to overwrite a key.
  sign_filters.py serial [--source DIR]
      Stamp provenance.json with the current UTC time as the set's serial. Run it after any
      change to the filter files, including youtube.js, and commit the result.
  sign_filters.py publish OUT --key PRIVATE.pem [--source DIR]
      Write a feed into OUT: OUT/<serial>/ with each file, then OUT/filters.json.sig and
      OUT/filters.json. Upload them in that order, so a client never sees a manifest whose
      files are missing.

DIR defaults to resources/ContentBlocking. Lite installs a set only when its serial is larger
than both the set it has and the one bundled with it. The private key never leaves this Mac:
the script passes its path to openssl and never reads or prints it.
"""
import argparse
import base64
import datetime
import hashlib
import json
import os
import pathlib
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'resources/ContentBlocking'
# Must match LTFilterFiles() in lite/model/LTFilterUpdates.m.
FILES = ['network.json', 'cosmetic.json', 'suffixes.txt', 'youtube.js', 'provenance.json', 'NOTICE.txt', 'COPYING-uBOL.txt']
# Published beside the set for the GPL and for reference; Lite does not download them.
SOURCES = ['upstream-source.tar.xz', 'public_suffix_list.dat']
FILE_LIMIT = 32 * 1024 * 1024
TOTAL_LIMIT = 64 * 1024 * 1024


def openssl(*args, **kwargs):
    return subprocess.run(['openssl', *args], check=True, capture_output=True, **kwargs).stdout


def public_key(key):
    return base64.b64encode(openssl('pkey', '-in', str(key), '-pubout', '-outform', 'DER')).decode()


def create_key(path):
    path = pathlib.Path(path)
    if path.exists():
        raise SystemExit(f'{path} already exists; Lite builds trust the key they were made with')
    path.parent.mkdir(parents=True, exist_ok=True)
    old = os.umask(0o077)
    try:
        openssl('genpkey', '-algorithm', 'EC', '-pkeyopt', 'ec_paramgen_curve:P-256', '-out', str(path))
    finally:
        os.umask(old)
    os.chmod(path, 0o600)
    print('Keep this file private and backed up. A build verifies updates with the key it was made with.')
    print('LITE_FILTER_PUBLIC_KEY=' + public_key(path))


def stamp(source):
    provenance = source / 'provenance.json'
    data = json.loads(provenance.read_text())
    data['serial'] = int(datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%d%H%M'))
    provenance.write_text(json.dumps(data, ensure_ascii=True, separators=(',', ':')) + '\n')
    print(f'serial {data["serial"]}')


def describe(path):
    data = path.read_bytes()
    if not data or len(data) > FILE_LIMIT:
        raise SystemExit(f'{path.name} is empty or larger than 32 MB')
    return {'sha256': hashlib.sha256(data).hexdigest(), 'size': len(data)}


def publish(out, key, source):
    out = pathlib.Path(out)
    provenance = json.loads((source / 'provenance.json').read_text())
    serial = provenance.get('serial')
    if not isinstance(serial, int) or isinstance(serial, bool) or not 1 <= serial <= 999999999999:
        raise SystemExit('provenance.json has no serial; run `sign_filters.py serial` first')
    for name, digest in provenance.get('sha256', {}).items():
        if hashlib.sha256((source / name).read_bytes()).hexdigest() != digest:
            raise SystemExit(f'{name} does not match provenance.json')
    previous = out / 'filters.json'
    if previous.exists() and json.loads(previous.read_text()).get('serial', 0) >= serial:
        raise SystemExit(f'{previous} already offers serial {serial} or later; stamp a new serial first')
    files = {name: describe(source / name) for name in FILES}
    if sum(f['size'] for f in files.values()) > TOTAL_LIMIT:
        raise SystemExit('the filter set is larger than 64 MB')
    manifest = {'format': 'lite-filters', 'version': 1, 'serial': serial,
                'created': datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
                'files': files,
                'sources': {name: describe(source / name) for name in SOURCES if (source / name).exists()}}
    body = (json.dumps(manifest, sort_keys=True, separators=(',', ':')) + '\n').encode()
    directory = out / str(serial)
    directory.mkdir(parents=True, exist_ok=True)
    for name in FILES + list(manifest['sources']):
        (directory / name).write_bytes((source / name).read_bytes())
    with tempfile.TemporaryDirectory() as temporary:
        unsigned = pathlib.Path(temporary) / 'filters.json'
        unsigned.write_bytes(body)
        signature = openssl('dgst', '-sha256', '-sign', str(key), str(unsigned))
        der = pathlib.Path(temporary) / 'public.der'
        der.write_bytes(base64.b64decode(public_key(key)))
        sig = pathlib.Path(temporary) / 'filters.sig'
        sig.write_bytes(signature)
        openssl('dgst', '-sha256', '-verify', str(der), '-keyform', 'DER', '-signature', str(sig), str(unsigned))
    (out / 'filters.json.sig').write_text(base64.b64encode(signature).decode() + '\n')
    previous.write_bytes(body)
    print(f'Published serial {serial} to {out}. Public key: {public_key(key)}')


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest='command', required=True)
    commands.add_parser('key').add_argument('path')
    serial = commands.add_parser('serial')
    serial.add_argument('--source', type=pathlib.Path, default=SOURCE)
    release = commands.add_parser('publish')
    release.add_argument('out')
    release.add_argument('--key', required=True)
    release.add_argument('--source', type=pathlib.Path, default=SOURCE)
    args = parser.parse_args()
    if args.command == 'key':
        create_key(args.path)
    elif args.command == 'serial':
        stamp(args.source)
    else:
        publish(args.out, args.key, args.source)


if __name__ == '__main__':
    try:
        main()
    except subprocess.CalledProcessError as error:
        sys.exit('openssl failed: ' + error.stderr.decode(errors='replace').strip())
