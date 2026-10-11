#!/usr/bin/env python3
"""Validate generated pages, navigation links, and the docs search index."""

from html.parser import HTMLParser
from pathlib import Path
import json
from urllib.parse import urlsplit, unquote

DIST = Path(__file__).parent / "dist"


class Links(HTMLParser):
    def __init__(self):
        super().__init__()
        self.links = []
        self.ids = set()

    def handle_starttag(self, tag, attrs):
        values = dict(attrs)
        if values.get('id'):
            self.ids.add(values['id'])
        for name in ('href', 'src'):
            if values.get(name):
                self.links.append(values[name])


def target(path):
    relative = unquote(path).lstrip('/')
    candidate = DIST / relative
    return candidate / 'index.html' if path.endswith('/') else candidate


def main():
    pages = list(DIST.rglob('*.html'))
    assert len(pages) == 14, f'expected homepage plus 13 guides, found {len(pages)}'
    errors = []
    for page in pages:
        source = page.read_text(encoding='utf-8')
        if '{{' in source:
            errors.append(f'{page}: unrendered template token')
        parsed = Links()
        parsed.feed(source)
        if 'main' not in parsed.ids:
            errors.append(f'{page}: missing main landmark')
        for link in parsed.links:
            url = urlsplit(link)
            if url.scheme or url.netloc:
                continue
            destination = page if not url.path else target(url.path) if url.path.startswith('/') else (page.parent / url.path)
            if not destination.is_file():
                errors.append(f'{page}: broken link {link}')
            elif url.fragment:
                other = Links()
                other.feed(destination.read_text(encoding='utf-8'))
                if url.fragment not in other.ids:
                    errors.append(f'{page}: missing anchor {link}')
    search = json.loads((DIST / 'assets/search.json').read_text(encoding='utf-8'))
    if len(search) != 13:
        errors.append('search index does not contain all guides')
    if errors:
        raise SystemExit('\n'.join(errors))
    print(f'Validated {len(pages)} pages, internal links, anchors, and docs search index')


if __name__ == '__main__':
    main()
