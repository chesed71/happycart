"""CoupangCrawler/output → collected_products (stage='parsed').

소스 병합:
  - <카테고리>/products*.json : productId, title, barcode(koreannet), image
  - <카테고리>/manual_ingredients_direct*.json : 육안 판독 원재료 (confidence 보유, 우선)
  - extracted_data/*.json : {productId: 원재료 원문} (confidence 없음)

사용: .venv/bin/python extract_coupang.py [--dsn DSN] [--dry-run]
참고: docs/superpowers/specs/2026-06-11-local-db-data-ingestion-plan.md §4.1
"""
from __future__ import annotations

import argparse
import glob
import json
import os
import re
from collections import Counter

from common import COUPANG_OUTPUT, COUNT_RE, SIZE_RE, connect, ean_valid, upsert_parsed


def parse_title(title: str):
    """쿠팡 title → (brand, name, size). 파싱 실패 필드는 None (승격에서 걸러짐).

    예: "롯데웰푸드 칸쵸 초코, 54g, 4개" → ("롯데웰푸드", "칸쵸 초코", "54g × 4개")
    """
    parts = [p.strip() for p in title.split(",") if p.strip()]
    if not parts:
        return None, None, None

    name_part = parts[0]
    tokens = name_part.split()
    if len(tokens) >= 2:
        brand, name = tokens[0], " ".join(tokens[1:])
    else:
        brand, name = None, name_part

    size = None
    count = None
    for p in parts[1:]:
        if size is None and SIZE_RE.fullmatch(p.replace(" ", "")):
            size = p.replace(" ", "")
        elif count is None and COUNT_RE.fullmatch(p.replace(" ", "")):
            count = p.replace(" ", "")
    if size and count:
        size = f"{size} × {count}"
    return brand, name, size


def load_products(folder: str) -> dict:
    """카테고리 폴더의 products*.json을 productId 기준 dedup 병합."""
    merged = {}
    for f in sorted(glob.glob(os.path.join(folder, "products*.json"))):
        page = os.path.basename(f)
        for p in json.load(open(f)):
            pid = p.get("productId")
            if not pid:
                continue
            pid = str(pid)
            if pid not in merged:
                merged[pid] = {"product": p, "pages": [page]}
            else:
                merged[pid]["pages"].append(page)
                # 바코드는 어느 페이지든 있으면 채택 (koreannet 작업이 페이지 단위로 진행됨)
                if not merged[pid]["product"].get("barcode") and p.get("barcode"):
                    merged[pid]["product"]["barcode"] = p["barcode"]
    return merged


def load_manual_ingredients(folder: str) -> dict:
    """manual_ingredients_direct*.json items → {productId: item}. 중복 시 뒤 파일 우선."""
    out = {}
    for f in sorted(glob.glob(os.path.join(folder, "manual_ingredients_direct*.json"))):
        data = json.load(open(f))
        for item in data.get("items", []):
            pid = item.get("productId")
            if pid:
                out[str(pid)] = {**item, "_file": os.path.basename(f)}
    return out


# extracted_data에 섞여 있는 미판독 placeholder 텍스트
_PLACEHOLDER_RE = re.compile(r"^not found", re.IGNORECASE)


