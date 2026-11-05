"""Audit public release bytes; never execute them or rebuild the inspected files.

VTAI is VirusTotal's official agent endpoint. A first token is encrypted to an
owner-supplied public key; only ciphertext is included in the public artifact.
Later runs reuse the repository secret. Uncertain uploads are recovered by hash,
never automatically repeated. Results remain evidence, not a safety certificate.
"""
import hashlib
import io
import json
import os
from pathlib import Path
import re
import subprocess
import time
from datetime import datetime, timezone
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen
import zipfile

BASE = 'https://ai.virustotal.com'
OUT = Path('scan-results')
OUT.mkdir(exist_ok=True)
TOKEN = os.environ.get('VTAI_TOKEN', '').strip()


def save(name, data):
    (OUT / name).write_text(json.dumps(data, indent=2, ensure_ascii=False), encoding='utf-8')


def fetch(url, *, method='GET', data=None, headers=None, timeout=60):
    request = Request(url, data=data, method=method, headers={'User-Agent': 'GeoRoute-release-audit/1.0', **(headers or {})})
    try:
        with urlopen(request, timeout=timeout) as response:
            return response.status, response.read()
    except HTTPError as error:
        return error.code, error.read()


def api(path, *, method='GET', data=None, content_type=None, consent=False):
    headers = {'Authorization': 'Bearer ' + TOKEN}
    if content_type:
        headers['Content-Type'] = content_type
    if consent:
        headers['X-VTAI-Consent'] = 'standard-v1'
    status, body = fetch(BASE + path, method=method, data=data, headers=headers, timeout=120)
    try:
        result = json.loads(body)
    except ValueError:
        raise RuntimeError(f'VTAI returned non-JSON HTTP {status} for {path}') from None
    return status, result


def bootstrap():
    global TOKEN
    if TOKEN:
        print('::add-mask::' + TOKEN)
        return
    public_key = os.environ.get('VTAI_BOOTSTRAP_PUBLIC_KEY', '').strip()
    if not public_key:
        raise RuntimeError('Configure VTAI_AGENT_TOKEN or an owner-controlled bootstrap public key')
    public_path = OUT / 'bootstrap-public.pem'
    public_path.write_text(public_key + '\n', encoding='ascii')
    status, body = fetch(BASE + '/api/v3/agents/register', method='POST',
                         headers={'Content-Type': 'application/json'},
                         data=json.dumps({'agent_family': 'georoute_release_audit', 'agent_version': '1.0',
                                          'display_name': 'GeoRoute release audit'}).encode())
    if status != 200:
        raise RuntimeError(f'VTAI registration returned HTTP {status}; do not repeat registration automatically')
    identity = json.loads(body)
    TOKEN = identity['agent_token']
    print('::add-mask::' + TOKEN)
    # Token never enters argv, logs, plain artifacts, or the repository.
    subprocess.run(['openssl', 'pkeyutl', '-encrypt', '-pubin', '-inkey', str(public_path),
                    '-pkeyopt', 'rsa_padding_mode:oaep', '-pkeyopt', 'rsa_oaep_md:sha256',
                    '-out', str(OUT / 'agent-token.encrypted')], input=TOKEN.encode(), check=True)
    save('bootstrap-identity.json', {'agent_id': identity.get('agent_id'),
                                    'created_at': datetime.now(timezone.utc).isoformat()})
    print('Registered one scan identity; retain its encrypted credential for future runs')


def analysis_status(data):
    if isinstance(data, dict):
        if data.get('status') in ('queued', 'in-progress', 'pending', 'completed', 'finished'):
            return data['status']
        for value in data.values():
            if isinstance(value, dict):
                status = analysis_status(value)
                if status:
                    return status
    return None


def analysis_id(data):
    if isinstance(data, dict):
        if data.get('analysis_id'):
            return data['analysis_id']
        if data.get('type') == 'analysis' and data.get('id'):
            return data['id']
        for value in data.values():
            if isinstance(value, dict):
                found = analysis_id(value)
                if found:
                    return found
    return None


