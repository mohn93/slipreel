#!/usr/bin/env python3
"""Synchronize crawler-visible release facts from a Sparkle appcast."""

from __future__ import annotations

import argparse
import re
from datetime import datetime
from email.utils import parsedate_to_datetime
from pathlib import Path
from xml.etree import ElementTree as ET


SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ORIGIN = "https://slipreel.app"


def latest_release(appcast: Path) -> dict[str, object]:
    root = ET.parse(appcast).getroot()
    releases = []
    for item in root.findall("./channel/item"):
        version = item.findtext(f"{{{SPARKLE}}}shortVersionString")
        build = item.findtext(f"{{{SPARKLE}}}version")
        published = item.findtext("pubDate")
        enclosure = item.find("enclosure")
        if not version or not build or not build.isdecimal() or not published or enclosure is None:
            continue
        length = enclosure.get("length")
        if not length or not length.isdecimal():
            continue
        releases.append(
            {
                "version": version,
                "build": int(build),
                "published": parsedate_to_datetime(published),
                "bytes": int(length),
            }
        )
    if not releases:
        raise ValueError("appcast has no complete release items")
    return max(releases, key=lambda release: release["build"])


def replace_once(source: str, pattern: str, replacement: str, label: str) -> str:
    updated, count = re.subn(pattern, replacement, source, count=1, flags=re.DOTALL)
    if count != 1:
        raise ValueError(f"could not uniquely update {label}")
    return updated


def update_sitemap(source: str, urls: set[str], date: str) -> str:
    for url in urls:
        escaped = re.escape(url)
        pattern = rf"(<loc>{escaped}</loc>\s*<lastmod>)([^<]+)(</lastmod>)"
        match = re.search(pattern, source, flags=re.DOTALL)
        if not match:
            raise ValueError(f"could not uniquely update sitemap {url}")
        effective_date = max(match.group(2), date)
        source = replace_once(source, pattern, rf"\g<1>{effective_date}\g<3>", f"sitemap {url}")
    return source


def synchronize(site: Path, release: dict[str, object]) -> list[Path]:
    version = str(release["version"])
    published = release["published"]
    assert isinstance(published, datetime)
    iso_date = published.date().isoformat()
    display_date = f"{published.day} {published.strftime('%B %Y')}"
    size_mb = round(int(release["bytes"]) / 1_000_000)

    files = {
        name: (site / name).read_text()
        for name in ["index.html", "downloads.html", "changelog.html", "llms.txt", "sitemap.xml"]
    }

    files["index.html"] = replace_once(
        files["index.html"],
        r"(<span data-version-badge>).*?(</span>)",
        rf"\g<1>Free download · v{version} · {size_mb} MB\g<2>",
        "homepage release badge",
    )
    files["downloads.html"] = replace_once(
        files["downloads.html"],
        r"The latest signed release is Slipreel [0-9.]+ \([^)]+\)\.",
        f"The latest signed release is Slipreel {version} ({display_date}).",
        "downloads fallback",
    )

    changelog = re.sub(r"\s*<span class=\"support-badge\">Latest release</span>", "", files["changelog.html"])
    heading = rf'(<h2 id="release-{re.escape(version.replace(".", "-"))}">{re.escape(version)}</h2>)'
    changelog = replace_once(
        changelog,
        heading,
        rf'\g<1>\n              <span class="support-badge">Latest release</span>',
        f"changelog release {version}",
    )
    article_pattern = (
        rf'(<article class="release-entry" aria-labelledby="release-{re.escape(version.replace(".", "-"))}">.*?)'
        r'<time datetime="[^"]+">[^<]+</time>'
    )
    changelog = replace_once(
        changelog,
        article_pattern,
        rf'\g<1><time datetime="{iso_date}">{display_date}</time>',
        f"changelog date {version}",
    )
    files["changelog.html"] = changelog

    release_line = (
        f"Current release: Slipreel {version}, published {display_date}. "
        "The direct download is signed with an Apple Developer ID and notarized by Apple."
    )
    if re.search(r"^Current release:.*$", files["llms.txt"], flags=re.MULTILINE):
        files["llms.txt"] = re.sub(
            r"^Current release:.*$", release_line, files["llms.txt"], count=1, flags=re.MULTILINE
        )
    else:
        files["llms.txt"] = replace_once(
            files["llms.txt"],
            r"(\A# Slipreel\n\n> [^\n]+)",
            rf"\g<1>\n\n{release_line}",
            "llms release fact",
        )

    files["sitemap.xml"] = update_sitemap(
        files["sitemap.xml"],
        {f"{ORIGIN}/", f"{ORIGIN}/downloads", f"{ORIGIN}/changelog"},
        iso_date,
    )

    changed = []
    for name, content in files.items():
        path = site / name
        if path.read_text() != content:
            path.write_text(content)
            changed.append(path)
    return changed


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--appcast", type=Path, required=True)
    parser.add_argument("--site", type=Path, default=Path(__file__).resolve().parents[1] / "site")
    args = parser.parse_args()
    release = latest_release(args.appcast)
    changed = synchronize(args.site, release)
    print(
        f"sync-site-release: {release['version']} ({release['build']}) -> "
        + (", ".join(path.name for path in changed) if changed else "already synchronized")
    )


if __name__ == "__main__":
    main()
