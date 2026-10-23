"""Synthetic cloud contract tests. These never authenticate or touch a live account."""
import importlib.util
import json
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
        return Response(b"thumb" if url.startswith("thumb:") else b"original" if url.startswith("original:") else b"motion")

    @property
    def item_type(self):
        return AssetItemType.MOVIE if self.kind == "video" else AssetItemType.IMAGE

    @property
    def created(self):
        return datetime.fromtimestamp(self._asset_record["fields"]["assetDate"]["value"] / 1000, timezone.utc)

    @property
    def size(self):
        return 8


class Library:
    def __init__(self, assets):
        self.assets = assets
        self.session = type("Session", (), {"calls": []})()
        self.pages = 0

    @property
    def all(self):
        # Emulate a cloud album with 100-item pages.
        for start in range(0, len(self.assets), 100):
            self.pages += 1
            yield from self.assets[start:start + 100]


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
        count = catalog.sync(self.cat, self.cfg, self.api)
        self.assertEqual(count, 652)
        self.assertEqual(self.personal.pages, 14)  # metadata, then fresh thumbnail URLs
        self.assertEqual(self.cat.db.execute("SELECT COUNT(*) FROM assets").fetchone()[0], 652)
        self.assertTrue(self.cat.get(catalog.item_key(self.cat.account, "PrimarySync", "p649"))["ts"] < 1700000000 - 30 * 86400)
        self.assertNotEqual(catalog.item_key(self.cat.account, "PrimarySync", "p0"),
                            catalog.item_key(self.cat.account, "SharedSync-fabricated", "p0"))
        calls = self.personal.session.calls + self.shared.session.calls
        self.assertTrue(calls)
        self.assertTrue(all(url.startswith("thumb:") for url in calls))
        missing = self.cat.get(catalog.item_key(self.cat.account, "SharedSync-fabricated", "live"))
        self.assertIsNone(missing["thumb"])
        self.assertIsNone(missing["location"])
        self.assertIsNone(missing["timezone"])

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
        self.assertEqual(len(first_transfer[0]), 652)
        self.assertTrue(all(not item["downloaded"] and not item["thumb"] for item in first_transfer[0]))

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
        with patch.object(catalog.subprocess, "run", return_value=SimpleNamespace(stdout="arib-std-b67")), \
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


if __name__ == "__main__":
    unittest.main()
