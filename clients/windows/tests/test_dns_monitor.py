import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).parents[1] / '_service/bridge'))
import dns_monitor as monitor


class DNSMonitor(unittest.TestCase):
    def test_scan_uses_only_fixed_public_domain_and_keeps_failures_separate(self):
        calls = []

        def fake_probe(settings):
            calls.append(settings)
            if settings['url'].startswith('https://bad.'):
                raise TimeoutError('test timeout')
            return dict(rows=[dict(server='8.8.8.8', ok=True, ms=10, rcode=0, answers=1)])

        items = [dict(id='good', name='Good', url='https://good.example/dns-query'),
                 dict(id='bad', name='Bad', url='https://bad.example/dns-query')]
        with tempfile.TemporaryDirectory() as root, patch.object(monitor.dns, 'probe', side_effect=fake_probe):
            path = Path(root) / 'result.json'
            result = monitor.run(items, path, 'test-run')
            self.assertEqual(json.loads(path.read_text()), result)
        self.assertEqual(result['completed'], 2)
        self.assertFalse(result['running'])
        self.assertEqual(result['runId'], 'test-run')
        self.assertTrue(result['rows'][0]['ready'])
        self.assertFalse(result['rows'][1]['ready'])
        self.assertIn('TimeoutError', result['rows'][1]['error'])
        self.assertTrue(all(c['domains'] == ['example.com'] for c in calls))

    def test_empty_dns_answer_is_not_healthy(self):
        with patch.object(monitor.dns, 'probe', return_value=dict(rows=[dict(ok=True, rcode=0, answers=0)])):
            row = monitor.check(dict(id='test', name='Test', url='https://dns.example/dns-query'))
        self.assertFalse(row['ready'])

    def test_custom_dns_added_once_without_copying_user_sites(self):
        raw = dict(providers=[dict(id='one', name='One', url='https://one.example/dns-query')])
        own = dict(url='https://custom.example/dns-query', domains=['private.example'], servers=['8.8.8.8'])
        rows = monitor.providers(raw, own)
        self.assertEqual(len(rows), 2)
        self.assertNotIn('domains', rows[-1])
        self.assertEqual(len(monitor.providers(raw, dict(url=raw['providers'][0]['url']))), 1)
        with self.assertRaises(ValueError):
            monitor.providers(dict(providers=raw['providers'] * 2))


if __name__ == '__main__':
    unittest.main()
