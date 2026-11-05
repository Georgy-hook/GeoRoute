"""Inspect the exact portable app artifact produced and tested in this workflow."""
import hashlib
import io
from pathlib import Path
import os
import zipfile

import scan_virustotal_release as audit

root = Path('client-candidate')
archives = list(root.glob('*.zip'))
if len(archives) != 1:
    raise RuntimeError('Expected exactly one client build artifact')
path = archives[0]
content = path.read_bytes()
digest = hashlib.sha256(content).hexdigest()
if digest != path.with_suffix(path.suffix + '.sha256').read_text(encoding='utf-8-sig').split()[0]:
    raise RuntimeError('Client does not match the build manifest')
with zipfile.ZipFile(io.BytesIO(content)) as archive:
    members = {item.filename.replace('\\', '/'): item for item in archive.infolist()}
    if len(members) != len(archive.infolist()):
        raise RuntimeError('Ambiguous client entries')
    selected = [(path.name, content)]
    for name in ['GeoRoute.cmd', '_service/NextDNS-GUI.ps1', '_service/AppInstance.ps1', '_service/bridge/bridge.py', '_service/bridge/python/python.exe']:
        selected.append((name, archive.read(members['GeoRoute/' + name])))
audit.save('candidate-manifest.json', {'source_commit': os.environ['GITHUB_SHA'],
           'purpose': 'Script-based WPF GUI and direct SCM bridge, tested portable app artifact',
           'files': [{'name': name, 'sha256': hashlib.sha256(data).hexdigest(), 'size': len(data)}
                     for name, data in selected]})
audit.audit_files(selected)
