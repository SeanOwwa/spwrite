#!/usr/bin/env python3
"""Publishes fresh Spwrite builds into the website repo (SeanOwwa/spwrite.web).

Run by .github/workflows/build.yml after the apps are built. Given a
checkout of the website and a folder holding the five zips, it:

  1. copies the zips into downloads/ with the site's naming scheme
     (Spwrite-macOS-v1.3.5.zip, Spwrite-Windows-v1.3.5.zip and
     Spwrite-Linux-v1.3.5.zip for ARM64, Spwrite-Windows-x64-v1.3.5.zip and
     Spwrite-Linux-x64-v1.3.5.zip for x64) and deletes the previous version's
     zips, so the repo does not grow with every release;
  2. updates each platform in update/release.json (version, date, file, size,
     SHA-256); the site's release.js fills download buttons from it;
  3. replaces the old file names and version label written directly in the
     download pages (mac.html, windows.html, linux.html, index.html), which
     are shown before release.js runs and when JavaScript is off.

With --changelog it also publishes the release notes:

  4. writes update/v1.3.5.md from that version's section of CHANGELOG.md
     (wrapped lines joined, "Added" shown as "New"). An existing notes file is
     kept, so hand-written notes win; pass --overwrite-notes to replace it;
  5. adds the version to the top of update/versions.json and moves the
     "Latest" tag to it. The site's changelog.js renders the page from these.

Usage:
  publish_website.py --site PATH --version 1.3.5 [--builds PATH]
                     [--changelog CHANGELOG.md] [--overwrite-notes]
                     [--date "October 3, 2026"]
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import shutil
import sys
from pathlib import Path

# Site platform key -> (name used in the download file, build zip name,
# architecture label for a newly added entry). The "windows" and "linux" keys
# keep the site's existing ARM64 downloads and file names; the "-x64" keys are
# extra entries in update/release.json for x64 download buttons.
PLATFORMS = {
    "mac": ("macOS", "Spwrite-macos.zip", "Apple Silicon (ARM64)"),
    "windows": ("Windows", "Spwrite-windows-arm64.zip", "Windows 11 · ARM64"),
    "windows-x64": ("Windows-x64", "Spwrite-windows-x64.zip", "Windows 10 and 11 · x64"),
    "linux": ("Linux", "Spwrite-linux-arm64.zip", "Debian-based · ARM64"),
    "linux-x64": ("Linux-x64", "Spwrite-linux-x64.zip", "Debian-based · x64"),
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

    for key, (os_name, build_name, arch) in PLATFORMS.items():
        build = builds / build_name
        if not build.is_file():
            raise SystemExit(f"Missing build: {build}")
        file_name = f"Spwrite-{os_name}-v{version}.zip"
        entry = manifest.setdefault("platforms", {}).setdefault(key, {})
        entry.setdefault("arch", arch)
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


#: CHANGELOG.md section names -> the headings the website uses.
SECTION_NAMES = {"added": "New"}


def changelog_section(changelog: str, version: str) -> str | None:
    """Returns the body of the `## [version]` section of CHANGELOG.md, or None."""
    lines = changelog.splitlines()
    start = None
    for i, line in enumerate(lines):
        if line.startswith("## ") and f"[{version}]" in line:
            start = i + 1
            break
    if start is None:
        return None
    end = len(lines)
    for i in range(start, len(lines)):
        if lines[i].startswith("## "):
            end = i
            break
    return "\n".join(lines[start:end]).strip()


def to_site_markdown(section: str) -> str:
    """Converts a CHANGELOG.md section to the website's release-note format.

    The site's renderer reads one line per bullet, so wrapped bullets and
    paragraphs are joined onto a single line; "Added" becomes "New".
    """
    blocks: list[str] = []
    current: str | None = None

    def flush() -> None:
        nonlocal current
        if current is not None:
            blocks.append(current)
            current = None

    for raw in section.splitlines():
        line = raw.rstrip()
        if not line.strip():
            flush()
            continue
        heading = line.startswith("### ")
        bullet = line.lstrip().startswith(("- ", "* ")) and (len(line) - len(line.lstrip())) < 2
        if heading:
            flush()
            name = line[4:].strip()
            blocks.append("### " + SECTION_NAMES.get(name.lower(), name))
        elif bullet:
            flush()
            current = "- " + line.lstrip()[2:].strip()
        elif current is not None:
            current += " " + line.strip()  # continuation of a wrapped bullet
        else:
            current = line.strip()  # start of a paragraph
    flush()
    return "\n".join(blocks).strip() + "\n"


def publish_changelog(
    site: Path, changelog: Path, version: str, date: str, overwrite: bool = False
) -> list[str]:
    """Adds this version's release notes to the website's changelog.

    Writes update/v<version>.md from CHANGELOG.md (unless that file already
    exists and [overwrite] is false, so hand-written notes are kept), and adds
    the version to the top of update/versions.json tagged "Latest".
    """
    summary: list[str] = []
    section = changelog_section(changelog.read_text(encoding="utf-8"), version)
    if not section:
        raise SystemExit(f"CHANGELOG.md has no section for [{version}].")

    update = site / "update"
    update.mkdir(exist_ok=True)
    notes = update / f"v{version}.md"
    if notes.exists() and not overwrite:
        summary.append(f"kept existing update/{notes.name}")
    else:
        notes.write_text(to_site_markdown(section), encoding="utf-8")
        summary.append(f"wrote update/{notes.name}")

    index_path = update / "versions.json"
    index = (
        json.loads(index_path.read_text(encoding="utf-8"))
        if index_path.exists()
        else {"versions": []}
    )
    versions: list[dict] = index.setdefault("versions", [])
    label = f"Beta v{version}"
    entry = next((v for v in versions if v.get("file") == notes.name), None)
    if entry is None:
        entry = {"version": label, "date": date, "file": notes.name}
        versions.insert(0, entry)
        summary.append(f"added {label} to update/versions.json")
    before = json.dumps(index, sort_keys=True)
    # Only the newest version carries the "Latest" pill.
    for v in versions:
        if v is not entry:
            v.pop("tag", None)
    entry["tag"] = "Latest"
    if versions[0] is not entry:
        versions.remove(entry)
        versions.insert(0, entry)
    if json.dumps(index, sort_keys=True) == before:
        return summary  # Already current: leave the file exactly as it is.
    index_path.write_text(
        json.dumps(index, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
    )
    return summary


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--site", type=Path, required=True)
    parser.add_argument(
        "--builds", type=Path, help="folder holding the build zips (skip to update notes only)"
    )
    parser.add_argument("--version", required=True, help="e.g. 1.3.5")
    parser.add_argument("--date", default=today_label())
    parser.add_argument(
        "--changelog", type=Path,
        help="CHANGELOG.md to take this version's release notes from",
    )
    parser.add_argument(
        "--overwrite-notes", action="store_true",
        help="replace update/v<version>.md even if it already exists",
    )
    args = parser.parse_args()
    version = args.version.lstrip("v")
    if args.builds is not None:
        for line in publish(args.site, args.builds, version, args.date):
            print(line)
    if args.changelog is not None:
        for line in publish_changelog(
            args.site, args.changelog, version, args.date, args.overwrite_notes
        ):
            print(line)
    return 0


if __name__ == "__main__":
    sys.exit(main())
