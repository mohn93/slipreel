#!/usr/bin/env python3
import importlib.util
import shutil
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("sync_site_release", ROOT / "scripts" / "sync-site-release.py")
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader
SPEC.loader.exec_module(MODULE)


class SyncSiteReleaseTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.site = Path(self.temp.name) / "site"
        shutil.copytree(ROOT / "site", self.site)
        self.appcast = Path(self.temp.name) / "appcast.xml"
        self.appcast.write_text(
            """<?xml version="1.0"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>
  <item><pubDate>Sun, 20 Sep 2026 08:00:00 +0000</pubDate>
    <sparkle:version>1000018</sparkle:version><sparkle:shortVersionString>1.0.18</sparkle:shortVersionString>
    <enclosure url="https://slipreel.app/download/Slipreel-1.0.18.dmg" length="162445955" />
  </item>
</channel></rss>"""
        )
        index = self.site / "index.html"
        index.write_text(index.read_text().replace("v1.0.18 · 162 MB", "v1.0.18 · 155 MB"))

    def tearDown(self):
        self.temp.cleanup()

    def test_syncs_crawler_visible_release_facts(self):
        release = MODULE.latest_release(self.appcast)
        changed = MODULE.synchronize(self.site, release)
        self.assertEqual(
            {path.name for path in changed},
            {"index.html", "downloads.html", "changelog.html", "llms.txt"},
        )
        self.assertIn("v1.0.18 · 162 MB", (self.site / "index.html").read_text())
        self.assertIn("Slipreel 1.0.18 (20 September 2026)", (self.site / "downloads.html").read_text())
        self.assertIn("Current release: Slipreel 1.0.18", (self.site / "llms.txt").read_text())
        changelog = (self.site / "changelog.html").read_text()
        self.assertEqual(changelog.count("Latest release"), 1)
        self.assertIn('<time datetime="2026-09-20">20 September 2026</time>', changelog)

    def test_requires_matching_changelog_entry(self):
        source = self.appcast.read_text().replace("1.0.18", "9.9.9").replace("1000018", "9999999")
        self.appcast.write_text(source)
        with self.assertRaisesRegex(ValueError, "changelog release 9.9.9"):
            MODULE.synchronize(self.site, MODULE.latest_release(self.appcast))

    def test_next_release_updates_changelog_and_site_fallbacks(self):
        source = self.appcast.read_text().replace("1.0.18", "1.0.19").replace("1000018", "1000019")
        self.appcast.write_text(source)
        MODULE.synchronize(self.site, MODULE.latest_release(self.appcast))

        changelog = (self.site / "changelog.html").read_text()
        self.assertEqual(changelog.count("Latest release"), 1)
        self.assertIn(
            '<h2 id="release-1-0-19">1.0.19</h2>\n              <span class="support-badge">Latest release</span>',
            changelog,
        )
        self.assertIn('<time datetime="2026-09-20">20 September 2026</time>', changelog)
        self.assertIn("v1.0.19", (self.site / "index.html").read_text())
        self.assertIn("Slipreel 1.0.19", (self.site / "downloads.html").read_text())


if __name__ == "__main__":
    unittest.main(verbosity=2)
