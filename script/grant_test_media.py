#!/usr/bin/env python3
"""Ask macOS for camera and microphone consent for the stably signed test bundle.

The person at the Mac answers the system prompts. This never edits consent records.
"""
import json
import pathlib
import subprocess
import sys
import uuid

from package import stable_requirement

ROOT = pathlib.Path(__file__).resolve().parents[1]


def main():
    app = pathlib.Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else ROOT / 'dist/LiteTest.app'
    if not stable_requirement(app):
        print('FAIL: ' + str(app) + ' is ad hoc signed, so consent would last for this build only. '
              'Set LITE_TEST_SIGNING_IDENTITY and run script/package.py --test first; see docs/build-macos.md.')
        return 1
    output = ROOT / '.build' / ('media-consent-' + uuid.uuid4().hex[:8] + '.json')
    try:
        subprocess.run(['open', '-W', '-n', str(app), '--args', '--lite-request-media-consent=' + str(output)], check=True)
        system = json.loads(output.read_text())
    finally:
        output.unlink(missing_ok=True)
    print(json.dumps(system, indent=2))
    if all(value == 'authorized' for value in system.values()):
        print('PASS: this test identity has camera and microphone consent')
        return 0
    print('FAIL: allow the test bundle under System Settings > Privacy & Security > Camera and Microphone.')
    return 1


if __name__ == '__main__':
    raise SystemExit(main())
