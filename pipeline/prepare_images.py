"""Phase 2.5 — 승격 바코드의 대표 이미지를 로컬에서 변환·정리 (§5).

승격된(stage='promoted', 바코드 확정) 행에 한해:
  1. 소스 이미지를 우선순위대로 찾는다
     쿠팡 detail(패키지 정면) > Koreannet images_page* > kakamuka detail > (쿠팡 CDN 썸네일은 보류)
  2. JPEG 로 변환 (PNG 알파는 흰 배경 합성), 512KB 이하로 압축 (Storage 버킷 제한)
  3. pipeline/work/images/products/<barcode>.jpg 로 정리
  4. collected_products.image_path 와 로컬 product_barcodes.image_source_url 갱신
  5. 이미지 manifest(work/images/manifest.json) 생성 — Phase 3(upload_prod.py)의 입력

image_url(Storage public URL)은 운영 업로드 성공 후 upload_prod.py 가 채운다.

사용: .venv/bin/python prepare_images.py [--dsn DSN] [--dry-run]
의존성: Pillow (requirements.txt)

참고: docs/superpowers/specs/2026-06-11-local-db-data-ingestion-plan.md §5
"""
from __future__ import annotations

import argparse
import glob
import hashlib
import io
import json
import os
from collections import Counter

from common import COUPANG_OUTPUT, KAKAMUKA_ROOT, connect

WORK_DIR = os.path.join(os.path.dirname(__file__), "work", "images")
OUT_DIR = os.path.join(WORK_DIR, "products")
MANIFEST_PATH = os.path.join(WORK_DIR, "manifest.json")
STORAGE_BUCKET = "product-images"
MAX_BYTES = 524288  # 512KB — Storage 버킷 file_size_limit

_IMG_EXTS = (".jpg", ".jpeg", ".png", ".webp")


def _find_source_image(source: str, source_ref: str, raw: dict) -> str | None:
    """우선순위대로 로컬 소스 이미지 경로를 찾는다 (없으면 None)."""
    pid = str(source_ref)
    if source == "coupang":
        folder = raw.get("category_folder")
        folders = [folder] + list(raw.get("also_in_folders") or [])
        for f in filter(None, folders):
            base = os.path.join(COUPANG_OUTPUT, f)
            # 1) 쿠팡 detail (패키지 정면)
            detail = sorted(glob.glob(os.path.join(base, "detail", pid, "*.jpg")))
            if detail:
                return detail[0]
            # 2) Koreannet images_page*/<rank>_<pid>.*
            koreannet = sorted(glob.glob(os.path.join(base, "images_page*", f"*_{pid}.*")))
            koreannet = [p for p in koreannet if p.lower().endswith(_IMG_EXTS)]
            if koreannet:
                return koreannet[0]
    elif source == "kakamuka":
        detail = sorted(glob.glob(os.path.join(KAKAMUKA_ROOT, "**", "detail", pid, "*.jpg"),
                                  recursive=True))
        if detail:
            return detail[0]
    return None


def _to_jpeg(path: str) -> bytes:
    """이미지를 JPEG 로 변환 (알파는 흰 배경 합성), 512KB 이내로 압축."""
    from PIL import Image

    img = Image.open(path)
    if img.mode in ("RGBA", "LA", "P"):
        bg = Image.new("RGB", img.size, (255, 255, 255))
        rgba = img.convert("RGBA")
        bg.paste(rgba, mask=rgba.split()[-1])
        img = bg
    elif img.mode != "RGB":
        img = img.convert("RGB")

    for quality in (90, 80, 70, 60, 50):
        buf = io.BytesIO()
        img.save(buf, format="JPEG", quality=quality)
        if buf.tell() <= MAX_BYTES:
            return buf.getvalue()
    return buf.getvalue()  # 50 에서도 초과하면 그대로 (드문 케이스 — 리포트로 드러남)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dsn", default=None)
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()
    stats = Counter()
    manifest = []

    if not args.dry_run:
        os.makedirs(OUT_DIR, exist_ok=True)

    with connect(args.dsn) as conn, conn.cursor() as cur:
        cur.execute("""
            select source, source_ref, barcode, raw, raw->>'source_url'
            from collected_products
            where stage = 'promoted' and barcode is not null
            order by source, source_ref
        """)
        rows = cur.fetchall()

        for source, source_ref, barcode, raw, source_url in rows:
            raw = raw or {}
            src = _find_source_image(source, source_ref, raw)
            if not src:
                stats["no_source_image"] += 1
                continue
            # 출처 기록용 CDN URL (벤더 썸네일). 로컬 변환 파일이 detail/Koreannet 이라도
            # 가용한 원본 URL 로 provenance 를 남긴다.
            cdn_url = (raw.get("product") or {}).get("image") or source_url

            out_path = os.path.join(OUT_DIR, f"{barcode}.jpg")
            if args.dry_run:
                stats["would_convert"] += 1
                continue

            try:
                data = _to_jpeg(src)
            except Exception as e:  # noqa: BLE001 — 한 건 실패가 전체를 막지 않게
                print(f"  convert 실패 {barcode} ({src}): {e}")
                stats["convert_failed"] += 1
                continue

            with open(out_path, "wb") as fh:
                fh.write(data)
            oversized = len(data) > MAX_BYTES
            if oversized:
                stats["oversized_after_50q"] += 1

            checksum = hashlib.sha256(data).hexdigest()
            # collected_products.image_path + 로컬 product_barcodes.image_source_url 갱신
            cur.execute("update collected_products set image_path = %s where source = %s and source_ref = %s",
                        (out_path, source, source_ref))
            cur.execute("update product_barcodes set image_source_url = %s where barcode = %s",
                        (cdn_url, barcode))

            manifest.append({
                "barcode": barcode,
                "source_image": src,
                "source_url": cdn_url,
                "local_path": out_path,
                "bytes": len(data),
                "sha256": checksum,
                "storage_target": f"products/{barcode}.jpg",
                "bucket": STORAGE_BUCKET,
                "oversized": oversized,
            })
            stats["prepared"] += 1

        if not args.dry_run:
            conn.commit()
            with open(MANIFEST_PATH, "w", encoding="utf-8") as fh:
                json.dump(manifest, fh, ensure_ascii=False, indent=2)

    print(f"\nprepare_images: {dict(stats)}")
    if not args.dry_run:
        print(f"manifest: {MANIFEST_PATH} ({len(manifest)}건)")
        print("→ Phase 3: upload_prod.py 가 이 manifest로 Storage 업로드 + image_url 갱신")


if __name__ == "__main__":
    main()
