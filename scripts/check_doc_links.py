#!/usr/bin/env python3
"""Check the local links of the documentation.

    python3 scripts/check_doc_links.py

Reads the Markdown files of the project (README.md, docs/, zxtres/) and the
HTML pages of docs/, and checks every relative link and image:

  * the file or folder it names exists;
  * a #fragment names an id (HTML) or a heading (Markdown, GitHub's slugs);
  * a link in a page of docs/ stays inside docs/, because GitHub Pages serves
    that folder only (links to the rest of the repository use their full
    github.com URL).

External links (http, https, mailto) are not fetched. Exits with 1 and lists
the broken links when there is one."""
import html.parser
import os
import re
import sys
import urllib.parse

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DOCS = os.path.join(ROOT, 'docs')
MARKDOWN = ['README.md', 'docs', 'zxtres/README.md', 'zxtres/SPEC.md']


class Links(html.parser.HTMLParser):
    def __init__(self):
        super().__init__()
        self.links, self.ids = [], set()

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if 'id' in a:
            self.ids.add(a['id'])
        if tag == 'a' and 'name' in a:
            self.ids.add(a['name'])
        for key in ('href', 'src'):
            if key in a and a[key] is not None:
                self.links.append((self.getpos()[0], a[key]))


def slug(heading):
    """GitHub's anchor for a Markdown heading."""
    s = re.sub(r'[`*_]|\[|\]\([^)]*\)', '', heading.strip().lower())
    s = re.sub(r'[^\w\- ]', '', s)
    return s.replace(' ', '-')


_cache = {}


def anchors(path):
    if path not in _cache:
        text = open(path, encoding='utf-8').read()
        if path.endswith('.html'):
            p = Links()
            p.feed(text)
            _cache[path] = p.ids
        elif path.endswith('.md'):
            text = re.sub(r'```.*?```', '', text, flags=re.S)
            _cache[path] = {slug(h) for h in re.findall(r'^#{1,6}\s+(.*)$', text, flags=re.M)}
        else:
            _cache[path] = None
    return _cache[path]


def markdown_links(path):
    text = open(path, encoding='utf-8').read()
    out = []
    for n, line in enumerate(text.splitlines(), 1):
        for m in re.finditer(r'!?\[[^\]]*\]\(([^)\s]+)(?:\s+"[^"]*")?\)', line):
            out.append((n, m.group(1)))
        for m in re.finditer(r'<(https?://[^>]+)>', line):
            out.append((n, m.group(1)))
    # fenced code holds no links
    return out


def files():
    for entry in MARKDOWN:
        p = os.path.join(ROOT, entry)
        if os.path.isdir(p):
            for dirpath, _, names in os.walk(p):
                for name in sorted(names):
                    if name.endswith(('.md', '.html')):
                        yield os.path.join(dirpath, name)
        elif os.path.exists(p):
            yield p


def main():
    errors, checked = [], 0
    for path in files():
        rel = os.path.relpath(path, ROOT).replace(os.sep, '/')
        if path.endswith('.html'):
            p = Links()
            p.feed(open(path, encoding='utf-8').read())
            links = p.links
        else:
            links = markdown_links(path)
        for line, url in links:
            if re.match(r'^(https?:|mailto:|data:|javascript:)', url):
                continue
            checked += 1
            target, _, frag = url.partition('#')
            target = urllib.parse.unquote(target)
            dest = os.path.normpath(os.path.join(os.path.dirname(path), target)) if target else path
            where = f'{rel}:{line}: {url}'
            if not os.path.exists(dest):
                errors.append(f'{where}: {os.path.relpath(dest, ROOT)} does not exist')
                continue
            if path.endswith('.html') and path.startswith(DOCS + os.sep) and \
                    not (dest == DOCS or dest.startswith(DOCS + os.sep)):
                errors.append(f'{where}: leaves docs/, which GitHub Pages does not serve')
            if os.path.isdir(dest) and path.endswith('.html'):
                if not os.path.exists(os.path.join(dest, 'index.html')):
                    errors.append(f'{where}: a folder with no index.html')
            if frag and os.path.isfile(dest):
                ids = anchors(dest)
                if ids is not None and frag not in ids:
                    errors.append(f'{where}: no anchor #{frag} in {os.path.relpath(dest, ROOT)}')
    for e in errors:
        print(e)
    print(f'{checked} local links checked, {len(errors)} broken')
    return 1 if errors else 0


if __name__ == '__main__':
    sys.exit(main())
