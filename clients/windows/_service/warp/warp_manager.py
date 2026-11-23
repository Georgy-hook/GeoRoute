"""Account-bound WARP service. Fixed SCM controls; bounded, validated profile data.

All executable code/configuration is installed under administrator-only write ACLs.
The owner may submit AI host mappings, never paths, scripts or arbitrary commands.
Only exact IPv4 routes are created; DNS, proxy, firewall and default routes stay alone.
"""
import argparse
import datetime as dt
import ipaddress
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import queue
import re
import subprocess
import socket
import ssl
import struct
import sys
import threading
import time

SCHEMA = 1
GEMINI = frozenset(('gemini.google.com', 'gemini.google', 'bard.google.com', 'www.google.com',
                   'geminiweb-pa.clients.google.com', 'geminiweb-pa.clients6.google.com',
                   'generativelanguage.googleapis.com', 'geller-pa.googleapis.com',
                   'proactivebackend-pa.googleapis.com', 'robinfrontend-pa.googleapis.com'))
ASSET = 'gemini.gstatic.com'
ID = re.compile(r'[a-zA-Z0-9_.-]{1,64}\Z')
DOMAIN = re.compile(r'[a-z0-9](?:[a-z0-9-]*[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)*\Z')
SID = re.compile(r'S-1-5-21-(?:\d+-){2}\d+-\d+\Z')


def valid_domain(value):
    if not isinstance(value, str) or len(value) > 253 or not DOMAIN.fullmatch(value):
        return False
    if any(len(label) > 63 for label in value.split('.')):
        return False
    return value in GEMINI or any(value == suffix or value.endswith('.' + suffix)
                                  for suffix in ('chatgpt.com', 'openai.com', 'oaistatic.com', 'oaiusercontent.com'))


def validate_profile(value):
    if not isinstance(value, dict) or set(value) - {'id', 'name', 'map'}:
        raise ValueError('Invalid profile fields')
    name, profile_id, records = value.get('name'), value.get('id'), value.get('map')
    if not isinstance(name, str) or not 1 <= len(name) <= 120 or any(ord(c) < 32 for c in name):
        raise ValueError('Invalid profile name')
    if not isinstance(profile_id, str) or not ID.fullmatch(profile_id):
        raise ValueError('Invalid profile identifier')
    if not isinstance(records, list) or not 1 <= len(records) <= 512:
        raise ValueError('Invalid host count')
    hosts = {}
    for record in records:
        if not isinstance(record, dict) or set(record) != {'domain', 'address'}:
            raise ValueError('Invalid host record')
        domain, address = record['domain'], record['address']
        if domain == ASSET:
            continue  # Public Google assets must retain their native route.
        if not valid_domain(domain) or not isinstance(address, str):
            raise ValueError('Unsupported domain')
        ip = ipaddress.ip_address(address)
        if ip.version != 4 or not ip.is_global or ip.is_multicast or ip.is_reserved or str(ip) != address:
            raise ValueError('A public IPv4 address is required')
        if domain in hosts and hosts[domain] != address:
            raise ValueError('Conflicting host addresses')
        hosts[domain] = address
    if not hosts or len(set(hosts.values())) > 32:
        raise ValueError('Invalid route count')
    if 'gemini.google.com' in hosts:
        hosts.setdefault('www.google.com', hosts['gemini.google.com'])
        if hosts['www.google.com'] != hosts['gemini.google.com']:
            raise ValueError('Gemini and Google verification must share one address')
    return dict(id=profile_id, name=name, map=[dict(domain=d, address=hosts[d]) for d in sorted(hosts)])


def validate_routes(value):
    if not isinstance(value, list) or len(value) > 64:
        raise ValueError('Invalid route list')
    routes = set()
    for address in value:
        if not isinstance(address, str):
            raise ValueError('Invalid route address')
        ip = ipaddress.ip_address(address)
        if ip.version != 4 or not ip.is_global or ip.is_multicast or ip.is_reserved or str(ip) != address:
            raise ValueError('A public IPv4 host route is required')
        routes.add(address)
    return sorted(routes)


def read_json(path, limit=131072):
    path = Path(path)
    if path.is_symlink() or (getattr(path.lstat(), 'st_file_attributes', 0) & 0x400):
        raise ValueError('Reparse-point data file')
    with path.open('rb') as stream:
        value = stream.read(limit + 1)
    if len(value) > limit:
        raise ValueError('Oversized data file')
    return json.loads(value.decode('utf-8-sig'))


def atomic_json(path, value):
    path = Path(path)
    temporary = path.with_name(path.name + '.tmp')
    with temporary.open('w', encoding='utf-8') as stream:
        json.dump(value, stream, ensure_ascii=False, indent=2)
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temporary, path)


