"""prepare_images 의 소스 이미지 선택 회귀 테스트 (DB·네트워크 불필요).

Koreannet 신규 행(source='kn')은 수동 업로드(_uploads/)가 있으면 그것을, 없으면 raw.kn.image_url
(Koreannet photoView 앞면 사진)을 내려받아 쓴다. 기존 cp 경로(상품목록 CDN 썸네일 우선)는 그대로다.

helper 단위 테스트만 두면 호출부에서 분기가 빠져도 통과하므로, 가짜 DB 연결과 가짜 내려받기로
main()(행 조회 → 소스 선택 → JPEG 변환 → image_path 갱신 → manifest) 전체를 돌린다.

사용: pipeline/.venv/bin/python -m unittest test_prepare_images -v
"""
from __future__ import annotations

import io
import json
import os
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

from PIL import Image

import prepare_images

KN_REF = "8801117789206"
KN_URL = (
    "https://www.koreannet.or.kr/front/allproduct/photoView.do"
    f"?gtin={KN_REF}&fileName={KN_REF}_250.png"
)


def _png_bytes() -> bytes:
    buf = io.BytesIO()
    Image.new("RGBA", (4, 4), (255, 0, 0, 128)).save(buf, format="PNG")
    return buf.getvalue()


class _FakeCursor:
    def __init__(self, rows):
        self.rows = rows
        self.executed = []

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False

    def execute(self, query, params=None):
        self.executed.append((" ".join(query.split()), params))

    def fetchall(self):
        return self.rows


class _FakeConn:
    def __init__(self, rows):
        self.cur = _FakeCursor(rows)
        self.committed = False

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False

    def cursor(self):
        return self.cur

    def commit(self):
        self.committed = True


class _PrepareImagesBase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = self.tmp.name
        self.output = os.path.join(root, "output")
        os.makedirs(os.path.join(self.output, "_uploads"))
        work = os.path.join(root, "work")
        self.out_dir = os.path.join(work, "products")
        self.manifest_path = os.path.join(work, "manifest.json")
        self.fetched = []

        def fake_fetch(url):
            self.fetched.append(url)
            return _png_bytes()

        for target, value in (
            ("COUPANG_OUTPUT", self.output),
            ("OUT_DIR", self.out_dir),
            ("MANIFEST_PATH", self.manifest_path),
            ("_fetch_url", fake_fetch),
        ):
            p = mock.patch.object(prepare_images, target, value)
            p.start()
            self.addCleanup(p.stop)

    def tearDown(self):
        self.tmp.cleanup()

    def _run(self, rows, extra_argv=()):
        # 조회 열 끝에 id 가 있다 — 6열로 준 행은 id 없음(None)으로 채운다.
        rows = [r if len(r) == 7 else tuple(r) + (None,) for r in rows]
        conn = _FakeConn(rows)
        with mock.patch.object(prepare_images, "connect", lambda dsn=None: conn), \
                mock.patch.object(sys, "argv", ["prepare_images.py", *extra_argv]), \
                mock.patch("builtins.print"):
            prepare_images.main()
        with open(self.manifest_path, encoding="utf-8") as fh:
            manifest = json.load(fh)
        updates = [p for q, p in conn.cur.executed if q.startswith("update collected_products")]
        barcode_updates = [p for q, p in conn.cur.executed if q.startswith("update product_barcodes")]
        self.conn = conn
        return manifest, updates, barcode_updates


