#!/usr/bin/env python3
"""Loopback-only, deterministic browser verification pages. No external services."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json, struct, zlib
from urllib.parse import urlsplit, parse_qs

blocking_hits = {}

def png():
    def chunk(kind, data):
        return struct.pack('!I', len(data)) + kind + data + struct.pack('!I', zlib.crc32(kind + data))
    # Small green icon, constructed locally without external assets or imaging dependencies.
    pixels = b''.join(b'\0' + bytes((32, 160, 92, 255)) * 32 for _ in range(32))
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('!2I5B', 32, 32, 8, 6, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(pixels)) + chunk(b'IEND', b'')

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        parsed = urlsplit(self.path)
        phase = parse_qs(parsed.query).get('phase', ['enabled'])[0]
        if parsed.path == '/content-blocking':
            body = '''<!doctype html><meta charset="utf-8"><title>Lite content blocking test</title>
<h1>Content blocking verification</h1><p id="normal-content">Normal content remains visible.</p>
<div id="AC_ad">Advertising fixture</div>
<script nonce="lite-test">addEventListener('load',async()=>{
 const phase=new URL(location.href).searchParams.get('phase')||'enabled';
 const get=async path=>{try{return (await fetch(path,{cache:'no-store'})).ok}catch{return false}};
 const blocked=await get('/webtracking.min.js?phase='+phase);
 const redirected=await get('/blocking-redirect?phase='+phase);
 const allowed=await get('/echo');
 await navigator.serviceWorker.register('/blocking-worker.js');
 const registration=await navigator.serviceWorker.ready;
 const workerBlocked=await new Promise(resolve=>{const channel=new MessageChannel();
  const timer=setTimeout(()=>resolve(null),3000);
  channel.port1.onmessage=e=>{clearTimeout(timer);resolve(e.data)};
  registration.active.postMessage(phase,[channel.port2]);});
 const late=document.createElement('div');late.id='AD_160';late.textContent='Dynamically inserted advertising';document.body.append(late);
 const hits=await(await fetch('/blocking-hits?phase='+phase)).json();
 window.blockingResult={blocked:!blocked,redirectBlocked:!redirected,workerBlocked,allowed,hits,
  cosmetic:getComputedStyle(document.querySelector('#AC_ad')).display==='none',
  dynamicCosmetic:getComputedStyle(late).display==='none',
  normalVisible:getComputedStyle(document.querySelector('#normal-content')).display!=='none'};
});</script>'''.encode()
            content = 'text/html'
        elif parsed.path == '/blocking-worker.js':
            body = b'''self.addEventListener('install',()=>self.skipWaiting());
self.addEventListener('activate',e=>e.waitUntil(self.clients.claim()));
self.addEventListener('message',e=>e.waitUntil((async()=>{
 let blocked=false;try{await fetch('/webtracking.min.js?phase='+e.data,{cache:'no-store'})}catch{blocked=true}
 e.ports[0].postMessage(blocked);
})()));'''
            content = 'application/javascript'
        elif parsed.path == '/blocking-redirect':
            self.send_response(302)
            self.send_header('Location', '/webtracking.min.js?phase='+phase)
            self.send_header('Cache-Control', 'no-store')
            self.send_header('Content-Length', '0')
            self.end_headers()
            return
        elif parsed.path == '/webtracking.min.js':
            blocking_hits[phase] = blocking_hits.get(phase, 0) + 1
            body, content = b'/* tracker fixture, no tracking */', 'application/javascript'
        elif parsed.path == '/blocking-hits':
            body, content = json.dumps(blocking_hits.get(phase, 0)).encode(), 'application/json'
        elif self.path == '/echo':
            body, content = b'lite-ok', 'text/plain'
        elif self.path == '/second':
            body, content = b'<title>Second Page</title><h1>Second page</h1><a href="/">Back to first</a>', 'text/html'
        elif self.path == '/favicon.ico':
            # Exercise HTML discovery rather than only the conventional icon path.
            self.send_error(404)
            return
        elif self.path == '/icon.png':
            body, content = png(), 'image/png'
        elif self.path == '/oversized-icon':
            body, content = b'x' * (600 * 1024), 'image/png'
        elif self.path == '/icon-page':
            head = b'<title>Unopened bookmark</title><link rel="icon" href="/icon.png">'
            # The 128 KiB fetch limit splits a UTF-8 character after its first byte.
            body = head + b' ' * (128 * 1024 - len(head) - 1) + '\u4e2d'.encode() + b' ' * (32 * 1024)
            content = 'text/html'
        elif self.path == '/login':
            body = b'''<!doctype html><title>Lite login test</title><link rel="icon" href="/icon.png"><style>body{font:18px system-ui;padding:48px}input,button{font:inherit;margin:12px;padding:10px}</style><h1>Local login test</h1><form action="/login" onsubmit="event.preventDefault();document.querySelector('#status').textContent='Submitted';"><label>Username<input name="username" autocomplete="username"></label><br><label>Password<input name="password" type="password" autocomplete="current-password"></label><br><button>Sign in</button></form><p id="status">Not submitted</p>'''
            content = 'text/html'
        elif self.path == '/media':
            body = b'''<!doctype html><title>Lite media test</title><style>body{font:20px system-ui;padding:40px;background:#f4f6f3}</style><h1>Picture in Picture test</h1><p>Generated locally from a canvas. No camera or microphone.</p><video controls muted autoplay playsinline width="600"></video><script>const c=document.createElement('canvas');c.width=640;c.height=360;const x=c.getContext('2d');setInterval(()=>{x.fillStyle='#284b43';x.fillRect(0,0,640,360);x.fillStyle='#ffffff';x.font='32px system-ui';x.fillText('Lite media test',40,150);x.fillText(new Date().toLocaleTimeString(),40,210)},100);document.querySelector('video').srcObject=c.captureStream(10);</script>'''
            content = 'text/html'
        else:
            body = b'''<!doctype html><title>Lite Test Page</title><meta charset="utf-8"><style>body{font:18px system-ui;background:#f4f6f3;color:#24372d;padding:48px}h1{font-size:36px}input,button{font:inherit;padding:10px;margin:8px}a{color:#287850}</style><h1>Lite browser test</h1><p>Chromium rendering, storage, navigation, and form protection.</p><input placeholder="Form protection"><a href="/second">Next page</a><button onclick="window.open('/second','login','width=600,height=500')">Open popup</button><a download="lite-test.txt" href="/echo">Download test file</a>'''
            content = 'text/html'
        self.send_response(200)
        if parsed.path == '/content-blocking':
            self.send_header('Content-Security-Policy', "default-src 'self'; script-src 'self' 'nonce-lite-test'; style-src 'none'")
        self.send_header('Cache-Control', 'no-store')
        self.send_header('Content-Type', content); self.send_header('Content-Length', str(len(body))); self.end_headers(); self.wfile.write(body)
    def log_message(self, *args): pass
ThreadingHTTPServer(('127.0.0.1', 18743), Handler).serve_forever()
