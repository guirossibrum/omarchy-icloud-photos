#!/usr/bin/env python3
"""Local, account-scoped iCloud catalog. No cloud mutation is performed here.

The only files eligible for eviction live under cache/originals and are recorded
as owned. Legacy icloudpd downloads are indexed in place but never removed.
"""
import argparse
import contextlib
from datetime import datetime, timezone
import fcntl
import hashlib
from itertools import islice
import json
import os
from pathlib import Path
import sqlite3
import sys
import time
import signal
import subprocess

from pyicloud_ipd.base import PyiCloudService
from pyicloud_ipd.version_size import AssetVersionSize, LivePhotoVersionSize
from pyicloud_ipd.asset_version import AssetVersion
from pyicloud_ipd.exceptions import PyiCloudFailedLoginException
from pyicloud_ipd.item_type import AssetItemType

from icloud_helper import read_config


def account_key(username):
    return hashlib.sha256(username.strip().casefold().encode()).hexdigest()[:20]


def item_key(account, zone, record):
    return hashlib.sha256(json.dumps([account, zone, record]).encode()).hexdigest()[:32]


def field(record, name):
    return record.get("fields", {}).get(name, {}).get("value")


def libraries(api, choice="auto"):
    yield "PrimarySync", api.photos
    if choice in ("no", "false", "0"):
        return
    others = {**api.photos.private_libraries, **api.photos.shared_libraries}
    for zone, library in others.items():
        if zone != "PrimarySync" and (choice == "auto" or choice == zone):
            yield zone, library


def metadata(asset, account, zone):
    master, record = asset._master_record, asset._asset_record
    name = asset.filename
    raw_date = field(record, "assetDate")
    capture = datetime.fromtimestamp(raw_date / 1000, timezone.utc) if raw_date is not None else None
    try:
        versions = asset.versions
    except (KeyError, ValueError, TypeError):
        versions = {}
    kind = "video" if asset.item_type == AssetItemType.MOVIE else "photo"
    if LivePhotoVersionSize.ORIGINAL in versions:
        kind = "live"
    # No guessed coordinates: only explicit cloud fields are stored.
    location = field(record, "location") or field(master, "location")
    camera = field(record, "cameraModel") or field(master, "cameraModel")
    return dict(id=item_key(account, zone, asset.id), account=account, zone=zone,
                record=asset.id, name=name, kind=kind,
                captured=capture.isoformat() if capture else None,
                ts=capture.timestamp() if capture else None,
                width=field(master, "resOriginalWidth"), height=field(master, "resOriginalHeight"),
                timezone=field(record, "timeZone") or field(master, "timeZone"),
                location=json.dumps(location) if location is not None else None,
                camera=camera, size=field(master, "resOriginalRes") and field(master, "resOriginalRes").get("size"))


