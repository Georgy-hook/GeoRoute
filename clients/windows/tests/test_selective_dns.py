import importlib.util
import socket
import ssl
import struct
import sys
import tempfile
import threading
import unittest
from pathlib import Path

folder = Path(__file__).parents[1] / '_service/bridge'
sys.path.insert(0, str(folder))
import selective_dns as dns


def settings(**changes):
    raw = dict(url='https://eu.geohide.ru/dns-query', servers=['143.20.64.192'],
               domains=['claude.ai'], subdomains=True)
    raw.update(changes)
    return dns.config(raw)


class SelectedDNS(unittest.TestCase):
    def test_normalize_links_idn_and_deduplicate(self):
        cfg = settings(domains=['https://Claude.AI/chat/123', 'claude.ai', 'пример.рф'])
        self.assertEqual(cfg['domains'], ['claude.ai', 'xn--e1afmkfd.xn--p1ai'])

    def test_exact_and_suffix_boundaries(self):
        cfg = settings()
        for name in ['claude.ai', 'api.claude.ai']:
            self.assertTrue(dns.matches(name, cfg))
        for name in ['notclaude.ai', 'claude.ai.evil.test', 'example.com']:
            self.assertFalse(dns.matches(name, cfg))
        cfg['subdomains'] = False
        self.assertFalse(dns.matches('api.claude.ai', cfg))

    def test_endpoint_and_bootstrap_boundaries(self):
        for url in ['http://eu.geohide.ru/dns-query', 'https://user:pass@eu.geohide.ru/',
                    'https://eu.geohide.ru:8443/', 'https://localhost/',
                    'https://eu.geohide.ru/dns-query?token=x', 'https://eu.geohide.ru/#x']:
            with self.subTest(url=url), self.assertRaises(ValueError):
                settings(url=url)
        for ip in ['127.0.0.1', '10.0.0.1', '169.254.169.254', '::1', 'fc00::1']:
            with self.subTest(ip=ip), self.assertRaises(ValueError):
                settings(servers=[ip])
        with self.assertRaises(ValueError):
            settings(domains=['geohide.ru'])
        with self.assertRaises(ValueError):
            settings(domains=['*.claude.ai'])
        with self.assertRaises(ValueError):
            settings(domains=['8.8.8.8'])
        with self.assertRaises(ValueError):
            settings(domains=[])

    def test_authenticated_tls_and_same_question(self):
        provider = dns.Provider(settings())
        self.assertTrue(provider.context.check_hostname)
        self.assertEqual(provider.context.verify_mode, ssl.CERT_REQUIRED)
        packet = dns.query('claude.ai')
        other = bytearray(dns.query('example.io')); other[2] = 0x81
        provider.request = lambda q, ip: bytes(other)
        with self.assertRaises(ValueError):
            provider.query(packet)
        packet = dns.query('claude.ai', 65)
        other = bytearray(dns.query('claude.ai', 97)); other[2] = 0x81
        provider.request = lambda q, ip: bytes(other)
        with self.assertRaises(ValueError):
            provider.query(packet)
        provider.close()

    def test_malformed_dns_is_rejected(self):
        for packet in [b'', dns.query('claude.ai')[:15], b'\0' * 12,
                       struct.pack('!6H', 1, 0x100, 1, 0, 0, 0) + b'\xc0\x0c\0\1\0\1']:
            with self.assertRaises(ValueError):
                dns.question(packet)

    def test_real_local_udp_tcp_and_unselected_refusal(self):
        with tempfile.TemporaryDirectory() as root:
            worker = dns.SelectedBridge(settings(), 0, root, refresh=False)
            calls = []

            def answer(packet):
                calls.append(dns.question(packet)[0])
                response = bytearray(packet); response[2:4] = b'\x81\x80'
                return bytes(response)

            worker.doh.query = answer
            ready = threading.Event()
            thread = threading.Thread(target=worker.start, kwargs={'on_ready': ready.set}, daemon=True)
            thread.start()
            try:
                self.assertTrue(ready.wait(3))
                self.assertEqual({s.getsockname()[0] for s in worker.sockets}, {'127.0.0.2'})
                udp = next(s for s in worker.sockets if s.type == socket.SOCK_DGRAM)
                with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as client:
                    client.settimeout(2)
                    client.sendto(dns.query('api.claude.ai'), udp.getsockname())
                    self.assertEqual(client.recv(65535)[3] & 15, 0)
                    client.sendto(dns.query('example.com'), udp.getsockname())
                    self.assertEqual(client.recv(65535)[3] & 15, 5)
                tcp = next(s for s in worker.sockets if s.type == socket.SOCK_STREAM)
                with socket.create_connection(tcp.getsockname(), 2) as client:
                    packet = dns.query('claude.ai')
                    client.sendall(struct.pack('!H', len(packet)) + packet)
                    size = int.from_bytes(worker.exact(client, 2), 'big')
                    self.assertEqual(worker.exact(client, size)[3] & 15, 0)
                self.assertEqual(calls, ['api.claude.ai', 'claude.ai'])
            finally:
                worker.stop.set(); thread.join(3); worker.close()
            self.assertFalse(thread.is_alive())


if __name__ == '__main__':
    unittest.main()
