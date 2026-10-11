#!/usr/bin/env python3
"""Build Zurafa's static product site and documentation without dependencies."""

from pathlib import Path
import html
import json
import re
import shutil

ROOT = Path(__file__).parent
DIST = ROOT / "dist"
ORIGIN = "https://zurafa.rare-haven-5290.chatgpt.site"
GROUPS = [
    ("Start here", [("overview", "Overview"), ("install", "Install on macOS"), ("quickstart", "Quick start")]),
    ("Workspace", [("sessions", "Sessions, tabs & panes"), ("shortcuts", "Commands & shortcuts"), ("ssh", "Remote SSH")]),
    ("Personalization", [("appearance", "Appearance & Ghostty"), ("backgrounds", "Dithered backgrounds"), ("status", "Program status")]),
    ("Reference", [("architecture", "Architecture & events"), ("ipc-reference", "IPC protocol"), ("build", "Build from source"), ("troubleshooting", "Troubleshooting & limits")]),
]
PAGES = [(slug, title, group) for group, items in GROUPS for slug, title in items]


def inline(text):
    text = html.escape(text)
    text = re.sub(r"\[([^\]]+)\]\((https?://[^\s)]+|/[^\s)]+)\)", r'<a href="\2">\1</a>', text)
    text = re.sub(r"`([^`]+)`", r"<code>\1</code>", text)
    text = re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", text)
    return text


def markdown(source):
    out, paragraph, code, headings = [], [], [], []
    listing = None
    fenced = False

    def flush():
        if paragraph:
            out.append("<p>" + inline(" ".join(paragraph)) + "</p>")
            paragraph.clear()

    def end_list():
        nonlocal listing
        if listing:
            out.append(f"</{listing}>")
            listing = None

    lines = source.splitlines()
    i = 0
    while i < len(lines):
        line = lines[i].strip()
        if line.startswith("```"):
            flush(); end_list()
            if fenced:
                out.append("<pre><code>" + html.escape("\n".join(code)) + "</code></pre>")
                code.clear()
            fenced = not fenced
            i += 1
            continue
        if fenced:
            code.append(lines[i]); i += 1; continue
        if not line:
            flush(); end_list(); i += 1; continue
        heading = re.match(r"^(#{1,4})\s+(.+)$", line)
        if heading:
            flush(); end_list()
            if len(heading.group(1)) == 1 and not out:
                i += 1
                continue  # The page template already supplies the h1.
            level = len(heading.group(1))
            label = heading.group(2)
            slug = re.sub(r"[^a-z0-9]+", "-", label.lower()).strip("-")
            headings.append((slug, label))
            out.append(f'<h{level} id="{slug}">{inline(label)}</h{level}>')
            i += 1; continue
        if line.startswith("|") and i + 1 < len(lines) and re.match(r"^\|?\s*:?-{2,}", lines[i + 1]):
            flush(); end_list()
            rows = [line]; i += 2
            while i < len(lines) and lines[i].strip().startswith("|"):
                rows.append(lines[i].strip()); i += 1
            out.append('<div class="table-scroll"><table>')
            for n, row in enumerate(rows):
                tag = 'th' if n == 0 else 'td'
                out.append('<tr>' + ''.join(f'<{tag}>{inline(cell.strip())}</{tag}>' for cell in row.strip('|').split('|')) + '</tr>')
            out.append('</table></div>'); continue
        item = re.match(r"^(-|\*|\d+\.)\s+(.+)$", line)
        if item:
            flush()
            kind = 'ol' if item.group(1)[0].isdigit() else 'ul'
            if listing != kind:
                end_list(); out.append(f'<{kind}>'); listing = kind
            out.append('<li>' + inline(item.group(2)) + '</li>')
            i += 1; continue
        if line.startswith('>'):
            flush(); end_list()
            out.append('<aside class="note">' + inline(line.lstrip('> ')) + '</aside>')
            i += 1; continue
        paragraph.append(line); i += 1
    flush(); end_list()
    return '\n'.join(out), headings


def main():
    DIST.mkdir(exist_ok=True)
    (DIST / 'assets').mkdir(exist_ok=True)
    for name in ('style.css', 'site.js', 'zurafa-icon.png'):
        shutil.copy2(ROOT / 'assets' / name, DIST / 'assets' / name)
    (DIST / 'index.html').write_text((ROOT / 'home.html').read_text(), encoding='utf-8')
    template = (ROOT / 'docs-template.html').read_text()
    nav = []
    for group, items in GROUPS:
        nav.append('<div class="nav-group"><p>' + html.escape(group) + '</p>')
        for slug, title in items:
            href = '/docs/' if slug == 'overview' else f'/docs/{slug}/'
            nav.append(f'<a href="{href}" data-page="{slug}">{html.escape(title)}</a>')
        nav.append('</div>')
    search = []
    for index, (slug, title, group) in enumerate(PAGES):
        source = (ROOT / 'docs-src' / (slug + '.md')).read_text(encoding='utf-8')
        summary = next((line.strip() for line in source.splitlines() if line.strip() and not line.startswith('#')), '')
        body, headings = markdown(source)
        toc = ''.join(f'<a href="#{key}">{html.escape(label)}</a>' for key, label in headings)
        prev = PAGES[index - 1] if index else None
        next_page = PAGES[index + 1] if index + 1 < len(PAGES) else None
        adjacent = '<nav class="page-adjacent" aria-label="More documentation">'
        if prev:
            href = '/docs/' if prev[0] == 'overview' else f'/docs/{prev[0]}/'
            adjacent += f'<a href="{href}"><small>← Previous</small><strong>{html.escape(prev[1])}</strong></a>'
        if next_page:
            adjacent += f'<a href="/docs/{next_page[0]}/"><small>Next →</small><strong>{html.escape(next_page[1])}</strong></a>'
        adjacent += '</nav>'
        path = '/docs/' if slug == 'overview' else f'/docs/{slug}/'
        page = template.replace('{{TITLE}}', html.escape(title)).replace('{{DESCRIPTION}}', html.escape(summary, quote=True))
        page = page.replace('{{CANONICAL}}', ORIGIN + path).replace('{{GROUP}}', html.escape(group))
        page = page.replace('{{NAV}}', '\n'.join(nav)).replace('{{CURRENT}}', slug)
        page = page.replace('{{BODY}}', body).replace('{{TOC}}', toc).replace('{{ADJACENT}}', adjacent)
        target = DIST / 'docs' / ('' if slug == 'overview' else slug)
        target.mkdir(parents=True, exist_ok=True)
        (target / 'index.html').write_text(page, encoding='utf-8')
        search.append({'title': title, 'group': group, 'url': path, 'text': re.sub(r'[`*#|>]', '', source)[:8000]})
    (DIST / 'assets' / 'search.json').write_text(json.dumps(search, ensure_ascii=False), encoding='utf-8')
    paths = ['/'] + ['/docs/' if slug == 'overview' else f'/docs/{slug}/' for slug, _, _ in PAGES]
    (DIST / 'sitemap.xml').write_text('<?xml version="1.0" encoding="UTF-8"?><urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">' + ''.join(f'<url><loc>{ORIGIN}{path}</loc></url>' for path in paths) + '</urlset>', encoding='utf-8')
    (DIST / 'robots.txt').write_text('User-agent: *\nAllow: /\nSitemap: ' + ORIGIN + '/sitemap.xml\n', encoding='utf-8')
    print(f'Built homepage and {len(PAGES)} documentation pages')


if __name__ == '__main__':
    main()