class Catalog:
    def __init__(self, cache, account):
        self.cache = Path(cache)
        self.cache.mkdir(parents=True, exist_ok=True)
        self.account = account
        self.db = sqlite3.connect(self.cache / "catalog.sqlite3", timeout=30)
        self.db.row_factory = sqlite3.Row
        self.db.execute("PRAGMA journal_mode=WAL")
        self.db.executescript("""
            CREATE TABLE IF NOT EXISTS assets (
              id TEXT PRIMARY KEY, account TEXT NOT NULL, zone TEXT NOT NULL,
              record TEXT NOT NULL, name TEXT NOT NULL, kind TEXT NOT NULL,
              captured TEXT, ts REAL, width INTEGER, height INTEGER,
              timezone TEXT, location TEXT, camera TEXT, size INTEGER, thumb TEXT,
              original TEXT, motion TEXT, owned INTEGER NOT NULL DEFAULT 0,
              state TEXT NOT NULL DEFAULT 'cloud-only', error TEXT,
              seen INTEGER NOT NULL DEFAULT 0,
              UNIQUE(account, zone, record));
            CREATE INDEX IF NOT EXISTS asset_order ON assets(account, ts);
            CREATE TABLE IF NOT EXISTS scans (
              account TEXT NOT NULL, zone TEXT NOT NULL, full_at INTEGER NOT NULL,
              PRIMARY KEY(account, zone));
        """)

    def upsert(self, data, seen):
        self.db.execute("""INSERT INTO assets
            (id, account, zone, record, name, kind, captured, ts, width, height,
             timezone, location, camera, size, seen)
            VALUES (:id,:account,:zone,:record,:name,:kind,:captured,:ts,:width,:height,
                    :timezone,:location,:camera,:size,:seen)
            ON CONFLICT(id) DO UPDATE SET name=excluded.name, kind=excluded.kind,
            captured=excluded.captured, ts=excluded.ts, width=excluded.width,
            height=excluded.height, location=excluded.location, camera=excluded.camera,
            size=excluded.size, timezone=excluded.timezone, seen=excluded.seen,
            state=CASE WHEN assets.state IN ('deleted','absent') THEN 'cloud-only' ELSE assets.state END""", {**data, "seen": seen})

    def get(self, key):
        row = self.db.execute("SELECT * FROM assets WHERE id=? AND account=?", (key, self.account)).fetchone()
        if row is None:
            raise ValueError("asset is absent from this account's catalog")
        return row

    def export(self):
        with (self.cache / "index.lock").open("a+b") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            return self._export()

    def _export(self):
        items = []
        for row in self.db.execute("SELECT * FROM assets WHERE account=? AND state NOT IN ('deleted','absent') ORDER BY ts, id", (self.account,)):
            r = dict(row)
            original = r["original"] if r["original"] and Path(r["original"]).is_file() else ""
            motion = r["motion"] if r["motion"] and Path(r["motion"]).is_file() else ""
            thumb = r["thumb"] if r["thumb"] and Path(r["thumb"]).is_file() else ""
            derived = self.cache / "previews" / (r["id"] + ".jpg")
            sdr = self.cache / "videos" / (r["id"] + ".mp4")
            ts = r["ts"] or 0
            local = datetime.fromtimestamp(ts).astimezone() if r["ts"] is not None else None
            items.append(dict(id=r["id"], record=r["record"], zone=r["zone"],
                name=r["name"], kind=r["kind"], ts=ts, captured=r["captured"],
                timezone=r["timezone"],
                date=local.strftime("%Y-%m-%d") if local else "Unknown",
                time=local.strftime("%H:%M") if local else "",
                thumb=thumb, preview=str(derived) if original and derived.is_file() else (original or thumb), path=original,
                video=(str(sdr) if sdr.is_file() else original) if r["kind"] == "video" else motion,
                shared=r["zone"] != "PrimarySync", duration=0,
                width=r["width"], height=r["height"], location=json.loads(r["location"]) if r["location"] else None,
                camera=r["camera"], size=r["size"], downloaded=bool(original),
                evictable=bool(original and r["owned"]),
                state=("downloaded" if original else "cloud-only") if r["state"] != "failed" else "failed",
                error=r["error"] or ""))
        atomic_json(self.cache / "index.json", items)
        return len(items)


def atomic_json(path, value):
    tmp = path.with_name(path.name + f".{os.getpid()}.tmp")
    tmp.write_text(json.dumps(value, ensure_ascii=False))
    os.replace(tmp, path)


def status(cache, state, message="", count=0):
    atomic_json(Path(cache) / "status.json", dict(state=state, message=message, count=count,
                                                   at=datetime.now().astimezone().isoformat()))


def cloud(cfg):
    if cfg.get("DEMO") == "1":
        raise RuntimeError("Synthetic demo has no cloud originals")
    api = PyiCloudService("com", cfg["APPLE_ID"], lambda: None, cookie_directory=cfg["COOKIES"])
    if api.requires_2fa:
        raise RuntimeError("iCloud session expired; sign in again")
    return api


def matching_asset(library, record):
    # pyicloud's public album interface does not offer a record lookup. Walk
    # every page by stable ID; never match a duplicate filename or stale URL.
    for asset in library.all:
        if asset.id == record:
            return asset
    raise ValueError("asset no longer exists in the selected library")


def version(asset, component):
    key = LivePhotoVersionSize.ORIGINAL if component == "motion" else AssetVersionSize.ORIGINAL
    value = asset.versions.get(key)
    if value is None:
        raise ValueError(f"{component} is unavailable in iCloud")
    return value


