"""Phase 2.5 — 승격 바코드의 대표 이미지를 로컬에서 변환·정리 (§5).

승격된(stage='promoted', 바코드 확정) 행에 한해:
  1. 소스 이미지를 우선순위대로 찾는다
     쿠팡 detail(패키지 정면) > Koreannet images_page* > kakamuka detail > (쿠팡 CDN 썸네일은 보류)
  2. JPEG 로 변환 (PNG 알파는 흰 배경 합성), 512KB 이하로 압축 (Storage 버킷 제한)
  3. pipeline/work/images/products/<barcode>.jpg 로 정리
  4. collected_products.image_path 와 로컬 product_barcodes.image_source_url 갱신
     - lottemartzetta 는 수집/DB 원본 경로를 _uploads/*.png 로 유지하고,
       업로드용 JPG 는 manifest.local_path 에만 기록한다.
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
import re
from collections import Counter

from common import COUPANG_OUTPUT, KAKAMUKA_ROOT, connect

# 쿠팡 CDN 썸네일 박스 크기 — 서비스 대표 이미지를 고해상도로 받는다(원본이 크면 그만큼 선명).
_COUPANG_BOX = re.compile(r"/\d+x\d+(?:ex)?/")


def _upsize_coupang(url: str) -> str:
    if "coupangcdn" in url:
        return _COUPANG_BOX.sub("/512x512ex/", url, count=1)
    return url

WORK_DIR = os.path.join(os.path.dirname(__file__), "work", "images")
OUT_DIR = os.path.join(WORK_DIR, "products")
MANIFEST_PATH = os.path.join(WORK_DIR, "manifest.json")
STORAGE_BUCKET = "product-images"
MAX_BYTES = 524288  # 512KB — Storage 버킷 file_size_limit

_IMG_EXTS = (".jpg", ".jpeg", ".png", ".webp")


def _output_path(path: str | None) -> str | None:
    if not path:
        return None
    return path if os.path.isabs(path) else os.path.join(COUPANG_OUTPUT, path)


def _existing_image(path: str | None) -> str | None:
    candidate = _output_path(path)
    if candidate and os.path.exists(candidate) and candidate.lower().endswith(_IMG_EXTS):
        return candidate
    return None


def _http_url(value: str | None) -> str | None:
    if value and value.startswith(("http://", "https://")):
        return value
    return None


def _manual_upload(source: str, source_ref: str, barcode: str | None) -> str | None:
    """검수자가 데이터데스크에서 등록한 수동 이미지(_uploads/)를 찾는다 — 최우선 소스.
    이 행의 업로드(<source>__<source_ref>) 우선, 없으면 같은 바코드의 업로드(소스 무관)."""
    upl = os.path.join(COUPANG_OUTPUT, "_uploads")
    for ext in _IMG_EXTS:
        p = os.path.join(upl, f"{source}__{source_ref}{ext}")
        if os.path.exists(p):
            return p
    if barcode:
        for p in sorted(glob.glob(os.path.join(upl, f"*__{barcode}.*"))):
            if p.lower().endswith(_IMG_EXTS):
                return p
    return None


def _find_source_image(source: str, source_ref: str, raw: dict, image_path: str | None = None) -> str | None:
    """우선순위대로 로컬 소스 이미지 경로를 찾는다 (없으면 None)."""
    pid = str(source_ref)
    if source == "coupang":
        # 서비스 대표 이미지 = 상품 목록 대표 이미지(CDN 썸네일, 데스크에 보이는 그 이미지).
        # detail 스캔은 서비스 등록에 불필요하므로 CDN 을 우선한다.
        product = raw.get("product") or {}
        cdn = (
            _http_url(product.get("image"))
            or _http_url(product.get("image_url"))
            or _http_url(product.get("source_image_url"))
        )
        if cdn:
            return _upsize_coupang(cdn)
        # CDN 이 없을 때만 로컬 소스로 폴백 (Koreannet → detail 순).
        folder = raw.get("category_folder")
        folders = [folder] + list(raw.get("also_in_folders") or [])
        for f in filter(None, folders):
            base = os.path.join(COUPANG_OUTPUT, f)
            koreannet = sorted(glob.glob(os.path.join(base, "images_page*", f"*_{pid}.*")))
            koreannet = [p for p in koreannet if p.lower().endswith(_IMG_EXTS)]
            if koreannet:
                return koreannet[0]
            detail = sorted(glob.glob(os.path.join(base, "detail", pid, "*.jpg")))
            if detail:
                return detail[0]
    elif source == "kakamuka":
        detail = sorted(glob.glob(os.path.join(KAKAMUKA_ROOT, "**", "detail", pid, "*.jpg"),
                                  recursive=True))
        if detail:
            return detail[0]
    elif source == "lottemartzetta":
        product = raw.get("product") or {}
        zetta = raw.get("lottemartzetta") or {}
        for path in (product.get("image_path"), zetta.get("productImagePath"), image_path):
            found = _existing_image(path)
            if found:
                return found
    return None


def _to_jpeg(path: str) -> bytes:
    """이미지를 JPEG 로 변환 (알파는 흰 배경 합성), 512KB 이내로 압축.
    path 가 http(s) URL 이면 먼저 내려받는다 (CDN 대표 썸네일 지원)."""
    from PIL import Image

    if path.startswith(("http://", "https://")):
        import urllib.request

        req = urllib.request.Request(path, headers={"User-Agent": "Mozilla/5.0 (Macintosh)"})
        with urllib.request.urlopen(req, timeout=20) as r:
            img = Image.open(io.BytesIO(r.read()))
    else:
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
    ap.add_argument("--source", default=None)
    ap.add_argument("--source-ref", default=None)
    args = ap.parse_args()
    stats = Counter()
    manifest = []

    if not args.dry_run:
        os.makedirs(OUT_DIR, exist_ok=True)

    with connect(args.dsn) as conn, conn.cursor() as cur:
        query = """
            select source, source_ref, barcode, raw, raw->>'source_url', image_path
            from collected_products
            where stage = 'promoted' and barcode is not null
        """
        params = []
        if args.source:
            query += " and source = %s"
            params.append(args.source)
        if args.source_ref:
            query += " and source_ref = %s"
            params.append(args.source_ref)
        query += " order by source, source_ref"
        cur.execute(query, params)
        rows = cur.fetchall()

        for source, source_ref, barcode, raw, source_url, image_path in rows:
            raw = raw or {}
            # 수동 등록 이미지(_uploads)가 있으면 최우선 — CDN/detail 로 덮지 않는다.
            manual = _manual_upload(source, source_ref, barcode)
            src = manual or _find_source_image(source, source_ref, raw, image_path)
            if not src:
                stats["no_source_image"] += 1
                continue
            # 출처 기록용 CDN URL (벤더 썸네일). 로컬 변환 파일이 detail/Koreannet 이라도
            # 가용한 원본 URL 로 provenance 를 남긴다.
            product = raw.get("product") or {}
            zetta = raw.get("lottemartzetta") or {}
            cdn_url = (
                _http_url(product.get("image_url"))
                or _http_url(product.get("source_image_url"))
                or _http_url(product.get("image"))
                or _http_url(zetta.get("productImageUrl"))
                or source_url
            )

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
            # collected_products.image_path + 로컬 product_barcodes.image_source_url 갱신.
            # 수동 업로드면 image_path 를 _uploads/ 상대경로로 유지 — 데스크 썸네일·재실행이
            # 사람이 등록한 이미지를 계속 존중하도록(파이프라인 출력 경로로 덮지 않는다).
            stored_image_path = out_path
            if manual:
                stored_image_path = os.path.relpath(manual, COUPANG_OUTPUT)
            elif source == "lottemartzetta":
                stored_image_path = (
                    product.get("image_path")
                    or zetta.get("productImagePath")
                    or image_path
                )
            cur.execute("update collected_products set image_path = %s where source = %s and source_ref = %s",
                        (stored_image_path, source, source_ref))
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
