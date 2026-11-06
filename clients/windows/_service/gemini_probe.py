"""Read-only Google route check. Cookies live only in this probe's memory.

Gemini and Google's verification share one authenticated TLS/HTTP2 connection.
This checks transport and the app page, never account access or a model reply.
"""
import argparse
from email.message import Message
import hashlib
import http.cookiejar
import ipaddress
import json
from pathlib import Path
import re
import socket
import ssl
import struct
import sys
import time
from urllib.parse import urljoin, urlsplit
from urllib.request import Request
import zlib

ROOT = Path(__file__).resolve().parent
for name, digest in json.loads((ROOT / 'vendor/hashes.json').read_text()).items():
    if not re.fullmatch(r'[a-z0-9_.-]+\.whl', name):
        raise ValueError('Invalid HTTP2 dependency name')
    wheel = ROOT / 'vendor' / name
    if hashlib.sha256(wheel.read_bytes()).hexdigest() != digest:
        raise ValueError('HTTP2 dependency hash mismatch')
    sys.path.insert(0, str(wheel))
import h2.config
import h2.connection
import h2.events
import h2.settings

HOSTS = {'gemini.google.com', 'www.google.com'}
LIMIT = 2_000_000


def www_certificate_valid(cert):
    # Fixed destinations only; no generalized wildcard matching or CN fallback.
    return any(kind == 'DNS' and name.lower() in ('www.google.com', '*.google.com')
               for kind, name in cert.get('subjectAltName', ()))


