"""Inspect a tested, same-run Bridge build. Never publish a release or install it."""
import hashlib
import json
import os
from pathlib import Path

import scan_virustotal_release as audit


def main():
    root = Path('bridge-candidate')
    manifest = json.loads((root / 'manifest.json').read_text(encoding='utf-8-sig'))
    if manifest['source_commit'] != os.environ['GITHUB_SHA']:
        raise RuntimeError('Candidate belongs to a different source revision')
    expected = {'NextDNSBridge-bundle.zip', 'bridge.py', 'python/python.exe'}
    if {item['name'] for item in manifest['files']} != expected or len(manifest['files']) != len(expected):
        raise RuntimeError('Unexpected candidate contents')
    selected = []
    for item in manifest['files']:
        content = (root / item['name']).read_bytes()
        if not 1024 <= len(content) <= 32000000 or len(content) != item['size']:
            raise RuntimeError('Unexpected candidate size')
        if hashlib.sha256(content).hexdigest() != item['sha256']:
            raise RuntimeError('Candidate does not match the tested build artifact')
        selected.append((item['name'], content))
    audit.save('candidate-manifest.json', manifest)
    audit.audit_files(selected)


if __name__ == '__main__':
    main()
