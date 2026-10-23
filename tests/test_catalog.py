"""Synthetic cloud contract tests. These never authenticate or touch a live account."""
import importlib.util
import base64
import json
import sqlite3
from pathlib import Path
from datetime import datetime, timezone
from types import SimpleNamespace
import tempfile
import threading
import unittest
from unittest.mock import patch

from pyicloud_ipd.asset_version import AssetVersion
from pyicloud_ipd.item_type import AssetItemType
from pyicloud_ipd.version_size import AssetVersionSize, LivePhotoVersionSize

SOURCE = Path(__file__).resolve().parents[1] / "bin" / "library_catalog.py"
spec = importlib.util.spec_from_file_location("library_catalog", SOURCE)
import sys
sys.path.insert(0, str(SOURCE.parent))
catalog = importlib.util.module_from_spec(spec)
spec.loader.exec_module(catalog)
import icloud_helper as helper


class Response:
    def __init__(self, payload, fail=False):
        self.payload, self.fail = payload, fail

    def raise_for_status(self):
        if self.fail:
            raise RuntimeError("expired URL")

    def iter_content(self, chunk_size):
        yield self.payload[:2]
        if self.fail:
            raise RuntimeError("interrupted")
        yield self.payload[2:]


class Asset:
    def __init__(self, record, zone, day, kind="photo", thumb=True, motion=False, name="same.jpg"):
        self.id, self.zone, self.filename, self.kind = record, zone, name, kind
        self._master_record = {"fields": {
            "itemType": {"value": "com.apple.quicktime-movie" if kind == "video" else "public.jpeg"},
            "resOriginalWidth": {"value": 3000}, "resOriginalHeight": {"value": 2000},
            "resOriginalRes": {"value": {"size": 8}}}}
        self._asset_record = {"recordName": record, "recordChangeTag": "tag",
                              "fields": {"assetDate": {"value": (1700000000 - day * 86400) * 1000}}}
        self.versions = {AssetVersionSize.ORIGINAL: AssetVersion(8, f"original:{zone}:{record}", "jpg", "")}
        if thumb:
            self.versions[AssetVersionSize.THUMB] = AssetVersion(5, f"thumb:{zone}:{record}", "jpg", "")
        if motion:
            self.versions[LivePhotoVersionSize.ORIGINAL] = AssetVersion(6, f"motion:{zone}:{record}", "mov", "")

    def download(self, session, url):
        session.calls.append(url)
        return Response(b"thumb" if url.startswith("thumb:") else b"original" if url.startswith(("original:", "medium:")) else b"motion")

    @property
    def item_type(self):
        return AssetItemType.MOVIE if self.kind == "video" else AssetItemType.IMAGE

    @property
    def created(self):
        return datetime.fromtimestamp(self._asset_record["fields"]["assetDate"]["value"] / 1000, timezone.utc)

    @property
    def size(self):
        return 8


class Album:
    def __init__(self, library):
        self.library = library
        self.offset = 0

    def __len__(self):
        return len(self.library.assets)

    def increment_offset(self, value):
        self.offset += value

    def _list_query_gen(self, offset, list_type, query_filter=None):
        return {"query": {"filterBy": [
            {"fieldName": "startRank", "fieldValue": {"value": offset}},
            {"fieldName": "direction", "fieldValue": {"value": "ASCENDING"}},
        ]}}

    def __iter__(self):
        query = self._list_query_gen(self.offset, "fabricated-album")
        direction = query["query"]["filterBy"][1]["fieldValue"]["value"]
        self.library.orders.append(direction)
        assets = self.library.assets if direction == "ASCENDING" else list(reversed(self.library.assets))
        while self.offset < len(assets):
            start = self.offset
            self.library.pages += 1
            for asset in assets[start:start + 100]:
                yield asset
                self.increment_offset(1)


class Library:
    def __init__(self, assets):
        self.assets = assets
        self.session = type("Session", (), {"calls": []})()
        self.pages = 0
        self.orders = []

    @property
    def all(self):
        return Album(self)


class API:
    def __init__(self, personal, shared):
        self.photos = personal
        personal.private_libraries = {"PrimarySync": personal}
        personal.shared_libraries = {"SharedSync-fabricated": shared}


class CatalogTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.cache = Path(self.tmp.name) / "cache"
        self.cat = catalog.Catalog(self.cache, catalog.account_key("fabricated@example.invalid"))
        self.addCleanup(self.cat.db.close)
        self.cfg = {"APPLE_ID": "fabricated@example.invalid", "SHARED_LIBRARY": "auto",
                    "LIBRARY": str(Path(self.tmp.name) / "empty-library")}
        self.personal = Library([Asset(f"p{i}", "PrimarySync", i) for i in range(650)])
        self.shared = Library([Asset("p0", "SharedSync-fabricated", 500, kind="video"),
                               Asset("live", "SharedSync-fabricated", 800, motion=True, thumb=False)])
        self.api = API(self.personal, self.shared)

    def test_full_sync_pagination_thumbnail_only_and_shared_identity(self):
        self.shared.assets[0]._asset_record["fields"]["duration"] = {"value": 33163}
        count = catalog.sync(self.cat, self.cfg, self.api)
        self.assertEqual(count, 652)
        self.assertEqual(self.personal.pages, 14)  # metadata, then fresh thumbnail URLs
        self.assertEqual(self.cat.db.execute("SELECT COUNT(*) FROM assets").fetchone()[0], 652)
        self.assertTrue(self.cat.get(catalog.item_key(self.cat.account, "PrimarySync", "p649"))["ts"] < 1700000000 - 30 * 86400)
        self.assertNotEqual(catalog.item_key(self.cat.account, "PrimarySync", "p0"),
                            catalog.item_key(self.cat.account, "SharedSync-fabricated", "p0"))
        video = self.cat.get(catalog.item_key(self.cat.account, "SharedSync-fabricated", "p0"))
        self.assertAlmostEqual(video["duration"], 33.163)
        self.assertEqual(Path(video["thumb"]).read_bytes(), b"thumb")
        self.assertIsNone(video["original"])
        calls = self.personal.session.calls + self.shared.session.calls
        self.assertTrue(calls)
        self.assertTrue(all(url.startswith("thumb:") for url in calls))
        missing = self.cat.get(catalog.item_key(self.cat.account, "SharedSync-fabricated", "live"))
        self.assertIsNone(missing["thumb"])
        self.assertIsNone(missing["location"])
        self.assertIsNone(missing["timezone"])

    def test_favorites_recents_metadata_and_restart_safe_migration(self):
        asset = self.personal.assets[0]
        asset._asset_record["fields"]["isFavorite"] = {"value": True}
        asset._asset_record["fields"]["addedDate"] = {"value": 1700000000000}
        catalog.sync(self.cat, self.cfg, self.api)
        key = catalog.item_key(self.cat.account, "PrimarySync", "p0")
        item = next(x for x in json.loads((self.cache / "index.json").read_text()) if x["id"] == key)
        self.assertTrue(item["favorite"])
        self.assertEqual(item["addedAt"], 1700000000)
        unknown = next(x for x in json.loads((self.cache / "index.json").read_text()) if x["id"] != key)
        self.assertIsNone(unknown["favorite"])
        self.assertIsNone(unknown["addedAt"])
        restarted = catalog.Catalog(self.cache, self.cat.account)
        self.addCleanup(restarted.db.close)
        self.assertTrue(restarted.get(key)["favorite"])
        self.assertEqual(restarted.get(key)["added_at"], 1700000000)

    def test_existing_catalog_schema_migrates_without_replacing_records(self):
        old_cache = Path(self.tmp.name) / "old-cache"
        old_cache.mkdir()
        db = sqlite3.connect(old_cache / "catalog.sqlite3")
        db.executescript("""
            CREATE TABLE assets (
              id TEXT PRIMARY KEY, account TEXT NOT NULL, zone TEXT NOT NULL,
              record TEXT NOT NULL, name TEXT NOT NULL, kind TEXT NOT NULL,
              captured TEXT, ts REAL, width INTEGER, height INTEGER,
              timezone TEXT, location TEXT, camera TEXT, size INTEGER, thumb TEXT,
              original TEXT, motion TEXT, owned INTEGER NOT NULL DEFAULT 0,
              state TEXT NOT NULL DEFAULT 'cloud-only', error TEXT,
              seen INTEGER NOT NULL DEFAULT 0,
              UNIQUE(account, zone, record));
        """)
        db.execute("INSERT INTO assets(id,account,zone,record,name,kind) VALUES(?,?,?,?,?,?)",
                   ("fabricated-key", self.cat.account, "PrimarySync", "fabricated-record", "fabricated.jpg", "photo"))
        old_original = old_cache / "originals" / "old-owned" / "saved.jpg"
        old_original.parent.mkdir(parents=True)
        old_original.write_bytes(b"fabricated")
        db.execute("""INSERT INTO assets(id,account,zone,record,name,kind,original,owned,state)
            VALUES(?,?,?,?,?,?,?,?,?)""", ("old-owned", self.cat.account, "PrimarySync",
            "old-record", "saved.jpg", "photo", str(old_original), 1, "downloaded"))
        db.commit()
        db.close()
        migrated = catalog.Catalog(old_cache, self.cat.account)
        self.addCleanup(migrated.db.close)
        self.assertEqual(migrated.get("fabricated-key")["name"], "fabricated.jpg")
        self.assertIsNone(migrated.get("fabricated-key")["favorite"])
        self.assertIsNone(migrated.get("fabricated-key")["added_at"])
        self.assertIsNone(migrated.get("fabricated-key")["rank"])
        self.assertIsNone(migrated.get("fabricated-key")["duration"])
        self.assertEqual(migrated.get("fabricated-key")["favorite_sync"], "synced")
        self.assertTrue(migrated.get("old-owned")["keep_offline"])
        self.assertEqual(catalog.apply_download_policy(migrated, self.cfg), 0)
        self.assertTrue(old_original.exists())

    def test_video_length_from_existing_original_and_favorite_request(self):
        catalog.sync(self.cat, self.cfg, self.api, max_items=3)
        video = Asset("duration-video", "PrimarySync", 2, kind="video", name="fabricated.mov")
        data = catalog.metadata(video, self.cat.account, "PrimarySync")
        data["rank"] = 2
        self.cat.upsert(data, 1)
        key = data["id"]
        original = self.cache / "originals" / key / "fabricated.mov"
        original.parent.mkdir(parents=True)
        original.write_bytes(b"fabricated video")
        self.cat.db.execute("UPDATE assets SET original=?, owned=1 WHERE id=?", (str(original), key))
        with patch.object(catalog, "video_duration", return_value=33.2):
            self.cat.export()
        exported = next(it for it in json.loads((self.cache / "index.json").read_text()) if it["id"] == key)
        self.assertEqual(exported["duration"], 33.2)

        calls = []
        class Session:
            def post(self, url, data, headers):
                calls.append(json.loads(data))
                return SimpleNamespace(json=lambda: {"records": [{"recordChangeTag": "next"}]})
        library = SimpleNamespace(service_endpoint="https://fabricated.invalid", params={},
                                  zone_id={"zoneName": "PrimarySync"}, session=Session())
        helper.set_asset_flag(library, "duration-video", "tag", "isFavorite", True)
        self.assertEqual(calls[0]["operations"][0]["record"]["fields"], {"isFavorite": {"value": 1}})
        with patch.object(helper, "CACHE", self.cache):
            helper.cmd_favorite(SimpleNamespace(key=key, value=1), {**self.cfg, "DEMO": "1"})
            self.assertEqual(self.cat.get(key)["favorite"], 1)
            helper.cmd_favorite(SimpleNamespace(key=key, value=0), {**self.cfg, "DEMO": "1"})
            self.assertEqual(self.cat.get(key)["favorite"], 0)

            master_key = catalog.item_key(self.cat.account, "PrimarySync", "p0")
            self.personal.assets[0]._asset_record["recordName"] = "linked-asset-record"
            self.personal.assets[0]._asset_record["fields"]["isFavorite"] = {"value": 0}
            def accept_favorite(*args):
                self.personal.assets[0]._asset_record["fields"]["isFavorite"] = {"value": 1}
            with patch.object(helper, "connect", return_value=self.api), \
                 patch.object(helper, "set_asset_flag", side_effect=accept_favorite) as update:
                helper.cmd_favorite(SimpleNamespace(key=master_key, value=1), self.cfg)
            self.assertEqual(update.call_args.args[1:],
                             ("linked-asset-record", "tag", "isFavorite", True))
            self.assertEqual(self.cat.get(master_key)["favorite_sync"], "synced")

    def test_failed_favorite_remains_local_and_refresh_retries(self):
        catalog.sync(self.cat, self.cfg, self.api, max_items=3)
        key = catalog.item_key(self.cat.account, "PrimarySync", "p0")
        asset = self.personal.assets[0]
        asset._asset_record["recordName"] = "linked-asset-record"
        asset._asset_record["fields"]["isFavorite"] = {"value": 0}
        with patch.object(helper, "CACHE", self.cache), \
             patch.object(helper, "connect", return_value=self.api), \
             patch.object(helper, "set_asset_flag", side_effect=helper.CloudMutationError("SERVICE_UNAVAILABLE")) as failed, \
             patch.object(helper.time, "sleep"):
            helper.cmd_favorite(SimpleNamespace(key=key, value=1), self.cfg)
        self.assertEqual(failed.call_count, 3)
        self.assertEqual(self.cat.get(key)["favorite"], 1)
        self.assertEqual(self.cat.get(key)["favorite_sync"], "local-only")
        restarted = catalog.Catalog(self.cache, self.cat.account)
        self.addCleanup(restarted.db.close)
        self.assertEqual(restarted.get(key)["favorite"], 1)

        with patch.object(helper, "set_asset_flag", side_effect=helper.CloudMutationError("SERVICE_UNAVAILABLE")) as retry_failed:
            catalog.sync(restarted, self.cfg, self.api, max_items=3)
        self.assertEqual(retry_failed.call_count, 1)
        self.assertEqual(restarted.get(key)["favorite"], 1)
        self.assertEqual(restarted.get(key)["favorite_sync"], "local-only")

        def accept_favorite(*args):
            asset._asset_record["fields"]["isFavorite"] = {"value": 1}
        with patch.object(helper, "set_asset_flag", side_effect=accept_favorite) as retried:
            catalog.sync(restarted, self.cfg, self.api, max_items=3)
        self.assertEqual(retried.call_count, 1)
        self.assertEqual(restarted.get(key)["favorite"], 1)
        self.assertEqual(restarted.get(key)["favorite_sync"], "synced")

    def test_older_favorite_attempt_cannot_replace_newer_local_choice(self):
        catalog.sync(self.cat, self.cfg, self.api, max_items=1)
        key = catalog.item_key(self.cat.account, "PrimarySync", "p0")
        self.cat.set_local_favorite(key, 1)
        old_request = self.cat.get(key)
        self.cat.set_local_favorite(key, 0)
        with patch.object(helper, "set_asset_flag") as cloud_write:
            self.assertFalse(helper.push_favorite(self.cat, old_request, self.api))
        cloud_write.assert_not_called()
        self.assertEqual(self.cat.get(key)["favorite"], 0)
        self.assertEqual(self.cat.get(key)["favorite_sync"], "pending")

    def test_first_sync_publishes_cards_before_thumbnail_requests(self):
        exports = []
        first_transfer = []
        real_export = self.cat.export
        real_transfer = catalog.transfer

        def record_export():
            count = real_export()
            exports.append(count)
            return count

        def record_transfer(*args, **kwargs):
            if not first_transfer:
                first_transfer.append(json.loads((self.cache / "index.json").read_text()))
            return real_transfer(*args, **kwargs)

        with patch.object(self.cat, "export", side_effect=record_export), \
             patch.object(catalog, "transfer", side_effect=record_transfer):
            catalog.sync(self.cat, self.cfg, self.api)
        self.assertEqual(exports[0], 30)
        self.assertTrue(any(30 < count < 652 for count in exports))
        self.assertEqual(len(first_transfer[0]), 30)
        self.assertTrue(all(not item["downloaded"] and not item["thumb"] for item in first_transfer[0]))

    def test_viewport_priority_seeks_to_older_visible_page(self):
        catalog.sync(self.cat, self.cfg, self.api, max_items=500)
        key = catalog.item_key(self.cat.account, "PrimarySync", "p400")
        thumb = Path(self.cat.get(key)["thumb"])
        thumb.unlink()
        catalog.atomic_json(self.cache / "priority.json", {"at": __import__("time").time(), "ids": [key]})
        pages_before = self.personal.pages
        self.assertTrue(catalog.fetch_visible_thumbnails(self.cat, {"PrimarySync": self.personal}))
        self.assertEqual(self.personal.pages - pages_before, 1)
        self.assertTrue(thumb.is_file())
        self.assertEqual(self.personal.session.calls[-1], "thumb:PrimarySync:p400")
        self.assertIsNone(self.cat.get(key)["original"])

    def test_capped_preview_keeps_future_full_scan_available(self):
        count = catalog.sync(self.cat, self.cfg, self.api, max_items=120)
        self.assertEqual(count, 120)
        self.assertEqual(self.personal.orders, ["ASCENDING", "ASCENDING"])
        self.assertIsNotNone(self.cat.get(catalog.item_key(self.cat.account, "PrimarySync", "p0")))
        with self.assertRaises(ValueError):
            self.cat.get(catalog.item_key(self.cat.account, "PrimarySync", "p649"))
        self.assertEqual(len(json.loads((self.cache / "index.json").read_text())), 120)
        self.assertEqual(self.cat.db.execute("SELECT COUNT(*) FROM scans").fetchone()[0], 0)
        self.assertEqual(self.cat.db.execute("SELECT COUNT(*) FROM assets WHERE original IS NOT NULL").fetchone()[0], 0)
        self.assertTrue(all(url.startswith("thumb:") for url in self.personal.session.calls))
        self.assertEqual(catalog.sync(self.cat, self.cfg, self.api), 652)

    def test_video_and_missing_poster_never_fetch_small_movie(self):
        video = self.shared.assets[0]
        video.filename = "fabricated.mov"
        video.versions[AssetVersionSize.THUMB] = AssetVersion(5, "small-movie", "video/quicktime", "")
        catalog.sync(self.cat, self.cfg, self.api)
        key = catalog.item_key(self.cat.account, "SharedSync-fabricated", "p0")
        self.assertIsNone(self.cat.get(key)["thumb"])
        self.assertNotIn("small-movie", self.shared.session.calls)
        catalog.download(self.cat, self.cfg, key, api=self.api)
        self.assertEqual(self.shared.session.calls[-1], "original:SharedSync-fabricated:p0")
        item = next(x for x in __import__("json").loads((self.cache / "index.json").read_text()) if x["id"] == key)
        self.assertEqual(item["kind"], "video")
        self.assertEqual(item["video"], item["path"])

    def test_thumbnail_failure_does_not_fall_back_to_original(self):
        asset = self.personal.assets[0]
        original_download = asset.download
        def fail_thumb(session, url):
            if url.startswith("thumb:"):
                raise RuntimeError("thumbnail expired")
            return original_download(session, url)
        with patch.object(asset, "download", side_effect=fail_thumb):
            catalog.sync(self.cat, self.cfg, self.api)
        key = catalog.item_key(self.cat.account, "PrimarySync", "p0")
        self.assertIsNone(self.cat.get(key)["thumb"])
        self.assertIsNone(self.cat.get(key)["original"])
        self.assertFalse(any(url.startswith("original:") for url in self.personal.session.calls))

    def test_hdr_conversion_preserves_full_catalog_and_evicts_playback_copy(self):
        catalog.sync(self.cat, self.cfg, self.api)
        key = catalog.item_key(self.cat.account, "SharedSync-fabricated", "p0")
        catalog.download(self.cat, self.cfg, key, api=self.api)
        def spawn(command):
            Path(command[-1]).write_bytes(b"fabricated-sdr")
            return SimpleNamespace(wait=lambda: 0, poll=lambda: 0)
        with patch.object(catalog.subprocess, "run", return_value=SimpleNamespace(stdout="arib-std-b67,\n")), \
             patch.object(catalog.subprocess, "Popen", side_effect=spawn):
            self.assertTrue(catalog.convert_video(self.cat, key))
        index = __import__("json").loads((self.cache / "index.json").read_text())
        self.assertEqual(len(index), 652)
        item = next(x for x in index if x["id"] == key)
        self.assertTrue(item["video"].endswith(key + ".mp4"))
        catalog.evict(self.cat, [key])
        self.assertFalse(Path(item["video"]).exists())

    def test_download_evict_restart_redownload_and_expiring_url(self):
        catalog.sync(self.cat, self.cfg, self.api)
        key = catalog.item_key(self.cat.account, "SharedSync-fabricated", "live")
        self.assertEqual(catalog.download(self.cat, self.cfg, key, api=self.api).endswith("same.jpg"), True)
        self.assertEqual(Path(self.cat.get(key)["original"]).read_bytes(), b"original")
        catalog.download(self.cat, self.cfg, key, "motion", self.api)
        self.assertEqual(Path(self.cat.get(key)["motion"]).read_bytes(), b"motion")
        before = list(self.shared.session.calls)
        catalog.download(self.cat, self.cfg, key, api=self.api)
        self.assertEqual(before, self.shared.session.calls)
        thumb = self.cat.get(key)["thumb"]
        before_evict = list(self.shared.session.calls)
        catalog.evict(self.cat, [key])
        self.assertEqual(before_evict, self.shared.session.calls)  # no cloud mutation or download
        restarted = catalog.Catalog(self.cache, self.cat.account)
        self.addCleanup(restarted.db.close)
        self.assertIsNone(restarted.get(key)["original"])
        self.assertEqual(restarted.get(key)["thumb"], thumb)
        catalog.sync(restarted, self.cfg, self.api)
        self.assertIsNone(restarted.get(key)["original"])
        self.shared.assets[1].versions[AssetVersionSize.ORIGINAL] = AssetVersion(8, "original:fresh", "jpg", "")
        catalog.download(restarted, self.cfg, key, api=self.api)
        self.assertEqual(self.shared.session.calls[-1], "original:fresh")

    def test_incomplete_download_never_becomes_complete(self):
        catalog.sync(self.cat, self.cfg, self.api)
        key = catalog.item_key(self.cat.account, "PrimarySync", "p0")
        asset = self.personal.assets[0]
        with patch.object(asset, "download", return_value=Response(b"original", fail=True)):
            with self.assertRaises(RuntimeError):
                catalog.download(self.cat, self.cfg, key, api=self.api)
        self.assertIsNone(self.cat.get(key)["original"])
        self.assertEqual(list((self.cache / "originals" / key).glob("*")), [])

    def test_auth_failure_and_old_record_lookup(self):
        catalog.sync(self.cat, self.cfg, self.api)
        key = catalog.item_key(self.cat.account, "PrimarySync", "p649")
        self.assertEqual(catalog.matching_asset(self.personal, "p649").id, "p649")
        with patch.object(catalog, "cloud", side_effect=RuntimeError("session expired")):
            with self.assertRaisesRegex(RuntimeError, "session expired"):
                catalog.download(self.cat, self.cfg, key)
        self.assertIsNone(self.cat.get(key)["original"])
        self.assertEqual(self.cat.get(key)["state"], "failed")
        with self.assertRaisesRegex(RuntimeError, "Synthetic demo"):
            catalog.cloud({"DEMO": "1"})

    def test_old_cloud_delete_uses_stable_record_and_zone(self):
        catalog.sync(self.cat, self.cfg, self.api)
        key = catalog.item_key(self.cat.account, "PrimarySync", "p649")
        args = SimpleNamespace(key=key, file=None, companion=None, ts=None, shared=False,
                               record="p649", zone="PrimarySync")
        with patch.object(helper, "CACHE", self.cache), patch.object(helper, "connect", return_value=self.api), \
             patch.object(helper, "set_deleted", return_value="new-tag") as mutate:
            helper.cmd_delete(args, self.cfg)
        self.assertEqual(mutate.call_args.args[1:3], ("p649", "tag"))
        self.assertEqual(self.cat.get(key)["state"], "deleted")

    def test_existing_backup_recognized_but_not_deleted(self):
        original = Path(self.cfg["LIBRARY"]) / "2023" / "11" / "same.jpg"
        original.parent.mkdir(parents=True)
        original.write_bytes(b"legacy")
        import os
        os.utime(original, (1700000000, 1700000000))
        catalog.sync(self.cat, self.cfg, self.api)
        key = catalog.item_key(self.cat.account, "PrimarySync", "p0")
        self.assertEqual(self.cat.get(key)["original"], str(original))
        self.assertEqual(self.cat.get(key)["owned"], 0)
        catalog.evict(self.cat, [key])
        self.assertTrue(original.is_file())
        self.assertEqual(self.cat.get(key)["original"], str(original))

    def test_legacy_jpeg_live_photo_plain_mov_is_recognized(self):
        still = Path(self.cfg["LIBRARY"]) / "shared" / "2021" / "09" / "same.jpg"
        motion = still.with_suffix(".MOV")
        still.parent.mkdir(parents=True)
        still.write_bytes(b"legacy-still")
        motion.write_bytes(b"legacy-motion")
        import os
        ts = 1700000000 - 800 * 86400
        os.utime(still, (ts, ts))
        catalog.sync(self.cat, self.cfg, self.api)
        key = catalog.item_key(self.cat.account, "SharedSync-fabricated", "live")
        self.assertEqual(self.cat.get(key)["original"], str(still))
        self.assertEqual(self.cat.get(key)["motion"], str(motion))

    def test_eviction_waits_for_inflight_download_and_rejects_external_path(self):
        catalog.sync(self.cat, self.cfg, self.api)
        key = catalog.item_key(self.cat.account, "PrimarySync", "p0")
        entered, release = threading.Event(), threading.Event()
        asset = self.personal.assets[0]
        class SlowResponse(Response):
            def iter_content(self, chunk_size):
                entered.set()
                release.wait(3)
                yield b"original"
        with patch.object(asset, "download", return_value=SlowResponse(b"original")):
            def do_download():
                worker_cat = catalog.Catalog(self.cache, self.cat.account)
                try:
                    catalog.download(worker_cat, self.cfg, key, api=self.api)
                finally:
                    worker_cat.db.close()
            worker = threading.Thread(target=do_download)
            worker.start()
            self.assertTrue(entered.wait(2))
            evicted = threading.Event()
            def do_evict():
                worker_cat = catalog.Catalog(self.cache, self.cat.account)
                try:
                    catalog.evict(worker_cat, [key])
                finally:
                    worker_cat.db.close()
                    evicted.set()
            remover = threading.Thread(target=do_evict)
            remover.start()
            self.assertFalse(evicted.wait(0.05))
            release.set()
            worker.join(3); remover.join(3)
            self.assertTrue(evicted.is_set())
            self.assertIsNone(self.cat.get(key)["original"])
            self.assertEqual(list((self.cache / "originals" / key).glob("*")), [])
        unrelated_inside = self.cache / "originals" / key / "notes.txt"
        unrelated_inside.write_text("leave me")
        catalog.evict(self.cat, [key])
        self.assertEqual(unrelated_inside.read_text(), "leave me")
        outside = Path(self.tmp.name) / "unrelated.jpg"
        outside.write_bytes(b"leave me")
        with self.cat.db:
            self.cat.db.execute("UPDATE assets SET original=?, owned=1 WHERE id=?", (str(outside), key))
        catalog.evict(self.cat, [key])
        self.assertEqual(outside.read_bytes(), b"leave me")

    def test_open_photo_uses_medium_preview_without_original_fallback(self):
        catalog.sync(self.cat, self.cfg, self.api, max_items=1)
        key = catalog.item_key(self.cat.account, "PrimarySync", "p0")
        asset = self.personal.assets[0]
        before = list(self.personal.session.calls)
        self.assertIsNone(catalog.preview(self.cat, self.cfg, key, self.api))
        self.assertEqual(before, self.personal.session.calls)
        asset.versions[AssetVersionSize.MEDIUM] = AssetVersion(8, "medium:PrimarySync:p0", "image/jpeg", "")
        with patch.object(asset, "download", return_value=Response(b"original")) as fetch:
            path = catalog.preview(self.cat, self.cfg, key, self.api)
        self.assertTrue(Path(path).is_file())
        self.assertEqual(fetch.call_args.args[1], "medium:PrimarySync:p0")
        self.assertIsNone(self.cat.get(key)["original"])
        exported = json.loads((self.cache / "index.json").read_text())[0]
        self.assertEqual(exported["preview"], path)
        self.assertFalse(exported["downloaded"])
        self.assertEqual(catalog.preview(self.cat, self.cfg, key, self.api), path)
        self.assertEqual(fetch.call_count, 1)

    def test_download_modes_recent_retention_pin_and_explicit_eviction(self):
        catalog.sync(self.cat, self.cfg, self.api, max_items=3)
        now = self.cat.get(catalog.item_key(self.cat.account, "PrimarySync", "p0"))["ts"] + 86400
        first = catalog.item_key(self.cat.account, "PrimarySync", "p0")
        second = catalog.item_key(self.cat.account, "PrimarySync", "p1")
        self.assertEqual(catalog.apply_download_policy(self.cat, self.cfg, self.api, now=now), 0)
        (self.cache / "settings.json").write_text(json.dumps({"downloadMode": "recent", "recentDays": 2}))
        with patch.object(catalog.time, "sleep"):
            self.assertEqual(catalog.apply_download_policy(self.cat, self.cfg, self.api, limit=3, now=now), 2)
        self.assertTrue(self.cat.get(first)["original"])
        self.assertFalse(self.cat.get(first)["keep_offline"])
        # A user choice pins an automatically fetched original.
        catalog.download(self.cat, self.cfg, first, api=self.api)
        self.assertTrue(self.cat.get(first)["keep_offline"])
        before = list(self.personal.session.calls)
        catalog.evict(self.cat, [second])
        self.assertEqual(before, self.personal.session.calls)
        self.assertTrue(self.cat.get(second)["auto_excluded"])
        restarted = catalog.Catalog(self.cache, self.cat.account)
        self.addCleanup(restarted.db.close)
        with patch.object(catalog.time, "sleep"):
            self.assertEqual(catalog.apply_download_policy(restarted, self.cfg, self.api, now=now), 0)
            self.assertEqual(catalog.apply_download_policy(restarted, self.cfg, self.api, now=now + 10 * 86400), 0)
        self.assertTrue(restarted.get(first)["original"])
        self.assertIsNone(restarted.get(second)["original"])
        catalog.download(restarted, self.cfg, second, api=self.api)
        self.assertFalse(restarted.get(second)["auto_excluded"])
        self.assertTrue(restarted.get(second)["keep_offline"])

    def test_all_mode_includes_old_assets_and_live_motion(self):
        catalog.sync(self.cat, self.cfg, self.api)
        (self.cache / "settings.json").write_text(json.dumps({"downloadMode": "all"}))
        old = catalog.item_key(self.cat.account, "PrimarySync", "p649")
        live = catalog.item_key(self.cat.account, "SharedSync-fabricated", "live")
        # Keep the batch small and force the requested records to the front.
        with self.cat.db:
            self.cat.db.execute("UPDATE assets SET auto_excluded=1 WHERE id NOT IN (?,?)", (old, live))
        with patch.object(catalog.time, "sleep"):
            self.assertEqual(catalog.apply_download_policy(self.cat, self.cfg, self.api, limit=2), 2)
            self.assertEqual(catalog.apply_download_policy(self.cat, self.cfg, self.api, limit=2), 1)
        self.assertTrue(self.cat.get(old)["original"])
        self.assertTrue(self.cat.get(live)["original"])
        self.assertTrue(self.cat.get(live)["motion"])
        self.assertFalse(self.cat.get(live)["keep_offline"])

    def test_preview_expiry_keeps_thumbnail_and_catalog(self):
        catalog.sync(self.cat, self.cfg, self.api, max_items=1)
        key = catalog.item_key(self.cat.account, "PrimarySync", "p0")
        asset = self.personal.assets[0]
        asset.versions[AssetVersionSize.MEDIUM] = AssetVersion(8, "medium:PrimarySync:p0", "image/jpeg", "")
        path = Path(catalog.preview(self.cat, self.cfg, key, self.api))
        import os
        os.utime(path, (1, 1))
        catalog.expire_previews(self.cat)
        self.assertFalse(path.exists())
        self.assertTrue(Path(self.cat.get(key)["thumb"]).exists())
        self.assertEqual(len(json.loads((self.cache / "index.json").read_text())), 1)

    def test_switching_to_manual_removes_only_unpinned_app_originals(self):
        catalog.sync(self.cat, self.cfg, self.api, max_items=2)
        first = catalog.item_key(self.cat.account, "PrimarySync", "p0")
        second = catalog.item_key(self.cat.account, "PrimarySync", "p1")
        (self.cache / "settings.json").write_text(json.dumps({"downloadMode": "all"}))
        with patch.object(catalog.time, "sleep"):
            catalog.apply_download_policy(self.cat, self.cfg, self.api, limit=2)
        catalog.download(self.cat, self.cfg, first, api=self.api)  # explicit keep
        thumbnail = Path(self.cat.get(second)["thumb"])
        (self.cache / "settings.json").write_text(json.dumps({"downloadMode": "manual"}))
        catalog.apply_download_policy(self.cat, self.cfg, self.api)
        self.assertTrue(Path(self.cat.get(first)["original"]).exists())
        self.assertIsNone(self.cat.get(second)["original"])
        self.assertTrue(thumbnail.exists())
        self.assertFalse(self.cat.get(second)["auto_excluded"])

    def test_album_list_and_members_use_stable_ids_without_originals(self):
        catalog.sync(self.cat, self.cfg, self.api, max_items=230)
        self.personal.library_type = "private"
        self.personal.params = {}
        self.personal.service_endpoint = "https://fabricated.invalid"
        self.personal.zone_id = {"zoneName": "PrimarySync"}
        title = base64.b64encode(b"Fabricated Album").decode()
        self.personal._fetch_folders = lambda: [
            {"recordName": folder, "fields": {"albumNameEnc": {"value": title}}}
            for folder in ("folder-one", "folder-two")]
        catalog.refresh_albums(self.cat, self.cfg, self.api, force=True)
        rows = json.loads((self.cache / "album-index.json").read_text())
        self.assertEqual(len(rows), 2)
        self.assertEqual(rows[0]["title"], rows[1]["title"])
        self.assertNotEqual(rows[0]["id"], rows[1]["id"])
        with patch.object(catalog, "PhotoAlbum", side_effect=lambda *a, **k: self.personal.assets[:230]):
            catalog.load_album_members(self.cat, self.cfg, rows[0]["id"], self.api)
        members = json.loads((self.cache / "albums" / (rows[0]["id"] + ".json")).read_text())
        self.assertTrue(members["complete"])
        self.assertEqual(len(members["ids"]), 230)
        self.assertEqual(members["ids"][0], catalog.item_key(self.cat.account, "PrimarySync", "p0"))
        self.assertTrue(all(not x["downloaded"] for x in json.loads((self.cache / "index.json").read_text())))


if __name__ == "__main__":
    unittest.main()