def wanted_on_start(auto_start, saved, boot):
    if isinstance(saved, dict) and saved.get('boot') == boot and type(saved.get('wanted')) is bool:
        return saved['wanted']
    return auto_start


def retry_delay(attempt):
    return min(300, 5 * 2 ** min(max(attempt, 0), 6))


class Manager:
    def __init__(self, program, data, network=None, boot=None, health=None, passive=None):
        self.program, self.data = Path(program), Path(data)
        self.private, self.public = self.data / 'private', self.data / 'public'
        self.config_path = self.private / 'settings.json'
        self.config = read_json(self.config_path)
        if self.config.get('schema') != SCHEMA or not SID.fullmatch(self.config.get('ownerSid', '')):
            raise ValueError('Invalid controller settings')
        if type(self.config.get('autoStart')) is not bool:
            raise ValueError('Invalid automatic-start preference')
        self.profile = validate_profile(self.config['profile'])
        self.config['extraRoutes'] = validate_routes(self.config.get('extraRoutes', []))
        self.stop, self.commands = threading.Event(), queue.Queue(maxsize=32)
        self.network = network or self.run_network
        self.health = health or self.check_transport
        self.passive = passive or ((lambda: self.network('Inspect')) if network else self.passive_inspection)
        self.boot = boot or self.network('Boot')['boot']
        try:
            saved = read_json(self.private / 'session.json')
        except (OSError, ValueError):
            saved = {}
        self.wanted = wanted_on_start(self.config['autoStart'], saved, self.boot)
        self.connected = False
        self.active = None
        self.command_id = ''
        self.last_error = ''
        self.attempt = 0
        self.retry_at = 0.0
        self.last_inspection = 0.0
        self.closed = False
        self.state = 'starting'

    def log(self, message):
        try:
            path = self.public / 'service.log'
            if path.exists() and path.stat().st_size > 262144:
                path.replace(path.with_suffix('.previous.log'))
            with path.open('a', encoding='utf-8') as stream:
                stream.write(dt.datetime.now(dt.timezone.utc).isoformat() + ' ' + message + '\n')
        except OSError:
            pass

    def save_session(self):
        atomic_json(self.private / 'session.json', dict(boot=self.boot, wanted=self.wanted))

    def publish(self):
        status = dict(schema=SCHEMA, installed=True, state=self.state, requested=self.wanted,
                      connected=self.connected, autoStart=self.config['autoStart'], ownerSid=self.config['ownerSid'],
                      profileId=self.profile['id'], profileName=self.profile['name'],
                      addresses=sorted({r['address'] for r in self.profile['map']}),
                      routeAddresses=self.active.get('addresses', []) if self.active else [],
                      routesCommandId=getattr(self, 'routes_command_id', ''),
                      commandId=self.command_id, error=self.last_error,
                      at=dt.datetime.now(dt.timezone.utc).isoformat(),
                      interfaceIndex=self.active.get('interfaceIndex') if self.active else None,
                      localAddress=self.active.get('localAddress') if self.active else None,
                      country=self.active.get('country', '') if self.active else '',
                      modelReplyVerified=False)
        atomic_json(self.public / 'status.json', status)

    def enqueue(self, command):
        try:
            self.commands.put_nowait(command)
        except queue.Full:
            self.log('Command queue full')

    def handle(self, command):
        if command == 128:
            value = read_json(self.data / 'requests' / 'connect.json', 65536)
            if not isinstance(value, dict) or set(value) != {'schema', 'id', 'profile'} or value['schema'] != SCHEMA:
                raise ValueError('Invalid connection request')
            if not isinstance(value['id'], str) or not re.fullmatch('[a-f0-9]{32}', value['id']):
                raise ValueError('Invalid command identifier')
            if value['id'] == self.command_id:
                return  # SCM retries must not reapply a different payload under an old ID.
            profile = self.profile if value['profile'] is None else validate_profile(value['profile'])
            self.command_id = value['id']
            if profile != self.profile:
                self.disconnect()
                self.profile = profile
                self.config['profile'] = profile
                atomic_json(self.config_path, self.config)
            self.wanted, self.retry_at, self.attempt = True, 0, 0
            self.last_error = ''
            self.save_session()
        elif command == 129:
            self.wanted = False
            self.save_session()
            self.disconnect()
        elif command in (130, 131):
            self.config['autoStart'] = command == 130
            atomic_json(self.config_path, self.config)
        elif command == 132:
            value = read_json(self.data / 'requests' / 'routes.json', 8192)
            if not isinstance(value, dict) or set(value) != {'schema', 'id', 'addresses'} or value['schema'] != SCHEMA or not re.fullmatch('[a-f0-9]{32}', value.get('id', '')):
                raise ValueError('Invalid route update request')
            addresses = validate_routes(value['addresses'])
            if addresses != self.config['extraRoutes']:
                self.config['extraRoutes'] = addresses
                atomic_json(self.config_path, self.config)
                if self.connected:
                    self.active.update(self.network('Routes'))
            self.routes_command_id = value['id']
        else:
            raise ValueError('Unsupported service command')
        self.publish()

    def run_network(self, action):
        shell = Path(os.environ.get('SystemRoot', r'C:\Windows')) / 'System32/WindowsPowerShell/v1.0/powershell.exe'
        args = [str(shell), '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
                '-File', str(self.program / 'WarpNetwork.ps1'), '-Action', action, '-DataRoot', str(self.data)]
        # The long-lived core inherits standard handles. Files avoid waiting for
        # an inherited pipe to close after PowerShell has already finished.
        output_path = self.private / ('worker-' + action.lower() + '.log')
        error_path = self.private / ('worker-' + action.lower() + '-error.log')
        with output_path.open('wb') as output, error_path.open('wb') as error:
            process = subprocess.Popen(args, stdin=subprocess.DEVNULL, stdout=output, stderr=error,
                                       creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0))
            try:
                return_code = process.wait(timeout=45)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)
                raise RuntimeError('network_worker_timeout') from None
        # Never echo stderr or command lines: the only response accepted is bounded JSON.
        with output_path.open('rb') as stream:
            stream.seek(max(0, output_path.stat().st_size - 131072))
            text = stream.read(131072).decode('utf-8-sig', errors='replace').strip()
        lines = [line for line in text.splitlines() if line.startswith('GEOROUTE_WARP_RESULT=')]
        if not lines:
            raise RuntimeError('Network worker did not return a structured result')
        response = json.loads(lines[-1].split('=', 1)[1])
        if return_code or not response.get('ok'):
            raise RuntimeError(response.get('errorCode', 'network_worker_failed'))
        return response

    def connect(self):
        self.state, self.last_error = 'connecting', ''
        self.publish()
        try:
            self.active = self.network('Start')
            proof = self.health(self.active, self.profile)
            if not proof.get('ready'):
                raise RuntimeError('route_https_unavailable')
            self.active['country'] = proof.get('country', '')
            if self.stop.is_set() or not self.wanted:
                self.disconnect()
                return
            self.network('Apply')
            self.connected, self.state = True, 'connected'
            self.attempt = 0
            self.last_inspection = time.monotonic()
            self.save_session()
            self.log('Connected: ' + self.profile['id'])
        except Exception as exc:
            self.connected, self.state = False, 'retrying'
            self.last_error = str(exc)[:160] if isinstance(exc, RuntimeError) else type(exc).__name__
            try:
                self.network('Stop')
            except Exception:
                self.last_error += '; cleanup_pending'
            self.active = None
            self.retry_at = time.monotonic() + retry_delay(self.attempt)
            self.attempt += 1
            self.log('Connection failed: ' + self.last_error)
        self.publish()

    def disconnect(self):
        self.state = 'disconnecting'
        self.connected = False
        self.publish()
        try:
            self.network('Stop')
        except Exception:
            self.state, self.last_error = 'cleanup-required', 'network_cleanup_failed'
            self.publish()
            raise
        self.active, self.connected, self.state = None, False, 'off'
        self.last_error = ''
        self.publish()

    def inspect(self):
        result = self.passive()
        self.last_inspection = time.monotonic()
        if result.get('externalChange'):
            self.wanted = False
            self.save_session()
            self.disconnect()
            self.last_error = 'profile_changed_externally'
            self.publish()
        elif not result.get('healthy'):
            self.connected = False
            self.state = 'retrying'
            self.last_error = 'transport_stopped'
            self.network('Stop')
            self.active = None
            self.retry_at = time.monotonic() + retry_delay(self.attempt)
            self.attempt += 1
            self.publish()

    def check_transport(self, active, profile):
        records = {r['domain']: r['address'] for r in profile['map']}
        if 'gemini.google.com' in records:
            spec = importlib.util.spec_from_file_location('georoute_warp_gemini', self.program / 'gemini_probe.py')
            probe = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(probe)
            return probe.probe(records['gemini.google.com'], int(active['interfaceIndex']), active['localAddress'], 15)
        host = next((h for h in records if h == 'chatgpt.com'), next(iter(records)))
        raw = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        raw.settimeout(8)
        raw.setsockopt(socket.IPPROTO_IP, 31, struct.pack('!I', int(active['interfaceIndex'])))
        raw.bind((active['localAddress'], 0))
        try:
            raw.connect((records[host], 443))
            with ssl.create_default_context().wrap_socket(raw, server_hostname=host) as tls:
                tls.sendall(('GET /cdn-cgi/trace HTTP/1.1\r\nHost: ' + host + '\r\nConnection: close\r\n\r\n').encode())
                head = tls.recv(8192)
                return dict(ready=bool(re.match(rb'HTTP/\S+ (?:200|301|302|400|401|404)', head)))
        finally:
            raw.close()

    def passive_inspection(self):
        """Read-only Win32 checks, no child processes, HTTP requests or DNS lookups."""
        import ctypes
        from ctypes import wintypes as w
        state = read_json(self.private / 'network-state.json')
        kernel = ctypes.WinDLL('kernel32', use_last_error=True)
        kernel.OpenProcess.argtypes = [w.DWORD, w.BOOL, w.DWORD]
        kernel.OpenProcess.restype = w.HANDLE
        kernel.GetExitCodeProcess.argtypes = [w.HANDLE, ctypes.POINTER(w.DWORD)]
        kernel.CloseHandle.argtypes = [w.HANDLE]
        handle = kernel.OpenProcess(0x1000, False, int(state['corePid']))
        alive = False
        if handle:
            code = w.DWORD()
            alive = bool(kernel.GetExitCodeProcess(handle, ctypes.byref(code))) and code.value == 259
            kernel.CloseHandle(handle)
        ip_api = ctypes.WinDLL('iphlpapi', use_last_error=True)
        ip_api.GetBestInterface.argtypes = [w.DWORD, ctypes.POINTER(w.DWORD)]
        ip_api.GetBestInterface.restype = w.DWORD
        routes = True
        for address in state['addresses']:
            best = w.DWORD()
            if ip_api.GetBestInterface(int.from_bytes(ipaddress.ip_address(address).packed, 'little'), ctypes.byref(best)) or best.value != self.active['interfaceIndex']:
                routes = False
        hosts = (Path(os.environ['SystemRoot']) / 'System32/drivers/etc/hosts').read_bytes()
        block = re.search(rb'(?ms)^# BEGIN CHATGPT-US-WINDOWS\r?\n.*?^# END CHATGPT-US-WINDOWS(?:\r?\n|$)', hosts)
        owned = bool(block and hashlib.sha256(block[0]).hexdigest().upper() == state['blockHash'])
        return dict(healthy=alive and routes and owned, externalChange=not owned)
    def start(self, on_ready=None):
        # A new boot with auto-start off still cleans up an interrupted old session.
        self.network('Stop')
        self.state = 'off'
        self.save_session()
        self.publish()
        if on_ready:
            on_ready()
        try:
            while not self.stop.is_set():
                try:
                    self.handle(self.commands.get(timeout=.5))
                except queue.Empty:
                    pass
                except Exception as exc:
                    self.last_error = type(exc).__name__
                    self.log('Command rejected: ' + self.last_error)
                    self.publish()
                if self.wanted and not self.connected and time.monotonic() >= self.retry_at:
                    self.connect()
                if self.connected and time.monotonic() - self.last_inspection >= 5:
                    try:
                        self.inspect()
                    except Exception as exc:
                        self.log('Inspection: ' + type(exc).__name__)
        finally:
            self.close()

    def close(self):
        if self.closed:
            return
        self.closed = True
        self.stop.set()
        try:
            self.disconnect()
        except Exception as exc:
            self.state = 'cleanup-required'
            self.last_error = type(exc).__name__
            self.publish()
            self.log('Cleanup requires attention')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--program-dir', type=Path, required=True)
    parser.add_argument('--data-dir', type=Path, required=True)
    parser.add_argument('--service', action='store_true')
    args = parser.parse_args()
    if not args.service or os.name != 'nt':
        parser.error('Run as the installed Windows service')
    if args.program_dir.resolve() != Path(__file__).resolve().parent:
        parser.error('Program directory must be the installed controller directory')
    spec = importlib.util.spec_from_file_location('georoute_warp_scm', args.program_dir / 'warp_windows_service.py')
    scm = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(scm)
    def log(message):
        # SCM setup failures contain no account data.
        path = args.data_dir / 'public' / 'service.log'
        with path.open('a', encoding='utf-8') as stream:
            stream.write(dt.datetime.now(dt.timezone.utc).isoformat() + ' ' + message + '\n')
    sys.stdin = open(os.devnull, 'r')
    sys.stdout = open(os.devnull, 'w')
    sys.stderr = open(os.devnull, 'w')
    return scm.run_service('GeoRouteWARP', lambda: Manager(args.program_dir, args.data_dir), log)


if __name__ == '__main__':
    sys.exit(main())
