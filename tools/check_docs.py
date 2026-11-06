"""Check tracked Markdown links, images and local heading anchors without network."""
from collections import Counter
from html import unescape
from html.parser import HTMLParser
from pathlib import Path
import re
import subprocess
from urllib.parse import unquote, urlsplit

ROOT = Path(__file__).resolve().parents[1]


def prose(text):
    return re.sub(r'(?ms)^\s*(```|~~~).*?^\s*\1\s*$', '', text)


class References(HTMLParser):
    def __init__(self):
        super().__init__()
        self.links = []
        self.anchors = set()

    def handle_starttag(self, tag, attrs):
        values = dict(attrs)
        for key in ('href', 'src'):
            if values.get(key):
                self.links.append(values[key])
        for key in ('id', 'name'):
            if values.get(key):
                self.anchors.add(values[key])


def anchors(text):
    html = References()
    html.feed(text)
    result = html.anchors
    counts = Counter()
    for title in re.findall(r'(?m)^#{1,6}\s+(.+?)\s*#*$', prose(text)):
        title = unescape(re.sub(r'<[^>]*>', '', title)).lower()
        title = re.sub(r'[^\w\-\s]', '', title)
        slug = re.sub(r'\s', '-', title.strip())
        number = counts[slug]
        counts[slug] += 1
        result.add(slug + (f'-{number}' if number else ''))
    return result


def main():
    files = subprocess.check_output(['git', 'ls-files', '-z'], cwd=ROOT).decode().split('\0')
    errors, checked = [], 0
    documents = [ROOT / name for name in files if name.lower().endswith('.md') and (ROOT / name).is_file()]
    for path in documents:
        text = prose(path.read_text(encoding='utf-8-sig'))
        html = References()
        html.feed(text)
        links = html.links + [m.group(1) or m.group(2) for m in re.finditer(r'\]\(\s*(?:<([^>]+)>|([^\s)]+))(?:\s+"[^"]*")?\s*\)', text)]
        links += re.findall(r'(?m)^\s*\[[^\]]+\]:\s*(\S+)', text)
        for link in links:
            value = urlsplit(unescape(link))
            if value.scheme or value.netloc:
                continue
            target = (path.parent / unquote(value.path)).resolve() if value.path else path
            checked += 1
            if not target.is_relative_to(ROOT) or not target.exists():
                errors.append(f'{path.relative_to(ROOT)}: missing target {link}')
            elif value.fragment and target.suffix.lower() == '.md':
                if unquote(value.fragment) not in anchors(target.read_text(encoding='utf-8-sig')):
                    errors.append(f'{path.relative_to(ROOT)}: missing heading {link}')
    if errors:
        raise SystemExit('\n'.join(errors))
    print(f'Checked {len(documents)} Markdown files and {checked} local links/images/anchors.')


if __name__ == '__main__':
    main()
