"""Authenticated HTTPS media actions. No request controls executable paths or argv."""
import argparse
import hmac
import ipaddress
import json
import re
import ssl
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlencode, urlsplit
from urllib.request import Request, urlopen

TORRSERVER = r'C:\WORK\ARSENAL\scripts\torrserver-lan\runtime\TorrServer-windows-amd64.exe'
DATA = r'C:\WORK\ARSENAL\scripts\torrserver-lan\runtime\data'
VLC = r'C:\Program Files\VideoLAN\VLC\vlc.exe'

class Unavailable(ValueError):
    pass

def request_json(url, payload=None):
    req = Request(url, data=None if payload is None else json.dumps(payload).encode(),
                  headers={'Content-Type': 'application/json'})
    with urlopen(req, timeout=8) as response:
        raw = response.read(2_000_001)
        if len(raw) > 2_000_000:
            raise Unavailable('upstream response too large')
        return json.loads(raw)

def identifier(value):
    if not isinstance(value, str) or not re.fullmatch(r'[a-fA-F0-9]{40}', value):
        raise ValueError('invalid torrent hash')
    return value

class Media:
    def __init__(self, config, fetch=request_json, spawn=subprocess.Popen):
        self.config, self.fetch, self.spawn = config, fetch, spawn
        self.process = None
        self.lock = threading.Lock()
        # TorrServer stays on loopback; stream URL is consumed only by local VLC.
        self.base = 'http://127.0.0.1:8090'
        self.adapter = config.get('lampa_adapter', '')
        if self.adapter and (urlsplit(self.adapter).scheme != 'https' or not urlsplit(self.adapter).hostname):
            raise ValueError('adapter must be HTTPS')

    def torrents(self):
        result = self.fetch(self.base + '/torrents', {'action': 'list'})
        if not isinstance(result, list):
            raise Unavailable('invalid TorrServer list')
        return result

    def torrent(self, value):
        result = self.fetch(self.base + '/torrents', {'action': 'get', 'hash': identifier(value)})
        if not isinstance(result, dict) or result.get('hash', '').lower() != value.lower():
            raise Unavailable('invalid TorrServer torrent')
        return result

    def newest(self):
        rows = self.torrents()
        # Field contract must be explicitly configured for the installed server version.
        field = self.config.get('authoritative_added_field')
        if not rows or not field:
            raise Unavailable('newest unavailable: authoritative addition timestamps not configured')
        values = [row.get(field) for row in rows]
        if any(type(v) not in (int, float) or v <= 0 or v != v or v == float('inf') for v in values):
            raise Unavailable('newest unavailable: missing addition timestamp')
        latest = max(values)
        candidates = [r for r, v in zip(rows, values) if v == latest]
        if len(candidates) != 1:
            raise Unavailable('newest ambiguous: select a torrent')
        return identifier(candidates[0].get('hash'))

    def files(self, value):
        torrent = self.torrent(value)
        files = torrent.get('file_stats')
        if not isinstance(files, list):
            raise Unavailable('file metadata unavailable; retry after TorrServer resolves metadata')
        return [{'id': f['id'], 'name': str(f.get('path', 'File'))} for f in files
                if type(f.get('id')) is int and f['id'] > 0]

    def play(self, value, file_id):
        value = identifier(value)
        if type(file_id) is not int or file_id not in [f['id'] for f in self.files(value)]:
            raise ValueError('select an existing file')
        url = self.base + '/stream?' + urlencode({'link': value, 'index': file_id, 'play': ''})
        self.spawn([VLC, '--', url], shell=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return {'message': 'VLC process launched; playback not confirmed'}

    def restart(self):
        with self.lock:
            if not self.config.get('restart_enabled', False):
                raise Unavailable('restart not enabled')
            if self.process is not None and self.process.poll() is None:
                self.process.terminate()
                self.process.wait(timeout=8)
                self.process = None
            # Do not kill any external process occupying 8090.
            import socket
            with socket.socket() as probe:
                if probe.connect_ex(('127.0.0.1', 8090)) == 0:
                    raise Unavailable('port occupied by unowned process; not stopped')
            if not Path(DATA, 'config.db').is_file():
                raise Unavailable('existing data/config.db required; refusing a fresh database')
            self.process = self.spawn([TORRSERVER, '--path', DATA, '--port', '8090', '--ip', '127.0.0.1'],
                                      cwd=str(Path(TORRSERVER).parent), shell=False,
                                      stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            for _ in range(30):
                if self.process.poll() is not None:
                    raise Unavailable('TorrServer exited before readiness')
                try:
                    self.torrents()
                    return {'message': 'TorrServer ready'}
                except (OSError, ValueError):
                    time.sleep(0.2)
            raise Unavailable('TorrServer readiness timeout')

    def dispatch(self, body):
        action = body.get('action')
        if action == 'capabilities':
            return {'lampa': bool(self.adapter), 'resume': bool(self.adapter),
                    'restart': bool(self.config.get('restart_enabled')), 'vlc': Path(VLC).is_file(),
                    'newest': bool(self.config.get('authoritative_added_field'))}
        if action == 'torrents':
            return {'torrents': [{'id': identifier(r.get('hash')), 'name': str(r.get('title', 'Torrent'))}
                                 for r in self.torrents()]}
        if action == 'newest':
            return {'id': self.newest()}
        if action == 'files':
            return {'files': self.files(identifier(body.get('id')))}
        if action == 'play':
            return self.play(body.get('id'), body.get('file'))
        if action == 'web':
            # iPad opens the configured explicit LAN UI address, not loopback.
            url = self.config.get('web_url', '')
            if urlsplit(url).scheme != 'https' or not urlsplit(url).hostname:
                raise Unavailable('trusted HTTPS TorrServer web URL not configured')
            return {'url': url}
        if action == 'restart':
            return self.restart()
        if action in ('card', 'resume'):
            if not self.adapter:
                raise Unavailable('verified Lampa adapter / history unavailable')
            query = {'action': action}
            if action == 'card':
                value = body.get('tmdb', '')
                if not isinstance(value, str) or not re.fullmatch(r'[0-9]{1,12}', value) or int(value) == 0:
                    raise ValueError('invalid TMDB ID')
                if body.get('kind') not in ('movie', 'tv'):
                    raise ValueError('invalid media kind')
                query.update(tmdb=value, kind=body['kind'])
            result = self.fetch(self.adapter + ('&' if '?' in self.adapter else '?') + urlencode(query))
            url = result.get('url', '') if isinstance(result, dict) else ''
            parts = urlsplit(url)
            if parts.scheme not in ('https', 'lampa') or not parts.netloc or any(ord(c) < 32 for c in url):
                raise Unavailable('adapter has no verified link/history')
            return {'url': url}
        raise ValueError('unknown action')

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass  # Never log private titles, URLs or credentials.

    def setup(self):
        super().setup()
        self.connection.settimeout(15)

    def do_POST(self):
        status, result = 200, {}
        if not hmac.compare_digest(self.headers.get('Authorization', '').encode(), ('Bearer ' + self.server.token).encode()):
            status, result = 401, {'error': 'unauthorized'}
        elif self.path != '/actions':
            status, result = 404, {'error': 'unknown endpoint'}
        else:
            try:
                size = int(self.headers.get('Content-Length', '0'))
                if not 0 < size <= 4096:
                    raise ValueError('invalid request size')
                body = json.loads(self.rfile.read(size))
                if not isinstance(body, dict):
                    raise ValueError('object required')
                result = self.server.media.dispatch(body)
            except Unavailable as exc:
                status, result = 409, {'error': str(exc)}
            except (ValueError, TypeError, KeyError):
                status, result = 400, {'error': 'invalid request'}
            except Exception:
                status, result = 502, {'error': 'media operation failed; check local configuration'}
        raw = json.dumps(result).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)
        self.close_connection = True

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--config', required=True)
    args = parser.parse_args()
    config = json.loads(Path(args.config).read_text())
    ip = ipaddress.IPv4Address(config['bind'])
    allowed = ip.is_loopback or any(ip in ipaddress.ip_network(n) for n in
              ('10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16', '169.254.0.0/16'))
    if not allowed or ip.is_unspecified or str(ip).endswith(('.0', '.255')):
        raise ValueError('concrete private IPv4 required')
    if len(config['token']) < 32 or not config['token'].isascii() or config['token'].startswith('REPLACE_'):
        raise ValueError('random ASCII token of at least 32 characters required')
    server = ThreadingHTTPServer((str(ip), config.get('port', 9443)), Handler)
    server.token, server.media = config['token'], Media(config)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    context.load_cert_chain(config['certificate'], config['private_key'])
    server.socket = context.wrap_socket(server.socket, server_side=True)
    server.serve_forever()

if __name__ == '__main__':
    main()