def main():
    tag = os.environ.get('RELEASE_TAG', 'v0.4.0')
    repo = os.environ.get('GITHUB_REPOSITORY', 'Georgy-hook/GeoRoute')
    if not re.fullmatch(r'v\d+\.\d+\.\d+', tag) or repo != 'Georgy-hook/GeoRoute':
        raise RuntimeError('Expected an explicit GeoRoute release tag in its own repository')
    github_headers = {'Authorization': 'Bearer ' + os.environ['GITHUB_TOKEN']} if os.environ.get('GITHUB_TOKEN') else {}
    status, raw = fetch(f'https://api.github.com/repos/{repo}/releases/tags/{tag}', headers=github_headers)
    if status != 200:
        raise RuntimeError(f'Release metadata returned HTTP {status}')
    release = json.loads(raw)
    filename = 'GeoRoute-Windows-x64-' + tag[1:] + '.zip'
    asset = next(a for a in release['assets'] if a['name'] == filename)
    status, archive = fetch(asset['browser_download_url'], timeout=90)
    sha256 = hashlib.sha256(archive).hexdigest()
    if status != 200 or asset.get('digest') != 'sha256:' + sha256:
        raise RuntimeError('Downloaded bytes do not match the published GitHub asset digest')
    with zipfile.ZipFile(io.BytesIO(archive)) as package:
        selected = [(filename, archive)] + [(path, package.read('GeoRoute/' + path)) for path in
                    ('GeoRoute.exe', '_service/bridge/NextDNSBridge.exe', '_service/bridge/python/python.exe')]
    save('release-manifest.json', {'tag': tag, 'release_url': release['html_url'],
                                  'download_url': asset['browser_download_url'], 'zip_sha256': sha256,
                                  'files': [{'name': name, 'size': len(data), 'sha256': hashlib.sha256(data).hexdigest()}
                                            for name, data in selected]})
    # Capture the actual official response schema with the scan evidence.
    status, schema = fetch(BASE + '/openapi.json')
    if status != 200:
        raise RuntimeError(f'Official VTAI schema returned HTTP {status}')
    (OUT / 'vtai-openapi.json').write_bytes(schema)
    bootstrap()
    status, access = api('/api/v3/agents/me/access')
    if status != 200:
        raise RuntimeError(f'VTAI access check returned HTTP {status}')
    save('access.json', access)
    pending = {}
    results = []
    for number, (name, content) in enumerate(selected):
        digest = hashlib.sha256(content).hexdigest()
        record = {'name': name, 'sha256': digest, 'size': len(content),
                  'report_url': 'https://www.virustotal.com/gui/file/' + digest + '/detection'}
        status, report = api('/api/v3/files/' + digest)
        save(f'{number}-lookup.json', {'http_status': status, 'body': report})
        if status == 200:
            record.update(state='existing-report', report=report)
            print(name + ': existing VirusTotal report')
        elif status == 404:
            print(name + ': confirmed unknown; submitting authorized public release bytes')
            # Persist intent before dispatch. Never retry an uncertain POST.
            save(f'{number}-intent.json', record)
            try:
                status, receipt = api('/api/v3/submissions/' + digest, method='POST', data=content,
                                      content_type='application/octet-stream', consent=True)
            except (URLError, TimeoutError):
                status, receipt = api('/api/v3/submissions/' + digest)
            save(f'{number}-receipt.json', {'http_status': status, 'body': receipt})
            record.update(state='submitted', receipt=receipt)
            identifier = analysis_id(receipt)
            if status not in (200, 202) or not identifier:
                # Keep the receipt for recovery rather than creating another submission.
                record['state'] = 'submission-needs-review'
            else:
                pending[number] = identifier
        else:
            record.update(state='lookup-failed', error_http=status)
        results.append(record)
        save('reports.json', results)
    deadline = time.monotonic() + 12 * 60
    while pending and time.monotonic() < deadline:
        time.sleep(30)
        for number, identifier in list(pending.items()):
            status, analysis = api('/api/v3/analyses/' + identifier)
            save(f'{number}-analysis.json', {'http_status': status, 'body': analysis})
            state = analysis_status(analysis)
            print(results[number]['name'] + ': analysis HTTP ' + str(status) + ' / ' + str(state))
            if status == 200 and state in ('completed', 'finished'):
                status, report = api('/api/v3/files/' + results[number]['sha256'])
                results[number].update(state='completed' if status == 200 else 'report-pending', report=report)
                del pending[number]
            elif status not in (200, 202, 404):
                results[number].update(state='analysis-needs-review', analysis_http=status)
                del pending[number]
        save('reports.json', results)
    save('completed.json', {'at': datetime.now(timezone.utc).isoformat(), 'pending': list(pending)})
    if pending or any(r['state'] not in ('existing-report', 'completed') for r in results):
        raise RuntimeError('Some VirusTotal results are incomplete; inspect retained evidence, do not claim clean')
    print('All requested report objects recovered. Review their findings before publishing a verdict.')


if __name__ == '__main__':
    main()
