"""Local-only DNS -> authenticated NextDNS DoH; no hosts rewriting or DNS cache."""
import argparse
import concurrent.futures
import ctypes
import datetime as dt
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

SERVERS = ('45.90.28.0', '45.90.30.0')
HOST = 'dns.nextdns.io'


def run_service(name, factory, log):
    """Host the DNS worker directly in SCM; no executable wrapper or child process."""
    from ctypes import wintypes as w
    api = ctypes.WinDLL('advapi32', use_last_error=True)
    service_main_type = ctypes.WINFUNCTYPE(None, w.DWORD, ctypes.POINTER(w.LPWSTR))
    handler_type = ctypes.WINFUNCTYPE(None, w.DWORD)

    class Status(ctypes.Structure):
        _fields_ = [(field, w.DWORD) for field in (
            'service_type', 'state', 'controls', 'win32_exit', 'service_exit', 'checkpoint', 'wait_hint')]

    class Entry(ctypes.Structure):
        _fields_ = [('name', w.LPWSTR), ('main', service_main_type)]

    api.RegisterServiceCtrlHandlerW.argtypes = [w.LPCWSTR, handler_type]
    api.RegisterServiceCtrlHandlerW.restype = w.HANDLE
    api.SetServiceStatus.argtypes = [w.HANDLE, ctypes.POINTER(Status)]
    api.SetServiceStatus.restype = w.BOOL
    api.StartServiceCtrlDispatcherW.argtypes = [ctypes.POINTER(Entry)]
    api.StartServiceCtrlDispatcherW.restype = w.BOOL
    status = Status(service_type=0x10)
    status_lock = threading.Lock()
    stopping = threading.Event()
    handle = None
    worker = None
    exit_code = 0

    def report(state, error=0):
        with status_lock:
            status.state = state
            status.controls = 5 if state == 4 else 0  # STOP | SHUTDOWN only while running
            status.win32_exit = error
            status.checkpoint = status.checkpoint + 1 if state in (2, 3) else 0
            status.wait_hint = 15000 if state in (2, 3) else 0
            if not api.SetServiceStatus(handle, ctypes.byref(status)):
                raise ctypes.WinError(ctypes.get_last_error())

    @handler_type
    def control(code):
        if code not in (1, 5):  # SERVICE_CONTROL_STOP / SHUTDOWN
            return
        try:
            stopping.set()
            report(3)
            if worker is not None:
                worker.stop.set()
        except Exception as exc:
            log('Service control failed: ' + str(exc))

    @service_main_type
    def service_main(argc, argv):
        nonlocal handle, worker, exit_code
        handle = api.RegisterServiceCtrlHandlerW(name, control)
        if not handle:
            exit_code = ctypes.get_last_error()
            log('Cannot register service handler: ' + str(exit_code))
            return
        try:
            report(2)
            worker = factory()
            if stopping.is_set():
                worker.stop.set()

            def ready():
                if not stopping.is_set():
                    report(4)
                    log('Service started; DNS worker ready')

            worker.start(on_ready=ready)
            if not stopping.is_set():
                raise RuntimeError('DNS worker stopped unexpectedly')
        except Exception as exc:
            exit_code = 1067  # ERROR_PROCESS_ABORTED; SCM recovery is configured by installer
            log('DNS worker failed: ' + type(exc).__name__ + ': ' + str(exc))
        finally:
            if worker is not None:
                worker.close()
            log('Service stopped')
            report(1, exit_code)

    table = (Entry * 2)(Entry(name, service_main), Entry(None, service_main_type()))
    if not api.StartServiceCtrlDispatcherW(table):
        raise ctypes.WinError(ctypes.get_last_error())
    return exit_code


