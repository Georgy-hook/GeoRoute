"""Validate a WARP-only proxy export; never accept executable paths or full configs."""
import argparse
import base64
import ipaddress
import json
from pathlib import Path
import re

NETWORKS = tuple(ipaddress.ip_network(v) for v in ('162.159.192.0/21', '188.114.96.0/22', '8.47.69.0/24'))


def key(value):
    if not isinstance(value, str) or len(value) != 44 or len(base64.b64decode(value, validate=True)) != 32:
        raise ValueError('Invalid WireGuard key')
    return value


def literal_packet(value):
    if not isinstance(value, str) or len(value) > 8192:
        raise ValueError('Invalid WARP initialization packet')
    tokens = re.findall(r'<([^<>]+)>', value)
    if ''.join('<' + token + '>' for token in tokens) != value or not tokens:
        raise ValueError('Invalid packet tokens')
    total = 0
    for token in tokens:
        if re.fullmatch(r'r \d{1,2}', token):
            size = int(token[2:])
            if not 1 <= size <= 64:
                raise ValueError('Oversized random packet segment')
            total += size
        elif re.fullmatch(r'b 0x[0-9A-Fa-f]+', token) and len(token[4:]) % 2 == 0:
            total += len(token[4:]) // 2
        else:
            raise ValueError('Unsupported packet token')
    if total > 1280:
        raise ValueError('Oversized initialization packet')
    return value


def make_proxy(value):
    if isinstance(value, dict) and 'proxies' in value:
        value = value['proxies']
    if isinstance(value, list) and len(value) == 1:
        value = value[0]
    if not isinstance(value, dict) or value.get('type') != 'wireguard':
        raise ValueError('A single WARP WireGuard proxy export is required')
    local = ipaddress.ip_address(value['ip'])
    if local.version != 4:
        raise ValueError('An IPv4 WARP address is required')
    peers = value.get('peers')
    if not isinstance(peers, list) or len(peers) != 1:
        raise ValueError('Exactly one WARP peer is required')
    peer = peers[0]
    server = ipaddress.ip_address(peer['server'])
    if server.version != 4 or not any(server in network for network in NETWORKS):
        raise ValueError('Only a Cloudflare WARP endpoint is accepted')
    if type(peer['port']) is not int or not 1 <= peer['port'] <= 65535:
        raise ValueError('Invalid endpoint port')
    awg = value.get('amnezia-wg-option')
    if not isinstance(awg, dict):
        raise ValueError('The tested WARP transport requires AmneziaWG parameters')
    limits = dict(jc=(0, 16), jmin=(0, 128), jmax=(0, 1024), s1=(0, 64), s2=(0, 64),
                  h1=(1, 4294967295), h2=(1, 4294967295), h3=(1, 4294967295), h4=(1, 4294967295))
    clean = {}
    for name, (low, high) in limits.items():
        number = awg.get(name)
        if type(number) is not int or not low <= number <= high:
            raise ValueError('Invalid AmneziaWG numeric parameter')
        clean[name] = number
    if clean['jmin'] > clean['jmax']:
        raise ValueError('Invalid junk range')
    clean['i1'] = literal_packet(awg.get('i1'))
    return {'name': 'WARP-GeoHide', 'type': 'wireguard', 'private-key': key(value['private-key']),
            'ip': str(local), 'peers': [{'server': str(server), 'port': peer['port'],
                                        'public-key': key(peer['public-key']),
                                        'allowed-ips': ['0.0.0.0/0'], 'persistent-keepalive': 25}],
            'amnezia-wg-option': clean, 'udp': True, 'mtu': 1280,
            'persistent-keepalive': 25, 'remote-dns-resolve': True, 'dns': ['1.1.1.1']}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--input', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    try:
        with args.input.open('rb') as stream:
            data = stream.read(131073)
        if len(data) > 131072:
            raise ValueError('Oversized WARP export')
        proxy = make_proxy(json.loads(data.decode('utf-8-sig')))
        args.output.write_text(json.dumps(proxy, indent=2), encoding='utf-8')
    except Exception:
        # A malformed input must never print credentials in a traceback.
        print('WARP profile validation failed')
        return 1
    print('WARP proxy validated')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