def thumbnail_version(asset):
    try:
        value = asset.versions.get(AssetVersionSize.THUMB)
    except (KeyError, ValueError, TypeError):
        value = None
    if value is not None and ("jpeg" in value.type.lower() or "jpg" in value.type.lower()):
        return value
    # pyicloud maps a video's THUMB to a small movie. Apple's separate JPEG
    # poster is safe to use when exposed in the record; a movie is never a
    # thumbnail download for this catalog.
    for record in (asset._asset_record, asset._master_record):
        raw = field(record, "resJPEGThumbRes")
        if raw and raw.get("downloadURL"):
            return AssetVersion(raw.get("size", 0), raw["downloadURL"], "image/jpeg", raw.get("fileChecksum", ""))
    return None


def transfer(asset, library, version_value, destination, progress=None):
    """Stream a specific version. Never substitute an original for a thumb."""
    destination.parent.mkdir(parents=True, exist_ok=True)
    tmp = destination.with_name(destination.name + f".{os.getpid()}.part")
    try:
        response = asset.download(library.session, version_value.url)
        response.raise_for_status()
        length = version_value.size or 0
        received = 0
        with tmp.open("xb") as out:
            for chunk in response.iter_content(chunk_size=256 * 1024):
                if chunk:
                    out.write(chunk)
                    received += len(chunk)
                    if progress:
                        progress(received, length)
            out.flush()
            os.fsync(out.fileno())
        if length and received != length:
            raise IOError("incomplete download")
        os.replace(tmp, destination)
    finally:
        tmp.unlink(missing_ok=True)


@contextlib.contextmanager
def asset_lock(cache, key):
    lock_dir = Path(cache) / "locks"
    lock_dir.mkdir(exist_ok=True)
    with (lock_dir / key).open("a+b") as handle:
        fcntl.flock(handle, fcntl.LOCK_EX)
        yield


def safe_name(name):
    value = Path(name).name.replace("/", "_").replace("\\", "_")
    return value if value not in ("", ".", "..") else "unnamed-asset"


def download(cat, cfg, key, component="original", api=None):
    with (cat.cache / "download.lock").open("a+b") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        return _download(cat, cfg, key, component, api)


def _download(cat, cfg, key, component="original", api=None):
    with asset_lock(cat.cache, key):
        row = cat.get(key)
        column = "motion" if component == "motion" else "original"
        if row[column] and Path(row[column]).is_file():
            return row[column]
        try:
            api = api or cloud(cfg)
            libs = dict(libraries(api, cfg.get("SHARED_LIBRARY", "auto")))
            library = libs[row["zone"]]
            asset = matching_asset(library, row["record"])
            v = version(asset, component)
            name = safe_name(row["name"])
            if component == "motion":
                name = Path(name).stem + "_HEVC.MOV"
            dest = cat.cache / "originals" / key / name
            if not dest.parent.resolve().is_relative_to((cat.cache / "originals").resolve()):
                raise ValueError("unsafe destination")
            def progress(done, total):
                print(json.dumps(dict(state="downloading", id=key, component=component,
                                      received=done, total=total)), flush=True)
            transfer(asset, library, v, dest, progress)
            if component == "original" and dest.suffix.lower() in (".heic", ".heif", ".tif", ".tiff", ".dng"):
                preview = cat.cache / "previews" / (key + ".jpg")
                preview.parent.mkdir(exist_ok=True)
                temp_preview = preview.with_name(preview.name + f".{os.getpid()}.tmp.jpg")
                try:
                    subprocess.run(["magick", str(dest), "-auto-orient", "-resize", "2200x2200>",
                                    "-quality", "90", str(temp_preview)], check=True, capture_output=True)
                    os.replace(temp_preview, preview)
                except (OSError, subprocess.CalledProcessError):
                    pass  # The cloud thumbnail remains a usable preview.
                finally:
                    temp_preview.unlink(missing_ok=True)
            with cat.db:
                cat.db.execute(f"UPDATE assets SET {column}=?, owned=1, state='downloaded', error=NULL WHERE id=?",
                               (str(dest), key))
            cat.export()
            print(json.dumps(dict(state="downloaded", id=key, path=str(dest))), flush=True)
            return str(dest)
        except Exception as exc:
            with cat.db:
                cat.db.execute("UPDATE assets SET state='failed', error=? WHERE id=?", (str(exc), key))
            cat.export()
            raise


