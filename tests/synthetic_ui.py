#!/usr/bin/env python3
"""Build a fabricated, isolated 750-item catalog for QML scrolling checks.

Usage: python tests/synthetic_ui.py /tmp/my-ui-check
Then set XDG_CONFIG_HOME=<root>/config and XDG_CACHE_HOME=<root>/cache
before launching Quickshell from this worktree. DEMO=1 blocks cloud access.
"""
import json
from datetime import datetime, timedelta, timezone
from pathlib import Path
import subprocess
import sys

root = Path(sys.argv[1]).resolve()
if not root.is_relative_to(Path("/tmp")):
    raise SystemExit("synthetic fixture root must be under /tmp")
config = root / "config" / "omarchy-icloud-photos"
cache = root / "cache" / "omarchy-icloud-photos"
config.mkdir(parents=True, exist_ok=True)
cache.mkdir(parents=True, exist_ok=True)
(config / "config").write_text("DEMO=1\nAPPLE_ID=fabricated@example.invalid\nLIBRARY=" + str(root / "library") + "\n")
thumb = cache / "thumb.png"
subprocess.run(["magick", "-size", "64x64", "xc:steelblue", str(thumb)], check=True)
items = []
for i in range(750):
    date = datetime(2023, 1, 1, tzinfo=timezone.utc) + timedelta(days=i // 10, hours=i % 10)
    kind = "video" if i in (748, 749) else "live" if i == 747 else "photo"
    items.append(dict(id=f"fabricated-{i:04}", record=f"record-{i:04}", zone="PrimarySync",
                      name=f"fabricated-{i:04}.{'mov' if kind == 'video' else 'jpg'}", kind=kind, ts=date.timestamp(),
                      captured=date.isoformat(), date=date.strftime("%Y-%m-%d"), time=date.strftime("%H:%M"),
                      thumb="" if i == 748 else str(thumb), preview="" if i == 748 else str(thumb), path="", video="", shared=False,
                      duration=0, downloaded=False, state="cloud-only", error="",
                      favorite=i % 11 == 0, addedAt=(datetime.now(timezone.utc) - timedelta(days=i % 45)).timestamp(),
                      evictable=False))
(cache / "index.json").write_text(json.dumps(items))
(cache / "album-index.json").write_text(json.dumps([
    {"id": "fabricated-album", "title": "Fabricated Album", "zone": "PrimarySync"}]))
(cache / "albums").mkdir(exist_ok=True)
(cache / "albums" / "fabricated-album.json").write_text(json.dumps({
    "albumId": "fabricated-album", "ids": [item["id"] for item in items[::13]], "complete": True}))
(cache / "status.json").write_text(json.dumps(dict(state="ok", message="", count=len(items),
                                                   at=datetime.now(timezone.utc).isoformat())))
print(f"{len(items)} fabricated items across 75 days in {root}")