def load_extracted(output_root: str) -> dict:
    out = {}
    for f in sorted(glob.glob(os.path.join(output_root, "extracted_data", "*.json"))):
        for pid, raw in json.load(open(f)).items():
            if not raw or _PLACEHOLDER_RE.match(raw.strip()):
                continue
            out[str(pid)] = {"ingredients": raw, "_file": os.path.basename(f)}
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dsn", default=None)
    ap.add_argument("--output-root", default=COUPANG_OUTPUT)
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    extracted = load_extracted(args.output_root)
    stats = Counter()
    by_pid = {}  # 같은 상품이 여러 카테고리 폴더에 등장할 수 있다 — 명시적으로 병합

    folders = sorted(
        d for d in os.listdir(args.output_root)
        if os.path.isdir(os.path.join(args.output_root, d)) and d != "extracted_data"
        and glob.glob(os.path.join(args.output_root, d, "products*.json"))
    )
    for folder_name in folders:
        folder = os.path.join(args.output_root, folder_name)
        manual = load_manual_ingredients(folder)
        for pid, entry in load_products(folder).items():
            p = entry["product"]
            brand, name, size = parse_title(p.get("title") or "")

            barcode = p.get("barcode")
            if barcode is not None:
                barcode = str(barcode)
                if not ean_valid(barcode):
                    stats["barcode_invalid"] += 1
                    barcode = None  # 검역 — 원값은 raw에 보존
                else:
                    stats["barcode_valid"] += 1

            # manual 파일에는 미판독 placeholder(ingredients가 None/빈 문자열)가
            # 다수 포함돼 있다 — 실제 값이 있는 항목만 원재료로 인정한다.
            m = manual.get(pid)
            ing_extracted = extracted.get(pid)
            if m and (m.get("ingredients") or "").strip():
                ingredients_raw = m["ingredients"].strip()
                confidence = m.get("confidence")
                stats["ingredients_manual"] += 1
            elif ing_extracted and (ing_extracted.get("ingredients") or "").strip():
                ingredients_raw = ing_extracted["ingredients"].strip()
                confidence = None
                stats["ingredients_extracted"] += 1
            else:
                ingredients_raw, confidence = None, None

            if brand is None or size is None:
                stats["title_parse_partial"] += 1

            row = {
                "source": "coupang",
                "source_ref": pid,
                "raw": {
                    "category_folder": folder_name,
                    "also_in_folders": [],
                    "product": p,
                    "pages": entry["pages"],
                    "ingredients_manual": m,
                    "ingredients_extracted": ing_extracted,
                    "source_url": f"https://www.coupang.com/vp/products/{pid}",
                },
                "brand": brand,
                "name": name,
                "size": size,
                "category": folder_name,
                "barcode": barcode,
                "ingredients_raw": ingredients_raw,
                "confidence": confidence,
            }
            cur = by_pid.get(pid)
            if cur is None:
                by_pid[pid] = row
                stats["rows"] += 1
            else:
                # 폴더 간 중복: 첫 폴더를 대표로 두고 빠진 필드만 보충
                stats["cross_folder_dup"] += 1
                cur["raw"]["also_in_folders"].append(folder_name)
                if cur["barcode"] is None and barcode is not None:
                    cur["barcode"] = barcode
                if cur["ingredients_raw"] is None and ingredients_raw is not None:
                    cur["ingredients_raw"] = ingredients_raw
                    cur["confidence"] = confidence
                    cur["raw"]["ingredients_manual"] = m
                    cur["raw"]["ingredients_extracted"] = ing_extracted

    # 목록 밖 원재료 (products*.json에 없지만 extracted_data에 원재료가 있는 pid).
    # title·바코드가 없어 승격은 불가하지만 원재료 자산으로 보존 — 추후 보강 대상.
    rows = list(by_pid.values())
    listed = set(by_pid)
    detail_folder = {}
    for folder_name in folders:
        dd = os.path.join(args.output_root, folder_name, "detail")
        if os.path.isdir(dd):
            for pid in os.listdir(dd):
                detail_folder.setdefault(pid, folder_name)
    for pid, ing in extracted.items():
        if pid in listed or not (ing.get("ingredients") or "").strip():
            continue
        rows.append({
            "source": "coupang",
            "source_ref": pid,
            "raw": {
                "category_folder": detail_folder.get(pid),
                "product": None,
                "ingredients_manual": None,
                "ingredients_extracted": ing,
                "source_url": f"https://www.coupang.com/vp/products/{pid}",
                "orphan": True,  # products 목록에 없음
            },
            "brand": None,
            "name": None,
            "size": None,
            "category": detail_folder.get(pid),
            "barcode": None,
            "ingredients_raw": ing["ingredients"],
            "confidence": None,
        })
        stats["rows"] += 1
        stats["orphan_ingredients"] += 1

    print(f"folders={len(folders)} {dict(stats)}")
    if args.dry_run:
        return
    with connect(args.dsn) as conn:
        upsert_parsed(conn, rows)
        with conn.cursor() as cur:
            cur.execute("select count(*) from collected_products where source='coupang'")
            print(f"collected_products(coupang) = {cur.fetchone()[0]}")


if __name__ == "__main__":
    main()