def evict(cat, keys):
    root = (cat.cache / "originals").resolve()
    for key in keys:
        with asset_lock(cat.cache, key):
            row = cat.get(key)
            if row["original"] and not row["owned"]:
                continue  # Existing backup files are outside app ownership.
            if row["owned"]:
                for column in ("original", "motion"):
                    p = row[column]
                    if p:
                        path = Path(p)
                        if path.resolve().is_relative_to(root) and path.is_file() and not path.is_symlink():
                            path.unlink()
                # Derived full-media caches use the same stable key.
                for folder, suffix in (("videos", ".mp4"), ("previews", ".jpg"), ("wallpaper", ".jpg")):
                    path = cat.cache / folder / (key + suffix)
                    if path.is_file() and not path.is_symlink():
                        path.unlink()
            # A process interrupted after rename but before its DB commit
            # can leave a final file here. Only our deterministic names and
            # their temporary parts are eligible; unrelated files are left.
            owned_dir = root / key
            if owned_dir.is_dir() and not owned_dir.is_symlink():
                still = safe_name(row["name"])
                motion = Path(still).stem + "_HEVC.MOV"
                for path in owned_dir.iterdir():
                    ours = path.name in (still, motion) or any(
                        path.name.startswith(name + ".") and path.name.endswith(".part")
                        for name in (still, motion))
                    if ours and path.is_file() and not path.is_symlink():
                        path.unlink()
            with cat.db:
                cat.db.execute("UPDATE assets SET original=NULL, motion=NULL, owned=0, state='cloud-only', error=NULL WHERE id=?", (key,))
    cat.export()


def convert_video(cat, key):
    """Build an app-owned SDR playback copy when ffprobe detects HDR."""
    with asset_lock(cat.cache, key):
        row = cat.get(key)
        source = row["original"]
        if row["kind"] != "video" or not source or not Path(source).is_file():
            raise ValueError("video original is not downloaded")
        probe = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v:0",
                                "-show_entries", "stream=color_transfer", "-of", "csv=p=0", source],
                               capture_output=True, text=True, check=True)
        if probe.stdout.strip() not in ("arib-std-b67", "smpte2084"):
            return False
        dest = cat.cache / "videos" / (key + ".mp4")
        if dest.is_file() and dest.stat().st_mtime >= Path(source).stat().st_mtime:
            return True
        dest.parent.mkdir(exist_ok=True)
        temp = dest.with_name(dest.stem + f".{os.getpid()}.tmp.mp4")
        command = ["ffmpeg", "-v", "error", "-y", "-i", source,
                   "-vf", "zscale=t=linear:npl=100,format=gbrpf32le,zscale=p=bt709,tonemap=hable:desat=0,zscale=t=bt709:m=bt709:r=tv,format=yuv420p,scale=w='if(gt(iw,ih),min(2200,iw),-2)':h='if(gt(iw,ih),-2,min(2200,ih))'",
                   "-threads", "2", "-c:v", "libx264", "-preset", "veryfast", "-crf", "23",
                   "-maxrate", "8M", "-bufsize", "16M", "-c:a", "aac", "-b:a", "128k",
                   "-movflags", "+faststart", str(temp)]
        process = subprocess.Popen(command)
        try:
            if process.wait() != 0:
                raise RuntimeError("HDR video conversion failed")
            os.replace(temp, dest)
        except BaseException:
            if process.poll() is None:
                process.terminate()
                process.wait()
            raise
        finally:
            temp.unlink(missing_ok=True)
    cat.export()
    return True


def on_ac():
    supplies = list(Path("/sys/class/power_supply").glob("*/online"))
    return not supplies or any(path.read_text().strip() == "1" for path in supplies if path.is_file())