class PrepareImagesSourceTest(_PrepareImagesBase):
    def test_kn_row_without_manual_upload_downloads_koreannet_image(self):
        raw = {"kn": {"name": "새우깡", "image_url": KN_URL}}
        manifest, updates, barcode_updates = self._run([("kn", KN_REF, KN_REF, raw, None, None)])
        self.assertEqual(self.fetched, [KN_URL])
        self.assertEqual(len(manifest), 1)
        entry = manifest[0]
        self.assertEqual(entry["source_image"], KN_URL)
        self.assertEqual(entry["source_url"], KN_URL)
        out_path = os.path.join(self.out_dir, f"{KN_REF}.jpg")
        self.assertEqual(entry["local_path"], out_path)
        self.assertTrue(os.path.exists(out_path))
        with Image.open(out_path) as img:
            self.assertEqual(img.format, "JPEG")
        self.assertEqual(updates, [(out_path, "kn", KN_REF)])
        self.assertEqual(barcode_updates, [(KN_URL, KN_REF)])

    def test_kn_row_with_manual_upload_uses_manual_image(self):
        manual = os.path.join(self.output, "_uploads", f"kn__{KN_REF}.png")
        with open(manual, "wb") as fh:
            fh.write(_png_bytes())
        raw = {"kn": {"name": "새우깡", "image_url": KN_URL}}
        manifest, updates, _ = self._run([("kn", KN_REF, KN_REF, raw, None, None)])
        self.assertEqual(self.fetched, [])
        self.assertEqual(manifest[0]["source_image"], manual)
        # 수동 업로드는 image_path 를 _uploads/ 상대경로로 유지한다(기존 규칙).
        self.assertEqual(updates, [(f"_uploads/kn__{KN_REF}.png", "kn", KN_REF)])

    def test_kn_row_without_image_url_has_no_source(self):
        manifest, updates, _ = self._run([("kn", KN_REF, KN_REF, {"kn": {"name": "x"}}, None, None)])
        self.assertEqual(manifest, [])
        self.assertEqual(updates, [])
        self.assertEqual(self.fetched, [])

    def test_kn_image_url_must_be_http(self):
        raw = {"kn": {"image_url": "/etc/passwd"}}
        manifest, _, _ = self._run([("kn", KN_REF, KN_REF, raw, None, None)])
        self.assertEqual(manifest, [])
        self.assertEqual(self.fetched, [])

    def test_kn_download_failure_skips_row_and_continues(self):
        other = "8801117788704"
        other_url = KN_URL.replace(KN_REF, other)

        def flaky_fetch(url):
            self.fetched.append(url)
            if url == KN_URL:
                raise OSError("HTTP Error 404")
            return _png_bytes()

        with mock.patch.object(prepare_images, "_fetch_url", flaky_fetch):
            manifest, updates, barcode_updates = self._run([
                ("kn", KN_REF, KN_REF, {"kn": {"image_url": KN_URL}}, None, None),
                ("kn", other, other, {"kn": {"image_url": other_url}}, None, None),
            ])
        # 실패한 행은 건너뛰고(manifest·image_path 갱신 없음) 다음 행은 처리한다.
        self.assertEqual(self.fetched, [KN_URL, other_url])
        self.assertEqual([e["barcode"] for e in manifest], [other])
        self.assertEqual(updates, [(os.path.join(self.out_dir, f"{other}.jpg"), "kn", other)])
        self.assertEqual(barcode_updates, [(other_url, other)])
        self.assertFalse(os.path.exists(os.path.join(self.out_dir, f"{KN_REF}.jpg")))

    def test_cp_row_unchanged_uses_upsized_cdn_thumbnail(self):
        cdn = "https://thumbnail6.coupangcdn.com/thumbnails/remote/230x230ex/image/a.jpg"
        raw = {"product": {"image": cdn}, "kn": {"image_url": KN_URL}}
        manifest, updates, barcode_updates = self._run(
            [("cp", "123", "8801043014809", raw, "https://www.coupang.com/vp/products/123", None)]
        )
        upsized = cdn.replace("/230x230ex/", "/512x512ex/")
        self.assertEqual(self.fetched, [upsized])
        self.assertEqual(manifest[0]["source_image"], upsized)
        self.assertEqual(manifest[0]["source_url"], cdn)
        out_path = os.path.join(self.out_dir, "8801043014809.jpg")
        self.assertEqual(updates, [(out_path, "cp", "123")])
        self.assertEqual(barcode_updates, [(cdn, "8801043014809")])


ID_A = "11111111-1111-1111-1111-111111111111"
ID_Y = "22222222-2222-2222-2222-222222222222"
ID_Z = "33333333-3333-3333-3333-333333333333"
BC_X = "8801000000017"
BC_Y = "8801000000024"
BC_Z = "8801000000031"


def _entry(barcode):
    return {"barcode": barcode, "source_image": "old", "source_url": None,
            "local_path": f"/old/{barcode}.jpg", "bytes": 1, "sha256": "0",
            "storage_target": f"products/{barcode}.jpg", "bucket": "product-images",
            "oversized": False}


def _row(barcode, row_id, with_url=True):
    raw = {"kn": {"image_url": KN_URL.replace(KN_REF, barcode)}} if with_url else {"kn": {}}
    return ("kn", barcode, barcode, raw, None, None, row_id)


