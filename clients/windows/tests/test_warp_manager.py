import base64
import copy
import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1] / '_service'


def module(name, filename):
    spec = importlib.util.spec_from_file_location(name, ROOT / 'warp' / filename)
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


w = module('warp_manager_test', 'warp_manager.py')
p = module('warp_provision_test', 'warp_provision.py')
PROFILE = {'id': 'eu-primary', 'name': 'GeoHide EU', 'map': [
    {'domain': 'gemini.google.com', 'address': '37.221.93.141'},
    {'domain': 'geminiweb-pa.clients6.google.com', 'address': '37.221.93.141'}]}


class Profiles(unittest.TestCase):
    def test_google_verification_is_added_to_the_same_node(self):
        value = w.validate_profile(PROFILE)
        hosts = {x['domain']: x['address'] for x in value['map']}
        self.assertEqual(hosts['www.google.com'], hosts['gemini.google.com'])

    def test_google_split_route_is_rejected(self):
        value = copy.deepcopy(PROFILE)
        value['map'].append(dict(domain='www.google.com', address='143.20.64.192'))
        with self.assertRaises(ValueError):
            w.validate_profile(value)

    def test_native_assets_are_not_pinned(self):
        value = copy.deepcopy(PROFILE)
        value['map'].append(dict(domain='gemini.gstatic.com', address='37.221.93.141'))
        self.assertNotIn('gemini.gstatic.com', [v['domain'] for v in w.validate_profile(value)['map']])

    def test_private_and_noncanonical_ips_cannot_be_routed(self):
        for address in ['127.0.0.1', '10.1.2.3', '169.254.1.1', '0.0.0.0', '224.0.0.1', '::1', '37.221.93.141/24', '037.221.93.141']:
            with self.subTest(address=address):
                value = copy.deepcopy(PROFILE)
                value['map'][0]['address'] = address
                with self.assertRaises(ValueError):
                    w.validate_profile(value)

    def test_arbitrary_domains_paths_and_commands_are_not_accepted(self):
        for domain in ['example.com', 'accounts.google.com', 'mail.google.com', 'google.com', 'x.google.com',
                       'api.openai.com.evil.test', 'chatgpt.com\n127.0.0.1 localhost', '*.openai.com']:
            value = copy.deepcopy(PROFILE)
            value['map'][0]['domain'] = domain
            with self.subTest(domain=domain), self.assertRaises(ValueError):
                w.validate_profile(value)
        value = copy.deepcopy(PROFILE)
        value['script'] = 'powershell.exe'
        with self.assertRaises(ValueError):
            w.validate_profile(value)

    def test_chatgpt_subdomains_remain_supported(self):
        self.assertTrue(w.valid_domain('files.oaiusercontent.com'))
        self.assertTrue(w.valid_domain('ab.storage.oaiusercontent.com'))
        self.assertTrue(w.valid_domain('api.openai.com'))


