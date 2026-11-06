"""Exercise real HTTP2 frames and cookie redirects without network or browser data."""
import importlib.util
from pathlib import Path
import time
import unittest

spec = importlib.util.spec_from_file_location('gemini_probe', Path(__file__).parents[1] / '_service/gemini_probe.py')
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)


class GooglePeer:
    def __init__(self, cookies=True):
        self.cookies = cookies
        self.requests = []
        self.conn = probe.h2.connection.H2Connection(config=probe.h2.config.H2Configuration(client_side=False, header_encoding='utf-8'))
        self.conn.initiate_connection()
        self.pending = bytearray(self.conn.data_to_send())

    def settimeout(self, value):
        pass

    def sendall(self, data):
        for event in self.conn.receive_data(data):
            if not isinstance(event, probe.h2.events.RequestReceived):
                continue
            h = dict(event.headers)
            self.requests.append(h)
            body = b''
            if h[':authority'] == 'www.google.com':
                headers = [(':status', '302'), ('location', 'https://gemini.google.com/app?google_abuse=ok')]
            elif h[':path'].startswith('/app?'):
                headers = [(':status', '302'), ('location', 'https://gemini.google.com/app')]
                if self.cookies:
                    headers.append(('set-cookie', 'GOOGLE_ABUSE_EXEMPTION=fixture; Domain=.google.com; Path=/; Secure; HttpOnly'))
            elif 'GOOGLE_ABUSE_EXEMPTION=fixture' in h.get('cookie', ''):
                headers = [(':status', '200')]
                body = b'<title>Google Gemini</title>,2,1,200,"NLD"'
            else:
                headers = [(':status', '302'), ('location', 'https://www.google.com/sorry/index?continue=https://gemini.google.com/app')]
            self.conn.send_headers(event.stream_id, headers, end_stream=not body)
            if body:
                self.conn.send_data(event.stream_id, body, end_stream=True)
        self.pending += self.conn.data_to_send()

    def recv(self, length):
        result = bytes(self.pending[:length])
        del self.pending[:length]
        return result


class Tests(unittest.TestCase):
    def test_cookie_round_trip_on_one_connection(self):
        peer = GooglePeer()
        session = probe.Session(peer, time.monotonic() + 5)
        result = probe.check_session(session)
        self.assertTrue(result['ready'] and result['verification'])
        self.assertEqual(result['country'], 'NLD')
        self.assertEqual(len(peer.requests), 4)
        self.assertTrue(any(c.name == 'GOOGLE_ABUSE_EXEMPTION' for c in session.jar))

    def test_redirect_loop_not_ready(self):
        session = probe.Session(GooglePeer(cookies=False), time.monotonic() + 5)
        self.assertFalse(probe.check_session(session)['ready'])

    def test_no_external_or_unencrypted_redirect(self):
        peer = GooglePeer()
        session = probe.Session(peer, time.monotonic() + 5)
        for url in ('https://evil.example/', 'http://www.google.com/', 'https://www.google.com.evil.example/', 'https://www.google.com:8443/', 'https://user:pass@www.google.com/'):
            with self.assertRaises(ValueError):
                session.get(url)
        self.assertFalse(peer.requests)

    def test_deadline(self):
        session = probe.Session(GooglePeer(), time.monotonic() - 1)
        with self.assertRaises(TimeoutError):
            session.get('https://gemini.google.com/app')

    def test_certificate_must_cover_www(self):
        for name in ('www.google.com', '*.google.com'):
            self.assertTrue(probe.www_certificate_valid({'subjectAltName': [('DNS', name)]}))
        for name in ('gemini.google.com', '*.com', 'www.google.com.evil.example'):
            self.assertFalse(probe.www_certificate_valid({'subjectAltName': [('DNS', name)]}))


if __name__ == '__main__':
    unittest.main()
