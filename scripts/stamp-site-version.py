#!/usr/bin/env python3
"""Stamp version, download size and checksum labels from the built app and staged DMG."""
import hashlib
import html
import plistlib
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def stamp(target, app_info):
    with app_info.open("rb") as source:
        version = plistlib.load(source)["CFBundleShortVersionString"]
    dmg = target.parent / "downloads/ELTransfer.dmg"
    size = dmg.stat().st_size
    if size <= 0:
        raise ValueError("Download DMG is empty")
    digest = hashlib.sha256(dmg.read_bytes()).hexdigest()
    # Decimal MB matches Finder's download size, rounded to one decimal place.
    release = {
        "app-version": f"v{version}",
        "download-size": f"{size / 1_000_000:.1f} MB",
        "download-sha256": digest,
    }
    page = target.read_text()
    for name, value in release.items():
        page, count = re.subn(
            rf'(<(?:span|code)\b[^>]*\bdata-{name}(?:="")?[^>]*>)[^<]*(</(?:span|code)>)',
            lambda match: match[1] + html.escape(value) + match[2], page,
        )
        if not count and name == "app-version":
            raise ValueError(f"No data-{name} labels found in {target.name}")
    target.write_text(page)
    print(f"App version: {release['app-version']}; download: {release['download-size']}; sha256: {digest[:12]}…")


if __name__ == "__main__":
    targets = [Path(arg) for arg in sys.argv[1:]] or [ROOT / "website/index.html"]
    for target in targets:
        stamp(target, ROOT / "build/ELTransfer.app/Contents/Info.plist")
