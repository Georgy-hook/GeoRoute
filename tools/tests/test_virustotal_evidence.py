"""Regressions for cached empty VirusTotal cards; no live requests or uploads."""
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest

MODULE = Path(__file__).resolve().parents[1] / 'scan_virustotal_release.py'


class EvidenceTests(unittest.TestCase):
    def setUp(self):
        self.previous = Path.cwd()
        self.directory = tempfile.TemporaryDirectory()
        os.chdir(self.directory.name)
        spec = importlib.util.spec_from_file_location('georoute_audit_test', MODULE)
        self.audit = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.audit)

    def tearDown(self):
        os.chdir(self.previous)
        self.directory.cleanup()

    def test_placeholder_recovers_existing_analysis_without_upload(self):
        import hashlib
        content = b'public test source'
        digest = hashlib.sha256(content).hexdigest()
        empty = {'data': {'analysis_date': None, 'last_analysis_stats': {}, 'coverage': {'engines': 0}}}
        calls = []

        def api(path, **kwargs):
            calls.append((path, kwargs.get('method', 'GET')))
            if '/files/' in path:
                return 200, empty
            if '/submissions/' in path:
                return 200, {'analysis_id': 'existing-id'}
            if '/analyses/' in path:
                return 200, {'status': 'completed', 'sha256': digest, 'analysis_date': '2026-11-06T10:00:00Z',
                             'stats': {'malicious': 0, 'suspicious': 0, 'undetected': 1}, 'coverage': {'engines': 1}}
            return 200, {}

        self.audit.api = api
        self.audit.fetch = lambda *args, **kwargs: (200, b'{}')
        self.audit.bootstrap = lambda: None
        self.audit.time.sleep = lambda _: None
        self.audit.audit_files([('test.ps1', content)])
        result = json.loads(Path('scan-results/reports.json').read_text())[0]
        self.assertEqual(result['state'], 'completed')
        self.assertEqual(result['report']['data']['evidence_source'], 'completed-analysis')
        self.assertTrue(all(method == 'GET' for _, method in calls))

    def test_unrelated_or_empty_analysis_cannot_be_used(self):
        analysis = {'status': 'completed', 'sha256': 'a' * 64, 'analysis_date': '2026-11-06',
                    'stats': {'undetected': 1}, 'coverage': {'engines': 1}}
        self.assertIsNone(self.audit.completed_analysis_report(analysis, 'b' * 64))
        analysis['coverage']['engines'] = 0
        self.assertIsNone(self.audit.completed_analysis_report(analysis, 'a' * 64))
        self.assertFalse(self.audit.has_engine_results({'data': {}}))


if __name__ == '__main__':
    unittest.main()
