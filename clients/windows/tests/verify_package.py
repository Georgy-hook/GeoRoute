"""Check distribution layout, runtime hashes and accidental local state."""
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import sys
import zipfile


def check(path):
    with zipfile.ZipFile(path) as archive:
        assert archive.testzip() is None
        names = archive.namelist()
        assert len(names) == len(set(names))
        required = ['GeoRoute/GeoRoute.cmd', 'GeoRoute/_service/AppInstance.ps1',
                    'GeoRoute/_service/bridge/bridge.py',
                    'GeoRoute/_service/bridge/python/python.exe',
                    'GeoRoute/_service/bridge/python/LICENSE.txt',
                    'GeoRoute/_service/GeoServices.ps1', 'GeoRoute/_service/GeoMonitorState.ps1',
                    'GeoRoute/_service/GeoProbe.ps1',
                    'GeoRoute/_service/ProfileMigration.ps1']
        required += ['GeoRoute/_service/gemini_probe.py', 'GeoRoute/_service/vendor/hashes.json']
        assert all(name in names for name in required)
        dependencies = json.loads(archive.read('GeoRoute/_service/vendor/hashes.json'))
        for name, digest in dependencies.items():
            assert hashlib.sha256(archive.read('GeoRoute/_service/vendor/' + name)).hexdigest() == digest
        assert not any(name.endswith(('/profiles/gemini-eu.hosts', '/profiles/gemini-us.hosts')) for name in names)
        assert not any(name.endswith('/NextDNSBridge.exe') for name in names)
        assert 'GeoRoute/GeoRoute.exe' not in names
        for name in names:
            parts = PurePosixPath(name).parts
            assert parts and parts[0] == 'GeoRoute' and '..' not in parts and '\\' not in name, name
            assert not any(part.lower() in {'backups', 'run-results', '__pycache__', 'bin'} for part in parts), name
            assert not name.lower().endswith(('.log', '.lock', '-state.json', '.pyc')), name
            assert parts[-1].lower() not in {'profile.txt', 'enabled.txt', 'gui-settings.json', 'geohide-settings.json', 'geohide-history.json', 'geohide-monitor.json', 'status.json', 'boot-check.json', 'boot-verified.json'}, name
            if name.endswith('.ps1'):
                assert archive.read(name).startswith(b'\xef\xbb\xbf'), name
            if PurePosixPath(name).suffix.lower() in {'.ps1', '.py', '.cs', '.json', '.txt', '.xaml', '.hosts', '.config'}:
                text = archive.read(name).decode('utf-8-sig')
                assert not re.search(r'[A-Za-z]:[/\\]Users[/\\]|S-1-5-21-\d', text), name
                assert not re.search(r'https://(?:[a-z0-9.-]+\.)?dns\.nextdns\.io/[a-f0-9]{6}\b', text), name
        hashes = json.loads(archive.read('GeoRoute/_service/bridge/runtime-hashes.json'))
        runtime_prefix = 'GeoRoute/_service/bridge/python/'
        runtime_names = {name[len(runtime_prefix):] for name in names if name.startswith(runtime_prefix) and not name.endswith('/')}
        assert runtime_names == set(hashes)
        for name, expected in hashes.items():
            assert hashlib.sha256(archive.read(runtime_prefix + name)).hexdigest() == expected.lower(), name
    print(json.dumps({'archive': Path(path).name, 'files': len(names), 'runtime_files': len(hashes), 'checks': 'passed'}))


if __name__ == '__main__':
    check(sys.argv[1])