class Lifecycle(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.data = Path(self.temp.name)
        for name in ['private', 'public', 'requests']:
            (self.data / name).mkdir()
        w.atomic_json(self.data / 'private/settings.json', dict(schema=1,
                      ownerSid='S-1-5-21-111-222-333-1001', autoStart=False,
                      profile=w.validate_profile(PROFILE)))
        self.calls = []
        self.inspection = dict(healthy=True, externalChange=False)
        def network(action):
            self.calls.append(action)
            if action == 'Start':
                return dict(ok=True, interfaceIndex=55, localAddress='172.31.255.1')
            if action == 'Inspect':
                return self.inspection
            return dict(ok=True)
        self.network = network
        self.manager = self.new_manager()

    def tearDown(self):
        self.temp.cleanup()

    def new_manager(self, boot='boot-a'):
        def health(active, profile):
            self.calls.append('HTTPS')
            return dict(ready=True, country='DEU')
        return w.Manager(self.data, self.data, self.network, boot, health)

    def request(self, profile=None, command_id='a' * 32):
        w.atomic_json(self.data / 'requests/connect.json', dict(schema=1, id=command_id, profile=profile))
        self.manager.handle(128)

    def test_connection_checks_https_before_changing_hosts(self):
        self.request()
        self.manager.connect()
        self.assertEqual(self.calls, ['Start', 'HTTPS', 'Apply'])
        state = w.read_json(self.data / 'public/status.json')
        self.assertTrue(state['connected'])
        self.assertFalse(state['modelReplyVerified'])

    def test_autostart_is_off_by_default_and_does_not_connect_when_toggled(self):
        self.assertFalse(self.manager.wanted)
        self.manager.handle(130)
        self.assertTrue(w.read_json(self.data / 'private/settings.json')['autoStart'])
        self.assertFalse(self.manager.wanted)
        self.assertEqual(self.calls, [])
        self.manager.handle(131)
        self.assertFalse(w.read_json(self.data / 'private/settings.json')['autoStart'])

    def test_same_boot_crash_resumes_but_new_boot_honors_opt_out(self):
        self.request()
        self.assertTrue(self.new_manager('boot-a').wanted)
        self.assertFalse(self.new_manager('boot-b').wanted)
        self.manager.handle(130)
        self.assertTrue(self.new_manager('boot-b').wanted)

    def test_manual_disconnect_stays_off_in_same_boot(self):
        self.manager.handle(130)
        self.request()
        self.manager.connect()
        self.manager.handle(129)
        self.assertFalse(self.new_manager('boot-a').wanted)
        self.assertTrue(self.new_manager('boot-b').wanted)

    def test_child_crash_cleans_up_then_retries(self):
        self.request()
        self.manager.connect()
        self.inspection.update(healthy=False)
        self.manager.inspect()
        self.assertEqual(self.calls[-1], 'Stop')
        self.assertTrue(self.manager.wanted)
        self.assertFalse(self.manager.connected)
        self.assertEqual(self.manager.state, 'retrying')
        self.manager.connect()
        self.assertTrue(self.manager.connected)

    def test_external_profile_edits_are_preserved_and_not_overwritten(self):
        self.request()
        self.manager.connect()
        self.inspection.update(healthy=False, externalChange=True)
        self.manager.inspect()
        self.assertFalse(self.manager.wanted)
        self.assertEqual(self.manager.last_error, 'profile_changed_externally')
        self.assertFalse(self.new_manager('boot-a').wanted)

    def test_failed_https_does_not_apply_hosts(self):
        self.request()
        self.manager.health = lambda *args: dict(ready=False)
        self.manager.connect()
        self.assertNotIn('Apply', self.calls)
        self.assertEqual(self.calls[-1], 'Stop')
        self.assertFalse(self.manager.connected)

    def test_duplicate_command_id_is_idempotent(self):
        self.request()
        self.manager.connect()
        calls = list(self.calls)
        other = copy.deepcopy(PROFILE)
        other['name'] = 'Other'
        self.request(other)
        self.assertEqual(self.calls, calls)
        self.assertEqual(self.manager.profile['name'], 'GeoHide EU')

    def test_close_is_idempotent_and_cleans_owned_network(self):
        self.request()
        self.manager.connect()
        self.manager.close()
        calls = list(self.calls)
        self.manager.close()
        self.assertEqual(self.calls, calls)
        self.assertEqual(calls[-1], 'Stop')

    def test_catalogue_sync_is_bounded_and_does_not_reconnect(self):
        self.request()
        self.manager.connect()
        self.calls.clear()
        addresses = ['143.20.64.192', '37.221.93.141']
        w.atomic_json(self.data / 'requests/routes.json', dict(schema=1, id='b' * 32, addresses=addresses))
        self.manager.handle(132)
        self.assertEqual(self.calls, ['Routes'])
        self.assertTrue(self.manager.connected)
        self.assertEqual(w.read_json(self.data / 'private/settings.json')['extraRoutes'], sorted(addresses))
        self.assertEqual(w.read_json(self.data / 'public/status.json')['routesCommandId'], 'b' * 32)

    def test_route_requests_reject_private_networks_and_large_lists(self):
        for value in [['0.0.0.0'], ['10.1.2.3'], ['127.0.0.1'], ['224.0.0.1'], ['::1'], ['1.1.1.1'] * 65]:
            with self.subTest(value=value[:1]), self.assertRaises(ValueError):
                w.validate_routes(value)
        self.assertEqual(w.validate_routes(['37.221.93.141', '37.221.93.141']), ['37.221.93.141'])

    @unittest.skipUnless(os.name == 'nt', 'Windows process-handle regression')
    def test_network_worker_does_not_wait_for_core_inherited_output(self):
        # Real PowerShell starts a longer-lived child that inherits its output.
        # The worker result must return before that child closes the handle.
        child = self.data / 'fixture_child.py'
        child.write_text('import time; time.sleep(5)', encoding='utf-8')
        shell = """param($Action,$DataRoot)
$start=[Diagnostics.ProcessStartInfo]::new()
$start.FileName='PYTHON_EXE'
$start.Arguments='"CHILD_FILE"'
$start.UseShellExecute=$false;$start.CreateNoWindow=$true
$child=[Diagnostics.Process]::Start($start)
Write-Output ('GEOROUTE_WARP_RESULT='+(@{ok=$true;childId=$child.Id}|ConvertTo-Json -Compress))
""".replace('PYTHON_EXE', sys.executable.replace("'", "''")).replace('CHILD_FILE', str(child).replace("'", "''"))
        (self.data / 'WarpNetwork.ps1').write_text(shell, encoding='utf-8-sig')
        started = time.monotonic()
        response = self.manager.run_network('Start')
        elapsed = time.monotonic() - started
        # Wait for only this test child before deleting its inherited log files.
        import ctypes
        from ctypes import wintypes as t
        kernel = ctypes.WinDLL('kernel32', use_last_error=True)
        kernel.OpenProcess.argtypes = [t.DWORD, t.BOOL, t.DWORD]
        kernel.OpenProcess.restype = t.HANDLE
        kernel.WaitForSingleObject.argtypes = [t.HANDLE, t.DWORD]
        kernel.CloseHandle.argtypes = [t.HANDLE]
        handle = kernel.OpenProcess(0x00100000, False, response['childId'])
        if handle:
            try:
                self.assertEqual(kernel.WaitForSingleObject(handle, 6500), 0)
            finally:
                kernel.CloseHandle(handle)
        self.assertLess(elapsed, 4.5, 'Inherited core output must not hold up the completed worker')


class Bootstrap(unittest.TestCase):
    def proxy(self):
        return {'type': 'wireguard', 'private-key': base64.b64encode(b'a' * 32).decode(), 'ip': '172.16.0.2',
                'peers': [dict(server='162.159.192.1', port=4500, **{'public-key': base64.b64encode(b'b' * 32).decode()})],
                'amnezia-wg-option': dict(jc=6, jmin=10, jmax=50, s1=0, s2=0, h1=1, h2=2, h3=3, h4=4, i1='<r 2><b 0x8580>')}

    def test_unrelated_proxy_settings_are_not_imported(self):
        value = self.proxy()
        value.update({'interface-name': 'Happ', 'dialer-proxy': 'evil', 'plugin': 'cmd.exe'})
        clean = p.make_proxy([value])
        self.assertNotIn('plugin', clean)
        self.assertNotIn('dialer-proxy', clean)
        self.assertNotIn('interface-name', clean)
        self.assertEqual(clean['mtu'], 1280)

    def test_non_cloudflare_endpoints_are_rejected(self):
        value = self.proxy()
        value['peers'][0]['server'] = '127.0.0.1'
        with self.assertRaises(ValueError):
            p.make_proxy(value)

    def test_packet_size_and_dsl_are_bounded(self):
        for packet in ['<r 999999>', '<r 0>', '<exec cmd.exe>', '<b 0x123>', 'x<r 2>']:
            with self.subTest(packet=packet), self.assertRaises(ValueError):
                p.literal_packet(packet)

    def test_retry_backoff_is_bounded(self):
        self.assertEqual([w.retry_delay(i) for i in range(8)], [5, 10, 20, 40, 80, 160, 300, 300])


if __name__ == '__main__':
    unittest.main()
