#!/usr/bin/env python3
"""Offline guards against reintroducing withdrawn public installers."""
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('archive', Path(__file__).with_name('prepare-download-archive.py'))
archive = importlib.util.module_from_spec(spec)
spec.loader.exec_module(archive)

class ArchivePolicyTest(unittest.TestCase):
    def test_supported_floor_and_future_retention(self):
        for patch_number in range(13):
            self.assertFalse(archive.supported_release(f'1.0.{patch_number}', 1000000 + patch_number))
        self.assertTrue(archive.supported_release('1.0.13', '1000013'))
        self.assertTrue(archive.supported_release('1.1.0', '1001000'))
        self.assertFalse(archive.supported_release('1.0.12', '1000013'))
        self.assertFalse(archive.supported_release('1.0.13', None))

    def test_explicit_withdrawn_request_fails_before_network(self):
        with tempfile.TemporaryDirectory() as tmp, patch('sys.argv', ['archive', '--version', '1.0.12', '--download', '--output', tmp]), patch.object(archive, 'run') as run:
            with self.assertRaises(SystemExit) as result:
                archive.main()
            self.assertEqual(result.exception.code, 2)
            run.assert_not_called()

    def test_cached_legacy_feed_is_not_probed_or_downloaded(self):
        feed = '<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item><sparkle:shortVersionString>1.0.12</sparkle:shortVersionString><sparkle:version>1000012</sparkle:version><enclosure url="https://slipreel.app/download/Slipreel-1.0.12.dmg" /></item></channel></rss>'
        with tempfile.TemporaryDirectory() as tmp, patch('sys.argv', ['archive', '--download', '--output', tmp]), patch.object(archive, 'run', return_value=feed) as run, patch.object(archive.subprocess, 'run') as download:
            archive.main()
            self.assertEqual(run.call_count, 1)  # Fetch feed only; no HEAD or download.
            download.assert_not_called()
            self.assertEqual((Path(tmp) / 'archive-inventory.json').read_text(), '[]\n')

if __name__ == '__main__':
    unittest.main()
