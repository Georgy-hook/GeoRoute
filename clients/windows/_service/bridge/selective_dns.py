"""Selected namespaces -> one selected DoH provider; global DNS stays unchanged."""
import argparse
import concurrent.futures
import ipaddress
import json
import os
from pathlib import Path
import re
import socket
import ssl
import struct
import sys
import threading
import time
from urllib.parse import urlsplit
from urllib.request import urlopen

# -I excludes the script directory, including when hosted directly by SCM.
sys.path.insert(0, str(Path(__file__).resolve().parent))
import bridge

CATALOGUE_URL = 'https://raw.githubusercontent.com/Internet-Helper/GeoHideDNS/main/lists/domains.txt'


def domain(text):
    text = text.strip()
    if '://' in text:
        value = urlsplit(text)
        if value.scheme not in ('https', 'http') or value.username or value.password:
            raise ValueError('Введите адрес сайта без логина и пароля')
        text = value.hostname or ''
    text = text.rstrip('.').encode('idna').decode('ascii').lower()
    if len(text) > 253 or '.' not in text or any(not re.fullmatch(r'[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?', part) for part in text.split('.')):
        raise ValueError('Нужен домен сайта, например claude.ai; маски и порты не подходят')
    try:
        ipaddress.ip_address(text)
    except ValueError:
        return text
    raise ValueError('Введите домен сайта, а не IP')


def endpoint(text):
    value = urlsplit(text.strip())
    if value.scheme != 'https' or not value.hostname or value.username or value.password or value.fragment or value.query or value.port not in (None, 443):
        raise ValueError('Нужен HTTPS DoH адрес без логина, query и нестандартного порта')
    host = domain(value.hostname)
    path = value.path or '/dns-query'
    if len(path) > 512 or not path.startswith('/') or any(ord(c) <= 32 or ord(c) >= 127 for c in path):
        raise ValueError('Некорректный путь DoH')
    return host, path


def address(text):
    ip = ipaddress.ip_address(text)
    if not ip.is_global or ip.is_multicast:
        raise ValueError('Bootstrap DNS должен быть публичным IP')
    return str(ip)


def config(raw, bootstrap=False):
    host, path = endpoint(raw['url'])
    domains = sorted({domain(x) for x in raw['domains']})
    if not 1 <= len(domains) <= 100:
        raise ValueError('Выберите от 1 до 100 сайтов')
    suffixes = raw.get('subdomains', True)
    if not isinstance(suffixes, bool):
        raise ValueError('Некорректный режим поддоменов')
    if any(host == d or (suffixes and host.endswith('.' + d)) for d in domains):
        raise ValueError('DNS-сервер не должен входить в список направляемых сайтов')
    servers = list(dict.fromkeys(address(x) for x in raw.get('servers', [])))
    if bootstrap:
        try:
            found = [address(x[4][0]) for x in socket.getaddrinfo(host, 443, type=socket.SOCK_STREAM)]
            servers = list(dict.fromkeys(found + servers))
        except (OSError, ValueError):
            if not servers:
                raise ValueError('Не найден публичный адрес DoH; укажите bootstrap IP') from None
    if not 1 <= len(servers) <= 16:
        raise ValueError('Укажите публичные bootstrap IP или проверьте обычный DNS')
    return dict(version=1, url='https://' + host + path, domains=domains, subdomains=suffixes, servers=servers)


def question(packet, response=False):
    if len(packet) < 17 or packet[2] & 0x78 or bool(packet[2] & 0x80) != response or packet[4:6] != b'\0\1':
        raise ValueError('Unsupported DNS question')
    offset, parts = 12, []
    while True:
        if offset >= len(packet):
            raise ValueError('Truncated DNS name')
        size = packet[offset]; offset += 1
        if size == 0:
            break
        if size > 63 or offset + size > len(packet) or offset + size > 266:
            raise ValueError('Invalid DNS label')
        parts.append(packet[offset:offset+size].decode('ascii').lower()); offset += size
    if offset + 4 > len(packet) or packet[offset+2:offset+4] != b'\0\1':
        raise ValueError('Unsupported DNS class')
    return '.'.join(parts), offset + 4


def query(name, kind=1):
    return struct.pack('!6H', 0x4352, 0x100, 1, 0, 0, 0) + b''.join(bytes([len(p)]) + p.encode('ascii') for p in name.split('.')) + b'\0' + struct.pack('!HH', kind, 1)


def matches(name, settings):
    return any(name == d or (settings['subdomains'] and name.endswith('.' + d)) for d in settings['domains'])


class Provider(bridge.DoH):
    def __init__(self, settings, refresh=False):
        super().__init__('000000')
        self.host, self.path = endpoint(settings['url'])
        self.servers = tuple(settings['servers'])
        self.context = ssl.create_default_context()
        self.context.minimum_version = ssl.TLSVersion.TLSv1_2
        self.context.set_alpn_protocols(['http/1.1'])
        self.fragment_hello, self.request_timeout = False, 3
        self.refresh_stop = threading.Event()
        if refresh:
            threading.Thread(target=self.refresh, daemon=True).start()

    def refresh(self):
        # The provider's own name is excluded from routed namespaces. Resolve it
        # through the unchanged Windows DNS; never adopt a different provider.
        while not self.refresh_stop.is_set():
            try:
                found = list(dict.fromkeys(address(x[4][0]) for x in socket.getaddrinfo(self.host, 443, type=socket.SOCK_STREAM)))
                with self.lock:
                    current = self.servers[self.preferred]
                    servers = tuple(dict.fromkeys([current] + found + list(self.servers)))[:4]
                    if not self.closed:
                        self.servers, self.preferred = servers, 0
            except (OSError, ValueError):
                pass  # Retain known bootstrap addresses during upstream-DNS outages.
            if self.refresh_stop.wait(300):
                break

    def close(self):
        self.refresh_stop.set()
        super().close()

    def query(self, packet):
        name, end = question(packet)
        reply = super().query(packet)
        response_name, response_end = question(reply, response=True)
        if response_name != name or reply[response_end-4:response_end] != packet[end-4:end]:
            raise ValueError('DNS question mismatch')
        return reply


