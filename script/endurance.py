#!/usr/bin/env python3
"""Bounded, resumable fixture endurance. Each cycle starts disposable app profiles.

The engine suite creates/closes many browsers within each process. This runner
also repeats launches and actual native windows; it is not a multi-hour public-
site session or a battery test. A phase is complete only after its subprocess exits.
"""
import argparse
import hashlib
import json
import os
import pathlib
import signal
import subprocess
import sys
import time
import uuid

from test_processes import stop_app

ROOT = pathlib.Path(__file__).resolve().parents[1]
APP = ROOT/'dist/Lite.app'


def run_phase(command, output, profile, timeout):
    environment = os.environ.copy()
    environment['LITE_TEST_PROFILE'] = str(profile)
    for selector in ('LITE_BLOCKING_ONLY', 'LITE_READINESS_ONLY', 'LITE_START_URL'):
        environment.pop(selector, None)
    process = subprocess.Popen(command, cwd=ROOT, stdout=output, stderr=subprocess.STDOUT,
                               env=environment, start_new_session=True)
    status = 124
    cleanup = None
    try:
        status = process.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        pass
    finally:
        if process.poll() is None:
            try:
                os.killpg(process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                process.wait(timeout=20)
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                process.wait()
        cleanup = stop_app(APP, profile)
    if cleanup['processIDs'] and status == 0:
        status = 1
    return status, cleanup


def save(path, value):
    temporary = path.with_suffix('.tmp')
    with temporary.open('w') as target:
        json.dump(value, target, indent=2)
        target.write('\n')
        target.flush()
        os.fsync(target.fileno())
    temporary.replace(path)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--cycles', type=int, default=3)
    parser.add_argument('--record', type=pathlib.Path, default=ROOT/'test-results/endurance/run.json')
    args = parser.parse_args()
    if not 1 <= args.cycles <= 100:
        parser.error('--cycles must be 1..100')
    fingerprint = hashlib.sha256((APP/'Contents/MacOS/Lite').read_bytes()).hexdigest()
    runner_hash = hashlib.sha256()
    for name in ('endurance.py', 'test_processes.py', 'test_browser.py', 'test_native.py',
                 'measure_native.py', 'test_server.py', 'resource_sample.c'):
        runner_hash.update(name.encode() + b'\0' + (ROOT/'script'/name).read_bytes())
    runner_fingerprint = runner_hash.hexdigest()
    args.record.parent.mkdir(parents=True, exist_ok=True)
    record = json.loads(args.record.read_text()) if args.record.exists() else dict(
        appSHA256=fingerprint, runnerSHA256=runner_fingerprint, cycles=args.cycles, phases=[], scope='fresh synthetic profile per phase; engine/native/stable native metrics')
    if record['appSHA256'] != fingerprint or record.get('runnerSHA256') != runner_fingerprint or record['cycles'] != args.cycles:
        parser.error('The existing record belongs to a different app, verification scripts or cycle count; choose a new record path')
    phases = [('engine', [sys.executable, 'script/test_browser.py'], 330),
              ('native', [sys.executable, 'script/test_native.py'], 180),
              ('metrics', [sys.executable, 'script/measure_native.py', '--duration', '15'], 120)]
    for cycle in range(args.cycles):
        for name, command, timeout in phases:
            key = f'{cycle+1}-{name}'
            if any(item['key'] == key and item['returncode'] == 0 for item in record['phases']):
                continue
            started = time.monotonic()
            log = args.record.parent/(key+'.log')
            profile = ROOT/'.build'/('endurance-' + uuid.uuid4().hex + '-' + name)
            report_path = ROOT/'test-results'/(name+'.json')
            if name == 'metrics':
                report_path = args.record.parent/(key+'.json')
                command = command + ['--output', str(report_path)]
            print('Running', key, flush=True)
            with log.open('w') as output:
                status, cleanup = run_phase(command, output, profile, timeout)
            item = dict(key=key, returncode=status, elapsedSeconds=time.monotonic()-started,
                        log=str(log), profile=str(profile), cleanup=cleanup)
            if report_path.exists():
                report = json.loads(report_path.read_text())
                if report.get('profile') == str(profile):
                    item['result'] = report
            if status == 0 and ('result' not in item or (name == 'metrics' and item['result'].get('gracefulExit') is not True)):
                status = item['returncode'] = 1
                item['error'] = 'The phase did not produce a successful report for its exact synthetic profile'
            record['phases'].append(item)
            record['completed'] = False
            record['measuredExecutionSeconds'] = sum(p['elapsedSeconds'] for p in record['phases'])
            save(args.record, record)
            if status:
                print('Failed; resume after resolving:', key, log, flush=True)
                return status
    record['completed'] = True
    save(args.record, record)
    print('Completed', args.cycles, 'cycles in', round(record['measuredExecutionSeconds'], 1), 'measured execution seconds')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
