"""DataCollector/kakamuka → collected_products (stage='parsed').

소스:
  - kakamuka/<폴더>/detail/<id>/info.json : 바코드·상품명·가격 등 (원재료 없음)
  - kakamuka/<폴더>/products.json : title·url·categories (목록 메타)
  - kakamuka/<폴더>/detail/<id>/*.jpg : 이미지

사용: .venv/bin/python extract_kakamuka.py [--dsn DSN] [--dry-run]
참고: docs/superpowers/specs/2026-06-11-local-db-data-ingestion-plan.md §4.2
"""
from __future__ import annotations

import argparse
import glob
import json
import os
from collections import Counter

from common import KAKAMUKA_ROOT, COUNT_RE, SIZE_RE, connect, ean_valid, upsert_parsed

# 분류 가치가 없는 진열용 카테고리
SKIP_CATEGORIES = {"신상품", "한정수량상품", "이달의추천상품"}


def parse_title(title: str):
    """kakamuka 상품명 → (brand, name, size).

    예: "오리온 다이제볼 42g" → ("오리온", "다이제볼", "42g")
    size 토큰은 뒤에서부터 찾고, 수량 토큰("4개" 등)이 붙으면 결합한다.
    """
    tokens = (title or "").split()
    if not tokens:
        return None, None, None

    size = None
    count = None
    rest = list(tokens)
    for t in reversed(tokens):
        norm = t.replace(" ", "")
        if size is None and SIZE_RE.fullmatch(norm):
            size = norm
            rest.remove(t)
        elif count is None and COUNT_RE.fullmatch(norm):
            count = norm
            rest.remove(t)
    if size and count:
        size = f"{size} × {count}"

    if len(rest) >= 2:
        brand, name = rest[0], " ".join(rest[1:])
    elif rest:
        brand, name = None, rest[0]
    else:
        brand, name = None, title
    return brand, name, size


def pick_category(categories: list) -> str | None:
    for c in categories or []:
        if c in SKIP_CATEGORIES or ">" in c:
            continue
        return c
    return None


def load_listing(root: str) -> dict:
    """폴더별 products.json → {productId: entry}."""
    out = {}
    for f in sorted(glob.glob(os.path.join(root, "*", "products.json"))):
        for p in json.load(open(f)):
            pid = p.get("productId")
            if pid and pid not in out:
                out[pid] = p
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dsn", default=None)
    ap.add_argument("--root", default=KAKAMUKA_ROOT)
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    listing = load_listing(args.root)
    stats = Counter()
    rows = []
    seen = set()

    for info_path in sorted(glob.glob(os.path.join(args.root, "*", "detail", "*", "info.json"))):
        info = json.load(open(info_path))
        pid = info.get("productId") or os.path.basename(os.path.dirname(info_path))
        if pid in seen:
            continue
        seen.add(pid)

        title = info.get("상품명") or (listing.get(pid) or {}).get("title") or ""
        brand, name, size = parse_title(title)

        barcode = info.get("바코드")
        if barcode is not None:
            barcode = str(barcode).strip()
            if not ean_valid(barcode):
                stats["barcode_invalid"] += 1
                barcode = None  # 검역 — 원값은 raw에 보존
            else:
                stats["barcode_valid"] += 1

        detail_dir = os.path.dirname(info_path)
        images = sorted(
            os.path.relpath(p, args.root)
            for p in glob.glob(os.path.join(detail_dir, "*.jpg"))
        )

        list_entry = listing.get(pid)
        if brand is None or size is None:
            stats["title_parse_partial"] += 1

        rows.append({
            "source": "kakamuka",
            "source_ref": pid,
            "raw": {
                "info": info,
                "listing": list_entry,
                "images": images,
                "source_url": info.get("url") or (list_entry or {}).get("url"),
            },
            "brand": brand,
            "name": name,
            "size": size,
            "category": pick_category((list_entry or {}).get("categories") or info.get("categories")),
            "barcode": barcode,
            "ingredients_raw": None,  # kakamuka에는 원재료 정보가 없다
            "confidence": None,
        })
        stats["rows"] += 1

    print(dict(stats))
    if args.dry_run:
        return
    with connect(args.dsn) as conn:
        upsert_parsed(conn, rows)
        with conn.cursor() as cur:
            cur.execute("select count(*) from collected_products where source='kakamuka'")
            print(f"collected_products(kakamuka) = {cur.fetchone()[0]}")


if __name__ == "__main__":
    main()