def sync(cat, cfg, api=None, full=False):
    api = api or cloud(cfg)
    now = int(time.time())
    count = 0
    changed = not (cat.cache / "index.json").is_file()
    # Publish the first cards quickly, then grow the batches to avoid
    # repeatedly rebuilding a large index in the viewer.
    next_publish = 30
    publish_step = 30
    last_publish_at = time.monotonic()
    thumbnail_libraries = []
    for zone, library in libraries(api, cfg.get("SHARED_LIBRARY", "auto")):
        last = cat.db.execute("SELECT full_at FROM scans WHERE account=? AND zone=?", (cat.account, zone)).fetchone()
        whole = full or last is None or now - last[0] > 7 * 86400
        zone_count = 0
        needs_thumbnails = False
        # The pyicloud iterator performs complete offset pagination. On routine
        # runs, stop after two full pages of already known records.
        known_streak = 0
        for asset in library.all:
            data = metadata(asset, cat.account, zone)
            previous = cat.db.execute("SELECT * FROM assets WHERE id=?", (data["id"],)).fetchone()
            existed = previous is not None
            if previous is None or any(previous[k] != v for k, v in data.items()) or previous["state"] in ("deleted", "absent"):
                changed = True
            cat.upsert(data, now)
            known_streak = known_streak + 1 if existed else 0
            count += 1
            zone_count += 1
            thumb = cat.cache / "thumbs" / (data["id"] + ".jpg")
            if not thumb.is_file() or previous is None or previous["thumb"] != str(thumb):
                needs_thumbnails = True
            if count >= next_publish or time.monotonic() - last_publish_at >= 5:
                cat.db.commit()
                if changed:
                    cat.export()
                    changed = False
                status(cat.cache, "syncing", "Finding photos", count)
                last_publish_at = time.monotonic()
                if count >= next_publish:
                    publish_step = min(publish_step * 2, 2000)
                    next_publish += publish_step
            if not whole and known_streak >= 200:
                break
        with cat.db:
            if whole:
                cat.db.execute("UPDATE assets SET state='absent' WHERE account=? AND zone=? AND seen != ? AND state != 'deleted'",
                               (cat.account, zone, now))
                changed = True
                cat.db.execute("INSERT INTO scans VALUES (?,?,?) ON CONFLICT(account,zone) DO UPDATE SET full_at=excluded.full_at",
                               (cat.account, zone, now))
        # A fresh iterator is used after metadata discovery. It obtains fresh
        # thumbnail URLs and keeps cloud asset objects out of long-lived memory.
        if needs_thumbnails:
            thumbnail_libraries.append((zone, library, zone_count))
    cat.db.commit()
    if changed:
        cat.export()
        changed = False
    status(cat.cache, "syncing", f"Loading thumbnails (0/{count})")
    thumbnails = 0
    next_thumb_publish = 20
    thumb_step = 20
    last_thumb_publish_at = time.monotonic()
    for zone, library, zone_count in thumbnail_libraries:
        for asset in islice(library.all, zone_count):
            key = item_key(cat.account, zone, asset.id)
            try:
                row = cat.get(key)
            except ValueError:
                # The cloud library can change between the metadata and
                # thumbnail passes. The next sync will catalog new records.
                continue
            thumb = cat.cache / "thumbs" / (key + ".jpg")
            if not thumb.is_file():
                thumb_version = thumbnail_version(asset)
                if thumb_version is not None:
                    try:
                        transfer(asset, library, thumb_version, thumb)
                    except Exception:
                        pass  # Placeholder remains; never fall back to original.
            if thumb.is_file() and row["thumb"] != str(thumb):
                cat.db.execute("UPDATE assets SET thumb=? WHERE id=?", (str(thumb), key))
                changed = True
            thumbnails += 1
            if thumbnails >= next_thumb_publish or time.monotonic() - last_thumb_publish_at >= 5:
                cat.db.commit()
                if changed:
                    cat.export()
                    changed = False
                status(cat.cache, "syncing", f"Loading thumbnails ({thumbnails}/{count})")
                last_thumb_publish_at = time.monotonic()
                if thumbnails >= next_thumb_publish:
                    thumb_step = min(thumb_step * 2, 2000)
                    next_thumb_publish += thumb_step
    cat.db.commit()
    if cat.db.execute("SELECT 1 FROM scans WHERE account=?", (cat.account,)).fetchone():
        changed = adopt_legacy(cat, cfg) or changed
    if changed:
        cat.export()
    return cat.db.execute("SELECT COUNT(*) FROM assets WHERE account=? AND state NOT IN ('deleted','absent')", (cat.account,)).fetchone()[0]


