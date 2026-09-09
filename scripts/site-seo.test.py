#!/usr/bin/env python3
"""Check the published content contract: crawl/index signals and schema parity."""
import json
import re
import unittest
from datetime import datetime
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import urljoin, urlsplit, unquote
from xml.etree import ElementTree as ET

SITE = Path(__file__).resolve().parents[1] / 'site'
ORIGIN = 'https://slipreel.app'

class Page(HTMLParser):
    def __init__(self, path):
        super().__init__(convert_charrefs=True)
        self.path = path
        self.meta, self.canonicals, self.links, self.ids = {}, [], [], []
        self.h1 = 0
        self.scripts = []
        self.script = None
        self.title = ''
        self.in_title = False
        self.faqs = []
        self.faq = None
        self.part = None
        self.feed(path.read_text())

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if 'id' in a: self.ids.append(a['id'])
        if tag == 'meta': self.meta[a.get('name', a.get('property'))] = a.get('content')
        if tag == 'link' and a.get('rel') == 'canonical': self.canonicals.append(a['href'])
        if tag == 'a' and 'href' in a: self.links.append(a['href'])
        if tag == 'h1': self.h1 += 1
        if tag == 'title': self.in_title = True
        if tag == 'script' and a.get('type') == 'application/ld+json': self.script = ''
        if tag == 'details' and a.get('class') == 'faq__item': self.faq = {'question': '', 'answer': ''}
        if self.faq is not None:
            if tag == 'summary': self.part = 'question'
            if tag == 'p' and a.get('class') == 'faq__answer': self.part = 'answer'

    def handle_data(self, data):
        if self.in_title: self.title += data
        if self.script is not None: self.script += data
        if self.faq is not None and self.part: self.faq[self.part] += data

    def handle_endtag(self, tag):
        if tag == 'title': self.in_title = False
        if tag == 'script' and self.script is not None:
            self.scripts.append(json.loads(self.script))
            self.script = None
        if self.faq is not None:
            if tag in ('summary', 'p'): self.part = None
            if tag == 'details':
                self.faqs.append({k: ' '.join(v.split()) for k, v in self.faq.items()})
                self.faq = None

    @property
    def nodes(self):
        return [node for script in self.scripts for node in script.get('@graph', [script])]

PAGES = {p.stem: Page(p) for p in SITE.glob('*.html')}
PUBLIC = {name: p for name, p in PAGES.items() if 'noindex' not in p.meta.get('robots', '')}

class SearchContract(unittest.TestCase):
    def test_sitemap_matches_indexable_canonical_pages(self):
        urls = ET.parse(SITE / 'sitemap.xml').findall('{*}url/{*}loc')
        actual = [u.text for u in urls]
        self.assertEqual(len(actual), len(set(actual)))
        self.assertEqual(set(actual), {ORIGIN + ('/' if n == 'index' else '/' + n) for n in PUBLIC})

    def test_public_metadata_and_structure(self):
        titles = set()
        for name, p in PUBLIC.items():
            with self.subTest(page=name):
                url = ORIGIN + ('/' if name == 'index' else '/' + name)
                self.assertEqual(p.canonicals, [url])
                self.assertEqual(p.h1, 1)
                self.assertEqual(len(p.ids), len(set(p.ids)), 'duplicate fragment IDs')
                self.assertTrue(p.title and p.title not in titles)
                titles.add(p.title)
                self.assertTrue(p.meta.get('description'))
                self.assertEqual(p.meta.get('og:url'), url)
                self.assertEqual(p.meta.get('twitter:card'), 'summary_large_image')
                self.assertTrue(p.meta.get('og:image', '').startswith(ORIGIN + '/'))
                self.assertTrue(p.scripts)
                self.assertNotIn('nosnippet', p.meta.get('robots', ''))

    def test_faq_markup_matches_visible_answers(self):
        for name, p in PUBLIC.items():
            for node in p.nodes:
                if node.get('@type') == 'FAQPage':
                    with self.subTest(page=name):
                        actual = [{'question': q['name'], 'answer': q['acceptedAnswer']['text']} for q in node['mainEntity']]
                        self.assertEqual(actual, p.faqs)

    def test_internal_public_links_use_canonicals_and_valid_fragments(self):
        for name, p in PAGES.items():
            for href in p.links:
                u = urlsplit(urljoin(ORIGIN + ('/' if name == 'index' else '/' + name), href))
                if u.netloc != 'slipreel.app': continue
                stem = u.path.strip('/').removesuffix('.html') or 'index'
                if stem not in PUBLIC: continue
                with self.subTest(page=name, href=href):
                    self.assertFalse(u.path.endswith('.html'))
                    if u.fragment: self.assertIn(unquote(u.fragment), PUBLIC[stem].ids)

    def test_credential_routes_remain_noindex_and_analytics_free(self):
        for name in ['login', 'account', 'success', 'cancel', 'pricing']:
            with self.subTest(page=name):
                self.assertIn('noindex', PAGES[name].meta['robots'])
                self.assertNotIn('src="assets/js/analytics.js', PAGES[name].path.read_text())

    def test_video_metadata_has_timezone_and_real_asset_references(self):
        for node in PAGES['index'].nodes:
            if node.get('@type') != 'VideoObject': continue
            with self.subTest(video=node['name']):
                self.assertIsNotNone(datetime.fromisoformat(node['uploadDate'].replace('Z', '+00:00')).tzinfo)
                self.assertRegex(node['duration'], r'^PT[0-9]+(?:\.[0-9]+)?S$')
                for key in ['contentUrl', 'thumbnailUrl']:
                    self.assertTrue(node[key].startswith(ORIGIN + '/'))
                    self.assertTrue((SITE / urlsplit(node[key]).path.lstrip('/')).is_file())

    def test_public_software_offers_have_prices_and_license_terms(self):
        app = next(n for n in PAGES['index'].nodes if n.get('@type') == 'SoftwareApplication')
        self.assertEqual({o['price'] for o in app['offers']}, {'9.00', '69.00'})
        for offer in app['offers']:
            self.assertEqual(offer['@type'], 'Offer')
            self.assertEqual(offer['priceCurrency'], 'USD')
            self.assertEqual(offer['url'], ORIGIN + '/#pricing')
        self.assertIn('14 days', app['offers'][1]['description'])
        llms = (SITE / 'llms.txt').read_text()
        for phrase in ['14 days', 'one year', 'analytics', 'diagnostics', 'update checks', '/privacy']:
            self.assertIn(phrase, llms)
        self.assertNotIn('only network calls', llms.lower())
        self.assertNotIn('forever', llms.lower())

if __name__ == '__main__': unittest.main(verbosity=2)