class DoH:
    def __init__(self, profile):
        if not re.fullmatch(r'[a-fA-F0-9]{6}', profile):
            raise ValueError('Invalid NextDNS profile ID')
        self.profile = profile.lower()
        self.context = ssl.create_default_context()
        self.context.minimum_version = ssl.TLSVersion.TLSv1_3
        self.context.maximum_version = ssl.TLSVersion.TLSv1_3
        self.preferred = 0
        self.lock = threading.Lock()
        self.active = set()
        self.closed = False

    def close(self):
        with self.lock:
            self.closed = True
            for sock in list(self.active):
                try:
                    sock.shutdown(socket.SHUT_RDWR)
                    sock.close()
                except OSError:
                    pass

    def query(self, query):
        with self.lock:
            first = self.preferred
        last_error = None
        for attempt in range(len(SERVERS)):
            with self.lock:
                if self.closed:
                    raise OSError('DNS worker is stopping')
            index = (first + attempt) % len(SERVERS)
            try:
                reply = self.request(query, SERVERS[index])
                if len(reply) < 12 or reply[:2] != query[:2] or not reply[2] & 128:
                    raise ValueError('DoH reply does not match DNS request')
                with self.lock:
                    self.preferred = index
                return reply
            except (OSError, EOFError, ValueError, ssl.SSLError) as exc:
                last_error = exc
        raise OSError('NextDNS: ' + type(last_error).__name__)

    def request(self, query, server):
        deadline = time.monotonic() + 5
        raw = socket.create_connection((server, 443), 2.0)
        raw.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        with self.lock:
            if self.closed:
                raw.close()
                raise OSError('DNS worker is stopping')
            self.active.add(raw)
        incoming, outgoing = ssl.MemoryBIO(), ssl.MemoryBIO()
        tls = self.context.wrap_bio(incoming, outgoing, server_side=False, server_hostname=HOST)
        def receive():
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError('DoH deadline')
            raw.settimeout(remaining)
            data = raw.recv(65536)
            if not data:
                raise EOFError('DoH peer closed')
            incoming.write(data)
        def flush(first=False):
            data = outgoing.read()
            if not data:
                return
            if first:
                data = split_hello(data)
                # Send two valid records; TLS handshake bytes remain identical.
                length = 5 + int.from_bytes(data[3:5], 'big')
                raw.sendall(data[:length])
                time.sleep(.08)
                raw.sendall(data[length:])
            else:
                raw.sendall(data)
        try:
            first = True
            while True:
                try:
                    tls.do_handshake()
                    break
                except ssl.SSLWantReadError:
                    flush(first)
                    first = False
                    receive()
            flush()
            header = (f'POST /{self.profile} HTTP/1.1\r\nHost: {HOST}\r\n'
                      'Accept: application/dns-message\r\nContent-Type: application/dns-message\r\n'
                      f'Content-Length: {len(query)}\r\nConnection: close\r\n\r\n').encode('ascii')
            tls.write(header + query)
            flush()
            response = bytearray()
            def read_more():
                while True:
                    try:
                        part = tls.read(65536)
                        if not part:
                            raise EOFError('DoH body truncated')
                        return part
                    except ssl.SSLWantReadError:
                        flush()
                        receive()
            while b'\r\n\r\n' not in response:
                response += read_more()
                if len(response) > 81920:
                    raise ValueError('DoH response too large')
            head, body = bytes(response).split(b'\r\n\r\n', 1)
            lines = head.split(b'\r\n')
            if not lines[0].startswith(b'HTTP/1.1 200 '):
                raise ValueError('DoH HTTP status not 200')
            fields = dict(line.split(b':', 1) for line in lines[1:] if b':' in line)
            fields = {k.lower(): v.strip().lower() for k, v in fields.items()}
            if fields.get(b'content-type', b'').split(b';')[0] != b'application/dns-message':
                raise ValueError('Unexpected DoH content type')
            if b'content-length' in fields:
                length = int(fields[b'content-length'])
                if not 12 <= length <= 65535:
                    raise ValueError('DoH body length')
                while len(body) < length:
                    body += read_more()
                return body[:length]
            if fields.get(b'transfer-encoding') == b'chunked':
                output = bytearray()
                while True:
                    while b'\r\n' not in body:
                        body += read_more()
                    line, body = body.split(b'\r\n', 1)
                    if len(line) > 80:
                        raise ValueError('DoH chunk header')
                    length = int(line.split(b';')[0], 16)
                    if length == 0:
                        return bytes(output)
                    if length < 0 or len(output) + length > 65535:
                        raise ValueError('DoH chunks too large')
                    while len(body) < length + 2:
                        body += read_more()
                    if body[length:length+2] != b'\r\n':
                        raise ValueError('DoH chunk framing')
                    output += body[:length]
                    body = body[length+2:]
            raise ValueError('Unbounded DoH response')
        finally:
            raw.close()
            with self.lock:
                self.active.discard(raw)

def split_hello(data):
    if len(data) < 5 or data[0] != 22 or data[1] != 3:
        raise ValueError('Expected TLS ClientHello')
    length = int.from_bytes(data[3:5], 'big')
    if length < 1 or len(data) < length + 5:
        raise ValueError('Incomplete TLS record')
    payload = data[5:5+length]
    index = payload.find(HOST.encode('ascii'))
    if index < 0:
        raise ValueError('Unexpected TLS destination')
    split = index + 5
    a, b = payload[:split], payload[split:]
    return (data[:3] + struct.pack('!H', len(a)) + a +
            data[:3] + struct.pack('!H', len(b)) + b + data[5+length:])

