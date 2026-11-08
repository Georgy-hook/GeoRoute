"""Read-only DoH availability checks; never changes Windows DNS or user routes."""
import argparse
import concurrent.futures
import json
import os
from pathlib import Path
import queue
import sys
import time

sys.path.insert(0, str(Path(__file__).resolve().parent))
import selective_dns as dns


def providers(raw, custom=None):
    rows = list(raw['providers'])
    if custom and custom.get('url') and custom['url'] not in {p['url'] for p in rows}:
        rows.append(dict(id='custom', name='Свой DNS', url=custom['url'], servers=custom.get('servers', [])))
    if not 1 <= len(rows) <= 32 or len({p['url'] for p in rows}) != len(rows):
        raise ValueError('DNS provider list is empty, duplicated or too large')
    return rows


def check(provider):
    row = dict(id=provider['id'], name=provider['name'], url=provider['url'],
               state='complete', ready=False, at=dns.bridge.Bridge.now(), servers=[], ms=None, error='')
    try:
        # Only a fixed public test domain is sent to candidate DNS providers.
        result = dns.probe(dict(url=provider['url'], servers=provider.get('servers', []),
                                domains=['example.com'], subdomains=False))
        healthy = sorted((r for r in result.get('rows', []) if r.get('ok')
                          and r.get('rcode') == 0 and r.get('answers', 0) > 0), key=lambda r: r['ms'])
        if healthy:
            row.update(ready=True, ms=healthy[0]['ms'], servers=[r['server'] for r in healthy[:2]])
        else:
            errors = '; '.join(dict.fromkeys(r.get('error', 'Пустой DNS-ответ / NXDOMAIN')
                                            for r in result.get('rows', [])))
            row['error'] = errors[:600] or result.get('error', 'DNS не подтвердил адрес тестового сайта')
    except Exception as exc:
        row['error'] = type(exc).__name__ + ': ' + str(exc)[:300]
    row['at'] = dns.bridge.Bridge.now()
    return row


def run(items, output, run_id):
    report = dict(version=1, runId=run_id, running=True, completed=0, total=len(items),
                  at=dns.bridge.Bridge.now(), rows=[dict(p, ready=False, state='queued', at=None,
                                                        ms=None, error='') for p in items])

    def save():
        temporary = output.with_name(output.name + '.tmp')
        temporary.write_text(json.dumps(report, ensure_ascii=False), encoding='utf-8')
        os.replace(temporary, output)

    save()
    started = queue.Queue()

    def work(index):
        started.put(index)
        return check(items[index])

    with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
        pending = {pool.submit(work, i): i for i in range(len(items))}
        while pending:
            changed = False
            while not started.empty():
                index = started.get_nowait()
                report['rows'][index]['state'] = 'checking'
                changed = True
            for future, index in list(pending.items()):
                if future.done():
                    report['rows'][index] = future.result()
                    del pending[future]
                    report['completed'] += 1
                    changed = True
            if changed:
                save()
            if pending:
                time.sleep(.1)
    report.update(running=False, at=dns.bridge.Bridge.now())
    save()
    return report


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--providers', required=True)
    parser.add_argument('--custom')
    parser.add_argument('--output', required=True)
    parser.add_argument('--run-id', required=True)
    args = parser.parse_args()
    raw = json.loads(Path(args.providers).read_text(encoding='utf-8-sig'))
    custom = json.loads(Path(args.custom).read_text(encoding='utf-8-sig')) if args.custom else None
    run(providers(raw, custom), Path(args.output), args.run_id)


if __name__ == '__main__':
    main()
