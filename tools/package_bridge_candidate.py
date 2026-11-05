"""Package only the direct service source and verified CPython runtime for auditing."""
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import zipfile

root = Path('bridge-candidate')
hashes = json.loads((root / 'runtime-hashes.json').read_text(encoding='utf-8'))
members = ['bridge.py', 'runtime-hashes.json']
for name, digest in hashes.items():
    parts = PurePosixPath(name).parts
    if not parts or '..' in parts or PurePosixPath(name).is_absolute() or '\\' in name:
        raise RuntimeError('Invalid runtime member')
    path = root / 'python' / name
    if hashlib.sha256(path.read_bytes()).hexdigest() != digest:
        raise RuntimeError('Runtime differs from its packaging manifest')
    members.append('python/' + name)
bundle = root / 'NextDNSBridge-bundle.zip'
with zipfile.ZipFile(bundle, 'w', zipfile.ZIP_DEFLATED) as archive:
    for name in sorted(members):
        archive.write(root / name, 'NextDNSBridge/' + name)
selected = ['NextDNSBridge-bundle.zip', 'bridge.py', 'python/python.exe']
manifest = {'source_commit': os.environ['GITHUB_SHA'], 'purpose': 'Direct SCM Python service; no native wrapper or child process',
            'scm_scenarios': 4, 'protocol_tests': 13, 'files': []}
for name in selected:
    content = (root / name).read_bytes()
    manifest['files'].append({'name': name, 'sha256': hashlib.sha256(content).hexdigest(), 'size': len(content)})
(root / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n', encoding='utf-8')
print('Packaged direct-service bundle with verified runtime; no profiles or logs included.')