class PrepareImagesIdsTest(_PrepareImagesBase):
    def _seed_manifest(self, *barcodes):
        os.makedirs(os.path.dirname(self.manifest_path), exist_ok=True)
        with open(self.manifest_path, "w", encoding="utf-8") as fh:
            json.dump([_entry(b) for b in barcodes], fh)

    def test_query_is_scoped_by_ids(self):
        self._run([_row(BC_Y, ID_Y)], ["--ids", ID_A])
        selects = [(q, p) for q, p in self.conn.cur.executed if q.startswith("select")]
        self.assertEqual(len(selects), 1)
        q, params = selects[0]
        self.assertIn("id = any", q)
        self.assertIn([ID_A], params)

    def test_unrelated_manifest_entry_is_kept(self):
        self._seed_manifest(BC_X)
        manifest, _, _ = self._run([_row(BC_Y, ID_Y)], ["--ids", ID_Y])
        self.assertEqual([e["barcode"] for e in manifest], [BC_X, BC_Y])

    def test_two_runs_with_different_ids_keep_both(self):
        self._run([_row(BC_Y, ID_Y)], ["--ids", ID_Y])
        manifest, _, _ = self._run([_row(BC_Z, ID_Z)], ["--ids", ID_Z])
        self.assertEqual([e["barcode"] for e in manifest], [BC_Y, BC_Z])

    def test_missing_source_removes_old_entry(self):
        self._seed_manifest(BC_X, BC_Y)
        manifest, _, _ = self._run([_row(BC_Y, ID_Y, with_url=False)], ["--ids", ID_Y])
        self.assertEqual([e["barcode"] for e in manifest], [BC_X])

    def test_convert_failure_removes_old_entry(self):
        self._seed_manifest(BC_X, BC_Y)
        with mock.patch.object(prepare_images, "_to_jpeg", side_effect=OSError("boom")):
            manifest, _, _ = self._run([_row(BC_Y, ID_Y)], ["--ids", ID_Y])
        self.assertEqual([e["barcode"] for e in manifest], [BC_X])

    def test_success_replaces_entry_in_place(self):
        self._seed_manifest(BC_Y, BC_X)
        manifest, _, _ = self._run([_row(BC_Y, ID_Y)], ["--ids", ID_Y])
        self.assertEqual([e["barcode"] for e in manifest], [BC_Y, BC_X])
        self.assertNotEqual(manifest[0]["source_image"], "old")

    def test_without_ids_manifest_is_rewritten_fully(self):
        self._seed_manifest(BC_X)
        manifest, _, _ = self._run([_row(BC_Y, ID_Y)])
        self.assertEqual([e["barcode"] for e in manifest], [BC_Y])
        selects = [q for q, _ in self.conn.cur.executed if q.startswith("select")]
        self.assertNotIn("id = any", selects[0])

    def test_dry_run_with_ids_does_not_write_manifest(self):
        self._seed_manifest(BC_X)
        with open(self.manifest_path, encoding="utf-8") as fh:
            before = fh.read()
        self._run([_row(BC_Y, ID_Y)], ["--ids", ID_Y, "--dry-run"])
        with open(self.manifest_path, encoding="utf-8") as fh:
            self.assertEqual(fh.read(), before)

    def test_merge_manifest_function(self):
        existing = [_entry(BC_X), _entry(BC_Y)]
        prepared = [dict(_entry(BC_Z), bytes=9)]
        merged = prepare_images.merge_manifest(existing, prepared, {BC_Y})
        self.assertEqual([e["barcode"] for e in merged], [BC_X, BC_Z])
        self.assertEqual(merged[1]["bytes"], 9)

    def test_empty_ids_exits_2(self):
        r = subprocess.run([sys.executable, "prepare_images.py", "--ids", " , "],
                           cwd=os.path.dirname(os.path.abspath(__file__)),
                           capture_output=True, text=True)
        self.assertEqual(r.returncode, 2)


class PrepareImagesIdsDbTest(unittest.TestCase):
    """지정하지 않은 행의 image_path 는 건드리지 않는다 (테스트 DB 전용, 연결 안 되면 skip)."""

    def setUp(self):
        import testdb

        self.testdb = testdb
        try:
            self.conn = testdb.connect_test(testdb.source_dsn(), autocommit=True)
        except Exception as e:  # noqa: BLE001
            self.skipTest(f"테스트 DB 연결 불가: {e}")
        self.addCleanup(self.conn.close)
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.refs = ["TPI-A", "TPI-B"]
        self.barcodes = ["8809990000011", "8809990000028"]
        self._cleanup_rows()
        self.addCleanup(self._cleanup_rows)

    def _cleanup_rows(self):
        self.conn.execute("delete from collected_products where source_ref like 'TPI-%'")
        self.conn.execute("delete from product_barcodes where barcode = any(%s)", (self.barcodes,))

    def test_only_target_row_image_path_changes(self):
        output = os.path.join(self.tmp.name, "output")
        os.makedirs(os.path.join(output, "_uploads"))
        ids = []
        for ref, bc in zip(self.refs, self.barcodes):
            with open(os.path.join(output, "_uploads", f"cp__{ref}.png"), "wb") as fh:
                fh.write(_png_bytes())
            row = self.conn.execute(
                "insert into collected_products (source, source_ref, raw, barcode, stage, image_path)"
                " values ('cp', %s, '{}'::jsonb, %s, 'promoted', %s) returning id",
                (ref, bc, f"old/{ref}.jpg"),
            ).fetchone()
            ids.append(str(row[0]))
        work = os.path.join(self.tmp.name, "work")
        manifest_path = os.path.join(work, "manifest.json")
        with mock.patch.object(prepare_images, "COUPANG_OUTPUT", output), \
                mock.patch.object(prepare_images, "OUT_DIR", os.path.join(work, "products")), \
                mock.patch.object(prepare_images, "MANIFEST_PATH", manifest_path), \
                mock.patch.object(sys, "argv", ["prepare_images.py", "--dsn",
                                                self.testdb.source_dsn(), "--ids", ids[0]]), \
                mock.patch("builtins.print"):
            prepare_images.main()
        paths = dict(self.conn.execute(
            "select source_ref, image_path from collected_products where source_ref like 'TPI-%'"
        ).fetchall())
        self.assertEqual(paths["TPI-A"], "_uploads/cp__TPI-A.png")
        self.assertEqual(paths["TPI-B"], "old/TPI-B.jpg")
        with open(manifest_path, encoding="utf-8") as fh:
            self.assertEqual([e["barcode"] for e in json.load(fh)], [self.barcodes[0]])


if __name__ == "__main__":
    unittest.main()