class Session:
    def __init__(self, tls, deadline):
        self.tls, self.deadline = tls, deadline
        self.jar = http.cookiejar.CookieJar()
        self.conn = h2.connection.H2Connection(config=h2.config.H2Configuration(header_encoding='utf-8'))
        self.conn.initiate_connection()
        self.conn.update_settings({h2.settings.SettingCodes.INITIAL_WINDOW_SIZE: 1_048_576})
        self.conn.increment_flow_control_window(1_048_576)
        self.tls.sendall(self.conn.data_to_send())

    def get(self, url):
        target = urlsplit(url)
        if target.scheme != 'https' or target.hostname not in HOSTS or target.port not in (None, 443) or target.username or target.password:
            raise ValueError('Google redirect outside the allowed route')
        remaining = self.deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError('Google route deadline')
        self.tls.settimeout(remaining)
        request = Request(url)
        self.jar.add_cookie_header(request)
        path = target.path or '/'
        if target.query:
            path += '?' + target.query
        headers = [(':method', 'GET'), (':scheme', 'https'), (':authority', target.hostname),
                   (':path', path), ('user-agent', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/142.0.0.0 Safari/537.36'),
                   ('accept-encoding', 'gzip')]
        cookie = request.get_header('Cookie')
        if cookie:
            headers.append(('cookie', cookie))
        stream = self.conn.get_next_available_stream_id()
        self.conn.send_headers(stream, headers, end_stream=True)
        self.tls.sendall(self.conn.data_to_send())
        response, body, complete = {}, bytearray(), False
        while not complete:
            remaining = self.deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError('Google route deadline')
            self.tls.settimeout(remaining)
            data = self.tls.recv(65536)
            if not data:
                raise EOFError('Google closed HTTP2')
            for event in self.conn.receive_data(data):
                if isinstance(event, h2.events.ResponseReceived) and event.stream_id == stream:
                    response = dict(event.headers)
                    message = Message()
                    for name, value in event.headers:
                        if not name.startswith(':'):
                            message[name] = value
                    class CookieResponse:
                        def info(self):
                            return message
                    self.jar.extract_cookies(CookieResponse(), request)
                elif isinstance(event, h2.events.DataReceived):
                    self.conn.acknowledge_received_data(event.flow_controlled_length, event.stream_id)
                    if event.stream_id == stream:
                        body += event.data
                        if len(body) > LIMIT:
                            raise ValueError('Google response exceeds limit')
                elif isinstance(event, h2.events.StreamEnded) and event.stream_id == stream:
                    complete = True
                elif isinstance(event, h2.events.StreamReset) and event.stream_id == stream:
                    raise OSError('Google reset HTTP2 stream')
            pending = self.conn.data_to_send()
            if pending:
                self.tls.sendall(pending)
        if response.get('content-encoding') == 'gzip':
            decoder = zlib.decompressobj(16 + zlib.MAX_WBITS)
            body = decoder.decompress(body, LIMIT + 1)
            if len(body) > LIMIT or not decoder.eof:
                raise ValueError('Invalid or oversized compressed Google response')
        return response, bytes(body)


def check_session(session):
    url = 'https://gemini.google.com/app'
    verified = False
    challenge = False
    for _ in range(8):
        host = urlsplit(url).hostname
        headers, body = session.get(url)
        status = int(headers.get(':status', '0'))
        if host == 'www.google.com':
            challenge = True
            verified = status in (200, 204, 301, 302, 303, 307, 308, 400, 429)
        if status in (301, 302, 303, 307, 308):
            url = urljoin(url, headers.get('location', ''))
            if urlsplit(url).hostname == 'accounts.google.com':
                return dict(ready=False, http=status, verification=verified, error='Google sign-in: app page not verified')
            continue
        text = body.decode('utf-8', errors='replace')
        marker = re.search(r',2,1,200,\\?"([A-Z]{3})', text)
        country = marker.group(1) if marker else ''
        blocked = country in ('RUS', 'CHN', 'IRN', 'PRK', 'SYR', 'CUB') or bool(re.search(r'not (?:available|supported) in your country', text, re.I))
        if host == 'gemini.google.com' and status == 200 and not blocked:
            if not verified:
                h, _ = session.get('https://www.google.com/generate_204')
                verified = int(h.get(':status', '0')) in (200, 204)
            return dict(ready=verified, http=status, verification=verified, country=country,
                        challengeResolved=challenge, error='' if verified else 'Google www route not verified')
        return dict(ready=False, http=status, verification=verified, country=country,
                    error='Google regional restriction' if blocked else 'Google app page unavailable')
    return dict(ready=False, verification=verified, error='Google redirect limit')


def probe(address, interface_index, local_address, timeout=15):
    started = time.monotonic()
    result = dict(ready=False, tls=False, verification=False, http=None, country='', ms=0, error='')
    raw = tls = None
    try:
        ip = ipaddress.ip_address(address)
        source = ipaddress.ip_address(local_address)
        if ip.version != 4 or not ip.is_global or source.version != 4 or source.is_unspecified or not 0 < interface_index < 2**31:
            raise ValueError('Invalid physical route')
        deadline = started + timeout
        raw = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        raw.setsockopt(socket.IPPROTO_IP, 31, struct.pack('!I', interface_index))
        raw.bind((local_address, 0))
        raw.settimeout(min(3, timeout))
        raw.connect((address, 443))
        context = ssl.create_default_context()
        context.set_alpn_protocols(['h2'])
        raw.settimeout(max(.1, deadline - time.monotonic()))
        tls = context.wrap_socket(raw, server_hostname='gemini.google.com')
        result['tls'] = True
        if tls.selected_alpn_protocol() != 'h2' or not www_certificate_valid(tls.getpeercert()):
            raise ValueError('HTTP2 or Google www certificate unavailable')
        result.update(check_session(Session(tls, deadline)))
    except Exception as exc:
        # Never log URLs, query tokens or cookie values.
        result['error'] = type(exc).__name__
    finally:
        if tls:
            tls.close()
        elif raw:
            raw.close()
        result['ms'] = round((time.monotonic() - started) * 1000)
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--address', required=True)
    parser.add_argument('--interface-index', type=int, required=True)
    parser.add_argument('--local-address', required=True)
    args = parser.parse_args()
    print(json.dumps(probe(args.address, args.interface_index, args.local_address)))
