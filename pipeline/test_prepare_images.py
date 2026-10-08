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


class PrepareImagesSourceTest(unittest.TestCase):
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

    def _run(self, rows):
        conn = _FakeConn(rows)
        with mock.patch.object(prepare_images, "connect", lambda dsn=None: conn), \
                mock.patch.object(sys, "argv", ["prepare_images.py"]), \
                mock.patch("builtins.print"):
            prepare_images.main()
        with open(self.manifest_path, encoding="utf-8") as fh:
            manifest = json.load(fh)
        updates = [p for q, p in conn.cur.executed if q.startswith("update collected_products")]
        barcode_updates = [p for q, p in conn.cur.executed if q.startswith("update product_barcodes")]
        return manifest, updates, barcode_updates

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


if __name__ == "__main__":
    unittest.main()
