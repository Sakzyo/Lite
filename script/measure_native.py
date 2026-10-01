#!/usr/bin/env python3
"""Measure the real native app, synthetic fresh profile, no personal browser data.

First usable page is a DOM-ready loopback beacon after process launch. This is
fresh-process launch, not an OS cache purge. Other installed apps remain running.
"""
import argparse
import http.server
import json
import os
import pathlib
import signal
import sqlite3
import subprocess
import threading
import time
import uuid

from test_processes import app_pids, stop_app

ROOT = pathlib.Path(__file__).resolve().parents[1]


def interrupted(signum, frame):
    raise KeyboardInterrupt


def main():
    signal.signal(signal.SIGTERM, interrupted)
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=pathlib.Path, required=True)
    parser.add_argument('--nodes', type=int, default=2000)
    parser.add_argument('--duration', type=int, default=15)
    parser.add_argument('--mixed', action='store_true', help='Three separate origins: document, canvas and storage application fixtures')
    args = parser.parse_args()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    profile = pathlib.Path(os.environ.get('LITE_TEST_PROFILE', ROOT / '.build' / ('native-measure-' + uuid.uuid4().hex[:8]))).resolve()
    if profile.parent != (ROOT/'.build').resolve() or not profile.name.startswith(('native-measure-', 'endurance-')):
        parser.error('The test profile must be a fresh native-measure- or endurance- directory inside .build')
    profile.mkdir(parents=True)
    ready = threading.Event()
    events = []

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            events.append((time.monotonic(), self.path))
            if self.path == '/ready':
                if sum(path == '/ready' for _, path in events) >= (3 if args.mixed else 1): ready.set()
                data = b'ok'
            else:
                data = b'''<!doctype html><title>Lite native fixture</title><h1>Native browser fixture</h1>
                <p>Disposable data. Scroll, keyboard, split, and sidebar fixture.</p>
                <input aria-label="Synthetic note"><a href="/second">Next page</a>
                <div style="height:4000px;background:linear-gradient(white,lightblue)"></div>
                <canvas width="640" height="320"></canvas>
                <script>
                if(location.search.includes('canvas')) {const c=document.querySelector('canvas').getContext('2d');
                  let n=0;setInterval(()=>{c.fillStyle=`hsl(${n++%360} 50% 70%)`;c.fillRect(0,0,640,320)},100)}
                if(location.search.includes('storage')) {localStorage.setItem('fixture','synthetic');
                  indexedDB.open('fixture',1).onupgradeneeded=e=>e.target.result.createObjectStore('notes')}
                addEventListener('DOMContentLoaded',()=>fetch('/ready'));</script>'''
            self.send_response(200)
            self.send_header('Content-Type', 'text/html')
            self.end_headers()
            self.wfile.write(data)

        def log_message(self, *unused):
            pass

    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    servers = [server]
    if args.mixed:
        for _ in range(2):
            extra = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
            threading.Thread(target=extra.serve_forever, daemon=True).start()
            servers.append(extra)
    origin = f'http://127.0.0.1:{server.server_port}'
    nodes = [dict(id=f'tab-{n}', kind='pinned', space='space', parent='',
                  title=f'Fixture {n:05d}', customTitle='', url=origin + f'/?page={n}',
                  pinnedURL=origin + f'/?page={n}', favicon='', order=n, expanded=False,
                  lastUsed=0) for n in range(args.nodes)]
    data = dict(version=1, spaces=[dict(id='space', name='Personal', selected='tab-0')],
                nodes=nodes, activeSpace='space', settings=dict(performance='Efficient',
                search='DuckDuckGo', externalMini=True, onboarded=True),
                windows=[dict(space='space', active='tab-0', secondary='', vertical=True,
                              ratio=0.5, sidebarCollapsed=False, sidebarWidth=238)])
    if args.mixed:
        for index, workload in enumerate(['document', 'canvas', 'storage']):
            nodes[index]['url'] = f'http://127.0.0.1:{servers[index].server_port}/?{workload}'
            nodes[index]['pinnedURL'] = nodes[index]['url']
        data['windows'] = [dict(space='space', active=f'tab-{index}', secondary='', vertical=True,
                              ratio=.5, sidebarCollapsed=False, sidebarWidth=238) for index in range(3)]
    with sqlite3.connect(profile / 'Lite.sqlite') as db:
        db.execute('CREATE TABLE profile (id INTEGER PRIMARY KEY CHECK(id=1),json BLOB NOT NULL)')
        db.execute('INSERT INTO profile VALUES (1,?)', (json.dumps(data).encode(),))
        db.execute('PRAGMA user_version=1')
    sampler = ROOT / '.build/resource_sample'
    subprocess.run(['cc', str(ROOT / 'script/resource_sample.c'), '-o', str(sampler)], check=True)
    started = time.monotonic()
    subprocess.run(['open', '-n', str(ROOT / 'dist/Lite.app'), '--stdout', str(profile/'stdout.log'),
                    '--stderr', str(profile/'stderr.log'), '--args', '--lite-test-profile='+str(profile),
                    '--use-mock-keychain', '--lite-native-measure'], check=True)
    pid = None
    result = dict(workload='native-three-origin-document-canvas-storage' if args.mixed else 'native-2000-pin-single-loopback-page', nodes=args.nodes,
                  profile=str(profile), architecture=os.uname().machine,
                  os=subprocess.check_output(['sw_vers', '-productVersion'], text=True).strip())
    try:
        if not ready.wait(40):
            raise RuntimeError('Native page did not send DOM-ready beacon within 40 seconds')
        result['launchToDOMReadySeconds'] = next(t for t, p in events if p == '/ready') - started
        matches = app_pids(ROOT/'dist/Lite.app', profile)
        pid = matches[0] if matches else None
        if not pid:
            raise RuntimeError('Test process missing')
        time.sleep(6)
        before = json.loads(subprocess.check_output([str(sampler), str(pid)]))
        sample_start = time.monotonic()
        request_start = len(events)
        time.sleep(args.duration)
        after = json.loads(subprocess.check_output([str(sampler), str(pid)]))
        duration = time.monotonic() - sample_start
        result.update(before=before, after=after, sampleSeconds=duration,
                      cpuPercentOneCore=100*(after['cpuSeconds']-before['cpuSeconds'])/duration,
                      interruptWakeupsPerSecond=(after['interruptWakeups']-before['interruptWakeups'])/duration,
                      idleFixtureRequests=len(events)-request_start,
                      networkScope='fixture requests only; no system-wide traffic capture',
                      fixtureRequests=len(events))
    except Exception as error:
        result['error'] = str(error)
    finally:
        cleanup = stop_app(ROOT/'dist/Lite.app', profile)
        result['gracefulExit'] = cleanup['gracefulExit']
        if not cleanup['gracefulExit']:
            result['error'] = result.get('error', 'The test app required a forced stop instead of closing gracefully')
            result['forcedProcessIDs'] = cleanup['forcedProcessIDs']
        for fixture in servers: fixture.shutdown()
        args.output.write_text(json.dumps(result, indent=2)+'\n')
        print(json.dumps(result, indent=2))
    return 1 if 'error' in result else 0


if __name__ == '__main__':
    raise SystemExit(main())