def failure(query):
    data = bytearray(query)
    if len(data) >= 12:
        data[2] = (data[2] & 0x79) | 0x80
        data[3] = (data[3] & 0x10) | 0x82
        data[6:10] = b'\0' * 4
    return bytes(data)

class Bridge:
    def __init__(self, profile, port, data_root):
        self.doh = DoH(profile)
        self.port = port
        self.root = Path(data_root)
        self.stop = threading.Event()
        self.pool = concurrent.futures.ThreadPoolExecutor(max_workers=64)
        self.slots = threading.BoundedSemaphore(64)
        self.sockets = []
        self.lock = threading.RLock()
        self.sessions = set()
        self.stats = dict(version=1, startedAt=self.now(), at=self.now(), lastSuccessAt=None,
                          successCount=0, failureCount=0, upstream=SERVERS[0], lastError='', running=True)
        ticks = ctypes.windll.kernel32.GetTickCount64
        ticks.restype = ctypes.c_uint64
        self.boot_at = (dt.datetime.now(dt.timezone.utc) - dt.timedelta(milliseconds=ticks())).isoformat()
        self.stats['bootAt'] = self.boot_at

    def boot_probe(self):
        """Check the Windows resolver after service start; retain actual boot proof separately."""
        try:
            route_path = Path(__file__).with_name('routes.json')
            if not route_path.exists():
                route_path = Path(__file__).parent.parent / 'connection-routes.json'
            routes = json.loads(route_path.read_text(encoding='utf-8-sig'))['routes']
            uptime = (dt.datetime.now(dt.timezone.utc) - dt.datetime.fromisoformat(self.boot_at)).total_seconds()
            report = dict(bootAt=self.boot_at, serviceStartedAt=self.stats['startedAt'],
                          afterReboot=uptime < 600, status='checking', checks=[])
            def save():
                with self.lock:
                    self.root.mkdir(parents=True, exist_ok=True)
                    report['at'] = self.now()
                    temporary = self.root / 'boot-check.json.tmp'
                    temporary.write_text(json.dumps(report), encoding='utf-8')
                    os.replace(temporary, self.root / 'boot-check.json')
                    if report['status'] == 'ok' and report['afterReboot']:
                        temporary = self.root / 'boot-verified.json.tmp'
                        temporary.write_text(json.dumps(report), encoding='utf-8')
                        os.replace(temporary, self.root / 'boot-verified.json')
            save()
            for attempt in range(4):
                if self.stop.is_set():
                    return
                nonce = 'boot-' + os.urandom(6).hex()
                checks = []
                for route in routes:
                    try:
                        answers = sorted({item[4][0] for item in socket.getaddrinfo(
                            nonce + '.' + route['domain'], None, socket.AF_UNSPEC, socket.SOCK_STREAM)})
                        good = bool(answers) and set(answers).issubset(route['addresses'])
                    except OSError:
                        answers, good = [], False
                    checks.append(dict(domain=route['domain'], addresses=answers, ok=good))
                report.update(checks=checks, attempt=attempt + 1,
                              status='ok' if checks and all(item['ok'] for item in checks) else 'waiting')
                save()
                if report['status'] == 'ok':
                    return
                if self.stop.wait(10):
                    return
            report['status'] = 'error'
            save()
        except Exception:
            # DNS service remains available even when its optional startup report cannot be written.
            return

    @staticmethod
    def now():
        return dt.datetime.now(dt.timezone.utc).isoformat()

    def write_status(self):
        with self.lock:
            try:
                self.root.mkdir(parents=True, exist_ok=True)
                self.stats['at'] = self.now()
                temporary = self.root / 'status.json.tmp'
                temporary.write_text(json.dumps(self.stats), encoding='utf-8')
                os.replace(temporary, self.root / 'status.json')
            except OSError:
                pass

    def resolve(self, query):
        try:
            answer = self.doh.query(query)
            with self.lock:
                self.stats.update(lastSuccessAt=self.now(), lastError='', upstream=SERVERS[self.doh.preferred])
                self.stats['successCount'] += 1
            return answer
        except Exception as exc:
            with self.lock:
                self.stats['failureCount'] += 1
                self.stats['lastError'] = type(exc).__name__ + ': ' + str(exc)[:160]
            return failure(query)
        finally:
            self.write_status()

    def start(self, on_ready=None):
        try:
            for family, ip in ((socket.AF_INET, '127.0.0.1'), (socket.AF_INET6, '::1')):
                for kind in (socket.SOCK_DGRAM, socket.SOCK_STREAM):
                    sock = socket.socket(family, kind)
                    sock.setsockopt(socket.SOL_SOCKET, socket.SO_EXCLUSIVEADDRUSE, 1)
                    sock.bind((ip, self.port))
                    self.sockets.append(sock)
                    if kind == socket.SOCK_DGRAM:
                        action = self.udp
                    else:
                        sock.listen(64)
                        action = self.tcp
                    threading.Thread(target=action, args=(sock,), daemon=True).start()
            self.write_status()
            if on_ready is not None:
                on_ready()
            print('READY', flush=True)
            threading.Thread(target=self.boot_probe, daemon=True).start()
            while not self.stop.wait(30):
                self.write_status()
        finally:
            self.close()

    def submit(self, action, *args):
        if self.stop.is_set():
            return False
        if not self.slots.acquire(False):
            return False
        def run():
            try:
                action(*args)
            finally:
                self.slots.release()
        try:
            self.pool.submit(run)
        except RuntimeError:
            self.slots.release()
            return False
        return True

    def udp(self, sock):
        while not self.stop.is_set():
            try:
                query, peer = sock.recvfrom(65535)
                if len(query) >= 12 and not query[2] & 128:
                    def answer(q, p):
                        try:
                            sock.sendto(self.resolve(q), p)
                        except OSError:
                            pass
                    if not self.submit(answer, query, peer):
                        sock.sendto(failure(query), peer)
            except OSError:
                if not self.stop.is_set():
                    time.sleep(.1)

    @staticmethod
    def exact(sock, length):
        parts = bytearray()
        while len(parts) < length:
            data = sock.recv(length - len(parts))
            if not data:
                raise EOFError('DNS TCP closed')
            parts += data
        return bytes(parts)

    def tcp(self, listener):
        while not self.stop.is_set():
            try:
                sock, _ = listener.accept()
                with self.lock:
                    if self.stop.is_set():
                        sock.close()
                        return
                    self.sessions.add(sock)
                if not self.submit(self.tcp_client, sock):
                    with self.lock:
                        self.sessions.discard(sock)
                    sock.close()
            except OSError:
                if not self.stop.is_set():
                    time.sleep(.1)

    def tcp_client(self, sock):
        with sock:
            sock.settimeout(12)
            try:
                for _ in range(16):
                    length = int.from_bytes(self.exact(sock, 2), 'big')
                    if length < 12:
                        return
                    response = self.resolve(self.exact(sock, length))
                    sock.sendall(struct.pack('!H', len(response)) + response)
            except (OSError, EOFError):
                pass
            finally:
                with self.lock:
                    self.sessions.discard(sock)

    def close(self):
        self.stop.set()
        for sock in self.sockets:
            sock.close()
        with self.lock:
            sessions = list(self.sessions)
            self.sessions.clear()
        for sock in sessions:
            try:
                sock.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            sock.close()
        self.doh.close()
        self.pool.shutdown(wait=False, cancel_futures=True)
        with self.lock:
            self.stats['running'] = False
        self.write_status()

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--profile-file', required=True)
    parser.add_argument('--port', type=int, default=53)
    parser.add_argument('--data-dir', required=True)
    parser.add_argument('--service', action='store_true')
    parser.add_argument('--service-name', default='NextDNSBridge')
    args = parser.parse_args()
    if not 1 <= args.port <= 65535:
        parser.error('Port must be between 1 and 65535')
    if args.service:
        if not re.fullmatch(r'[A-Za-z0-9_.-]{1,64}', args.service_name):
            parser.error('Invalid Windows service name')
        root = Path(args.data_dir)

        def log(message):
            try:
                root.mkdir(parents=True, exist_ok=True)
                path = root / 'service.log'
                if path.exists() and path.stat().st_size > 256 * 1024:
                    path.write_text('', encoding='utf-8')
                with path.open('a', encoding='utf-8') as stream:
                    stream.write(dt.datetime.now(dt.timezone.utc).isoformat() + ' ' + message + '\n')
            except OSError:
                pass

        def factory():
            profile = Path(args.profile_file).read_text(encoding='utf-8-sig').strip()
            return Bridge(profile, args.port, args.data_dir)

        # Services report to service.log and SCM, not to a console owned by another process.
        sys.stdin = open(os.devnull, 'r')
        sys.stdout = open(os.devnull, 'w')
        sys.stderr = open(os.devnull, 'w')
        try:
            return run_service(args.service_name, factory, log)
        except OSError as exc:
            log('Cannot connect to Windows Service Control Manager: ' + str(exc))
            return 1
    profile = Path(args.profile_file).read_text(encoding='utf-8-sig').strip()
    bridge = Bridge(profile, args.port, args.data_dir)
    def control():
        for line in sys.stdin:
            if line.strip() == 'STOP':
                bridge.stop.set()
                return
    threading.Thread(target=control, daemon=True).start()
    bridge.start()

if __name__ == '__main__':
    sys.exit(main())
