#!/usr/bin/env python3
"""List URL hosts in shipped assets, excluding ordinary anchor navigation."""
from html.parser import HTMLParser
from pathlib import Path
import re
import sys

URL = re.compile(r'https?://[A-Za-z0-9.:-]+')

class Requests(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.parts = []

    def handle_starttag(self, tag, attrs):
        for key, value in attrs:
            if tag == 'a' and key == 'href':
                continue  # A click navigates; it does not load a page dependency.
            if value:
                self.parts.append(value)

    handle_startendtag = handle_starttag

    def handle_data(self, data):
        self.parts.append(data)

hosts = set()
for path in Path(sys.argv[1]).rglob('*'):
    if path.suffix not in ('.html', '.css', '.js') or path.name.endswith('.test.js'):
        continue
    source = path.read_text()
    if path.suffix == '.html':
        parser = Requests()
        parser.feed(source)
        source = '\n'.join(parser.parts)
    hosts.update(URL.findall(source))
print('\n'.join(sorted(hosts)))