def adopt_legacy(cat, cfg):
    """One-time read-only match of existing icloudpd files by zone/name/time.

    Ambiguous matches are ignored. Backup files are never moved or owned by
    the catalog, so local eviction cannot delete them.
    """
    marker = cat.cache / ("legacy-scan-" + cat.account)
    if marker.exists():
        return False
    library = Path(os.path.expandvars(cfg.get("LIBRARY", str(Path.home() / "Pictures/iCloud")))).expanduser()
    if not library.is_dir():
        marker.touch()
        return False
    changed = False
    candidates = {}
    for base, dirs, names in os.walk(library):
        for name in names:
            path = Path(base) / name
            if path.is_symlink() or not path.is_file():
                continue
            zone = "shared" if path.is_relative_to(library / "shared") else "personal"
            candidates.setdefault((zone, name), []).append(path)
    for row in cat.db.execute("SELECT * FROM assets WHERE account=? AND original IS NULL", (cat.account,)).fetchall():
        zone = "personal" if row["zone"] == "PrimarySync" else "shared"
        matches = [p for p in candidates.get((zone, row["name"]), [])
                   if row["ts"] is not None and abs(p.stat().st_mtime - row["ts"]) <= 180]
        if len(matches) == 1:
            motion = None
            if row["kind"] == "live":
                possible = [matches[0].with_name(matches[0].stem + "_HEVC.MOV")]
                if matches[0].suffix.lower() in (".jpg", ".jpeg"):
                    possible.append(matches[0].with_suffix(".MOV"))
                for companion in possible:
                    if companion.is_file() and not companion.is_symlink():
                        motion = str(companion)
                        break
            cat.db.execute("UPDATE assets SET original=?, motion=?, state='downloaded', owned=0 WHERE id=?",
                           (str(matches[0]), motion, row["id"]))
            changed = True
    cat.db.commit()
    marker.touch()
    return changed


def main():
    def interrupted(signum, frame):
        raise KeyboardInterrupt("download cancelled")
    signal.signal(signal.SIGTERM, interrupted)
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("sync").add_argument("--full", action="store_true")
    sub.add_parser("export")
    get = sub.add_parser("download"); get.add_argument("id"); get.add_argument("--component", choices=("original", "motion"), default="original")
    remove = sub.add_parser("evict"); remove.add_argument("ids", nargs="+")
    convert = sub.add_parser("convert"); convert.add_argument("ids", nargs="+")
    sub.add_parser("convert-all").add_argument("--force", action="store_true")
    args = parser.parse_args()
    cfg = read_config()
    cfg.setdefault("COOKIES", str(Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config")) / "icloudpd"))
    cache = Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache")) / "omarchy-icloud-photos"
    cat = Catalog(cache, account_key(cfg["APPLE_ID"]))
    try:
        if args.command == "sync":
            with (cache / "sync.lock").open("a+b") as lock:
                try:
                    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError:
                    return
                status(cache, "syncing", "Refreshing catalog")
                n = sync(cat, cfg, full=args.full)
                status(cache, "ok", "", n)
        elif args.command == "export":
            cat.export()
        elif args.command == "download":
            download(cat, cfg, args.id, args.component)
        elif args.command == "convert":
            for key in args.ids:
                convert_video(cat, key)
        elif args.command == "convert-all":
            if not args.force and not on_ac():
                raise RuntimeError("plug in or pass --force to convert all videos")
            for row in cat.db.execute("SELECT id FROM assets WHERE account=? AND kind='video' AND original IS NOT NULL", (cat.account,)).fetchall():
                convert_video(cat, row["id"])
        else:
            evict(cat, args.ids)
    except (Exception, KeyboardInterrupt) as exc:
        if args.command == "sync":
            status(cache, "auth-required" if isinstance(exc, PyiCloudFailedLoginException) or "session expired" in str(exc) else "error", str(exc))
        print(json.dumps(dict(ok=False, error=str(exc))), file=sys.stderr)
        raise SystemExit(1)


if __name__ == "__main__":
    main()
