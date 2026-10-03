#!/usr/bin/env python3
"""Publishes fresh Spwrite builds into the website repo (SeanOwwa/spwrite.web).

Run by .github/workflows/build.yml after the three apps are built. Given a
checkout of the website and a folder holding the three zips, it:

  1. copies the zips into downloads/ with the site's naming scheme
     (Spwrite-macOS-v1.3.5.zip, Spwrite-Windows-v1.3.5.zip,
     Spwrite-Linux-v1.3.5.zip) and deletes the previous version's zips, so the
     repo does not grow with every release;
  2. updates each platform in update/release.json (version, date, file, size,
     SHA-256); the site's release.js fills download buttons from it;
  3. replaces the old file names and version label written directly in the
     download pages (mac.html, windows.html, linux.html, index.html), which
     are shown before release.js runs and when JavaScript is off.

update/versions.json and the changelog pages are left alone: release notes
are written by hand.

Usage:
  publish_website.py --site PATH --builds PATH --version 1.3.5 [--date "October 3, 2026"]
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import shutil
import sys
from pathlib import Path

# Site platform key -> (name used in the download file, build zip name).
PLATFORMS = {
    "mac": ("macOS", "Spwrite-macos.zip"),
    "windows": ("Windows", "Spwrite-windows.zip"),
    "linux": ("Linux", "Spwrite-linux.zip"),
}

# Pages that write the download file name / version label directly.
PAGES = ("index.html", "mac.html", "windows.html", "linux.html")


def sha256_of(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def today_label() -> str:
    d = dt.date.today()
    return f"{d.strftime('%B')} {d.day}, {d.year}"


def publish(site: Path, builds: Path, version: str, date: str) -> list[str]:
    """Updates the site checkout in place. Returns a summary of changes."""
    manifest_path = site / "update" / "release.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    label = f"Beta v{version}"
    old_label = manifest.get("appVersion")
    downloads = site / "downloads"
    downloads.mkdir(exist_ok=True)

    replacements: dict[str, str] = {}
    summary: list[str] = []

    for key, (os_name, build_name) in PLATFORMS.items():
        build = builds / build_name
        if not build.is_file():
            raise SystemExit(f"Missing build: {build}")
        file_name = f"Spwrite-{os_name}-v{version}.zip"
        entry = manifest.setdefault("platforms", {}).setdefault(key, {})
        old_file_name = entry.get("fileName")

        shutil.copyfile(build, downloads / file_name)
        # Remove this platform's previous zip(s) to keep the Pages repo small.
        for stale in downloads.glob(f"Spwrite-{os_name}-v*.zip"):
            if stale.name != file_name:
                stale.unlink()
                summary.append(f"removed downloads/{stale.name}")

        target = downloads / file_name
        entry.update(
            available=True,
            version=label,
            date=date,
            file=f"downloads/{file_name}",
            fileName=file_name,
            size=target.stat().st_size,
            sha256=sha256_of(target),
        )
        if old_file_name and old_file_name != file_name:
            replacements[old_file_name] = file_name
        summary.append(f"added downloads/{file_name} ({entry['size']:,} bytes)")

    manifest["appVersion"] = label
    if old_label and old_label != label:
        replacements[old_label] = label
    manifest_path.write_text(
        json.dumps(manifest, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
    )
    summary.append(f"updated update/release.json to {label}")

    for page in PAGES:
        path = site / page
        if not path.is_file():
            continue
        text = path.read_text(encoding="utf-8")
        new = text
        for old, repl in replacements.items():
            new = new.replace(old, repl)
        if new != text:
            path.write_text(new, encoding="utf-8")
            summary.append(f"updated {page}")
    return summary


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--site", type=Path, required=True)
    parser.add_argument("--builds", type=Path, required=True)
    parser.add_argument("--version", required=True, help="e.g. 1.3.5")
    parser.add_argument("--date", default=today_label())
    args = parser.parse_args()
    version = args.version.lstrip("v")
    for line in publish(args.site, args.builds, version, args.date):
        print(line)
    return 0


if __name__ == "__main__":
    sys.exit(main())
