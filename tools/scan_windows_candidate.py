"""Inspect exact tested portable, installer and installed-uninstaller bytes."""
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

setups = list(root.glob('GeoRoute-Setup-*-x64.exe'))
if len(setups) != 1:
    raise RuntimeError('Expected exactly one tested installer')
setup = setups[0]
data = setup.read_bytes()
if hashlib.sha256(data).hexdigest() != setup.with_suffix('.exe.sha256').read_text(encoding='utf-8-sig').split()[0]:
    raise RuntimeError('Installer hash mismatch')
selected.append((setup.name, data))
selected.append(('Installed/unins000.exe', Path('installer-test-evidence/unins000.exe').read_bytes()))
audit.save('candidate-manifest.json', {'source_commit': os.environ['GITHUB_SHA'],
           'purpose': 'Tested portable GUI, ordinary Inno Setup installer and installed uninstaller',
           'files': [{'name': name, 'sha256': hashlib.sha256(data).hexdigest(), 'size': len(data)}
                     for name, data in selected]})
audit.audit_files(selected)