class SelectedBridge(bridge.Bridge):
    def __init__(self, settings, port, root, *, refresh=True):
        self.settings = config(settings)
        super().__init__('000000', port, root, doh=Provider(self.settings, refresh=refresh), bindings=((socket.AF_INET, '127.0.0.2'),))
        self.stats.update(provider=self.settings['url'], domainCount=len(self.settings['domains']), selectedOnly=True)

    def boot_probe(self):
        # This is a separate selected-only service, not a NextDNS route check.
        return

    def resolve(self, packet):
        try:
            name, _ = question(packet)
            if not matches(name, self.settings):
                reply = bytearray(bridge.failure(packet)); reply[3] = (reply[3] & 0xF0) | 5
                return bytes(reply)
        except (ValueError, UnicodeError):
            return bridge.failure(packet)
        return super().resolve(packet)


def probe(settings):
    settings = config(settings, bootstrap=True)
    packet = query(settings['domains'][0])

    def test(server):
        provider = Provider(dict(settings, servers=[server]))
        start = time.monotonic()
        try:
            result = provider.query(packet)
            if result[3] & 15 not in (0, 3):
                raise ValueError('DNS returned an error')
            return dict(server=server, ok=True, ms=round((time.monotonic()-start)*1000), rcode=result[3] & 15)
        except (OSError, ValueError, EOFError) as exc:
            return dict(server=server, ok=False, error=type(exc).__name__ + ': ' + str(exc)[:160])
        finally:
            provider.close()

    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
        rows = list(pool.map(test, settings['servers']))
    good = sorted((r for r in rows if r['ok']), key=lambda r: r['ms'])
    if not good:
        return dict(status='error', settings=settings, rows=rows,
                    error='Выбранный DoH не ответил с проверкой сертификата; системный DNS не изменён')
    settings['servers'] = [r['server'] for r in good[:2]]
    return dict(status='ok', settings=settings, rows=rows, message='DoH отвечает. Это проверка DNS, а не открытия сайта; NXDOMAIN не подтверждает поддержку сайта.')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--mode', choices=['validate', 'probe', 'serve', 'catalogue'], required=True)
    parser.add_argument('--config')
    parser.add_argument('--output')
    parser.add_argument('--data-dir')
    parser.add_argument('--port', type=int, default=53)
    parser.add_argument('--service', action='store_true')
    parser.add_argument('--service-name', default='GeoRouteDNS')
    args = parser.parse_args()
    if not 1 <= args.port <= 65535 or not re.fullmatch(r'[A-Za-z0-9_.-]{1,64}', args.service_name):
        parser.error('Invalid listener port or service name')
    try:
        if args.mode == 'catalogue':
            with urlopen(CATALOGUE_URL, timeout=12) as response:
                data = response.read(1048577)
            if len(data) > 1048576:
                raise ValueError('Provider list too large')
            names = sorted({domain(x) for x in data.decode('utf-8-sig').splitlines() if x.strip() and not x.startswith('#')})
            if not 10 <= len(names) <= 10000:
                raise ValueError('Provider list is incomplete')
            result = dict(status='ok', domains=names, at=bridge.Bridge.now())
        elif args.mode in ('validate', 'probe'):
            raw = json.loads(Path(args.config).read_text(encoding='utf-8-sig'))
            result = probe(raw) if args.mode == 'probe' else dict(status='ok', settings=config(raw))
        else:
            def factory():
                return SelectedBridge(json.loads(Path(args.config).read_text(encoding='utf-8-sig')), args.port, args.data_dir)
            if args.service:
                def log(message):
                    path = Path(args.data_dir) / 'service.log'
                    if path.exists() and path.stat().st_size > 262144:
                        path.write_text('', encoding='utf-8')
                    with path.open('a', encoding='utf-8') as stream:
                        stream.write(bridge.Bridge.now() + ' ' + message + '\n')
                sys.stdin = open(os.devnull, 'r')
                sys.stdout = open(os.devnull, 'w')
                sys.stderr = open(os.devnull, 'w')
                return bridge.run_service(args.service_name, factory, log)
            worker = factory()

            def stop():
                for line in sys.stdin:
                    if line.strip() == 'STOP':
                        worker.stop.set(); return
            threading.Thread(target=stop, daemon=True).start()
            worker.start(); return 0
    except Exception as exc:
        result = dict(status='error', error=str(exc)[:300])
    if args.output:
        Path(args.output).write_text(json.dumps(result, ensure_ascii=False), encoding='utf-8')
    else:
        print(json.dumps(result, ensure_ascii=True))
    return 0 if result['status'] == 'ok' else 1


if __name__ == '__main__':
    sys.exit(main())
