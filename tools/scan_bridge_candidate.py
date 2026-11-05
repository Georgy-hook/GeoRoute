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
    name = 'NextDNSBridge.exe'
    content = (root / name).read_bytes()
    if not 1024 <= len(content) <= 1024 * 1024:
        raise RuntimeError('Unexpected bridge candidate size')
    if hashlib.sha256(content).hexdigest() != manifest['sha256']:
        raise RuntimeError('Candidate does not match the tested build artifact')
    audit.save('candidate-manifest.json', manifest)
    audit.audit_files([(name, content)])


if __name__ == '__main__':
    main()
