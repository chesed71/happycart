"""CoupangCrawler/output → collected_products (stage='parsed').

소스 병합:
  - <카테고리>/products*.json : productId, title, barcode(koreannet), image
  - <카테고리>/manual_ingredients_direct*.json : 육안 판독 원재료 (confidence 보유, 우선)
  - extracted_data/ingredients_*.json : {productId: 원재료 원문} (confidence 없음)

output/ 은 롯데마트제타 크롤러와 공유된다 — 그쪽 산출물은 아래 세 곳에서 걸러낸다:
  - <카테고리>/products*.json 의 zettaSku 보유 행 (적재는 자체 SQL 경로)
  - <카테고리>/manual_ingredients_direct*.json 중 쿠팡 형식(dict)이 아닌 파일
  - extracted_data/ 의 분석·리포트 JSON (ingredients_*.json 규칙으로 선별)

사용: .venv/bin/python extract_coupang.py [--dsn DSN] [--dry-run]
참고: docs/superpowers/specs/2026-06-11-local-db-data-ingestion-plan.md §4.1
"""
from __future__ import annotations

import argparse
import glob
import json
import os
import re
import unicodedata
from collections import Counter

from common import COUPANG_OUTPUT, COUNT_RE, SIZE_RE, connect, ean_valid, upsert_parsed


def nfc_category(folder_name: str | None) -> str | None:
    """category 컬럼용 NFC 정규화. macOS 파일시스템은 디렉터리명을 NFD로 돌려주므로
    그대로 넣으면 눈에 같은 카테고리가 NFC/NFD 두 값으로 쪼개진다(2026-10-06 운영 중복).
    raw.category_folder는 prepare_images가 파일 경로 조립에 쓰므로 원값을 유지한다."""
    return unicodedata.normalize("NFC", folder_name) if folder_name else folder_name


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
                # 같은 pid 가 여러 페이지에 있을 때 한쪽에만 zettaSku 가 있으면 출처 판정이
                # 파일 정렬 순서에 좌우된다 — 마커가 보이면 대표 객체로 올려 제외 쪽으로 고정.
                if "zettaSku" in p and "zettaSku" not in merged[pid]["product"]:
                    merged[pid]["product"]["zettaSku"] = p["zettaSku"]
                # 바코드는 어느 페이지든 있으면 채택 (koreannet 작업이 페이지 단위로 진행됨)
                if not merged[pid]["product"].get("barcode") and p.get("barcode"):
                    merged[pid]["product"]["barcode"] = p["barcode"]
    return merged


def split_zetta_rows(products: dict) -> tuple[dict, set]:
    """load_products 결과를 (쿠팡 행, 제외한 롯데마트제타 productId 집합) 로 가른다.

    롯데마트제타 상품 행은 zettaSku 를 갖는다. 그쪽은 crawl_lottemart_zetta.py 가 만드는
    적재 SQL로 collected_products 에 source='lottemartzetta' 로 들어가므로, 쿠팡 추출이
    가져가면 출처가 뒤바뀐다.

    폴더 단위로 판정하면(all) 한 행만 zettaSku 가 빠져도 폴더 전체가 쿠팡 경로로 넘어온다 —
    1천 행대 폴더가 통째로 오염되는 fail-open 이라 행 단위로 가른다. 쿠팡 행은 그대로 남으니
    혼재 폴더에서도 상품이 유실되지 않는다.
    """
    coupang = {pid: e for pid, e in products.items() if "zettaSku" not in e["product"]}
    return coupang, set(products) - set(coupang)


def load_manual_ingredients(folder: str, stats: Counter | None = None) -> dict:
    """manual_ingredients_direct*.json items → {productId: item}. 중복 시 뒤 파일 우선.

    롯데마트제타 크롤러가 같은 이름으로 최상위 list 를 쓴다(쿠팡은 {"items": [...]}).
    형식이 다른 파일은 세어서 건너뛴다 — 받아주면 다른 출처의 원재료를 조용히 먹는다.
    """
    out = {}
    for f in sorted(glob.glob(os.path.join(folder, "manual_ingredients_direct*.json"))):
        data = json.load(open(f))
        if not isinstance(data, dict):
            if stats is not None:
                stats["skipped_manual_not_coupang_shape"] += 1
            continue
        for item in data.get("items", []):
            pid = item.get("productId")
            if pid:
                out[str(pid)] = {**item, "_file": os.path.basename(f)}
    return out


# extracted_data에 섞여 있는 미판독 placeholder 텍스트
_PLACEHOLDER_RE = re.compile(r"^not found", re.IGNORECASE)


def load_extracted(output_root: str) -> dict:
    """extracted_data/ingredients_*.json → {productId: 원재료 원문}.

    extracted_data/ 에는 과거 세션의 분석·리포트 JSON과 롯데마트제타 적재 SQL도 쌓여 있다.
    파일명 규칙으로 원재료 파일만 고르고, 그래도 섞인 비문자열 값은 건너뛴다.
    """
    out = {}
    for f in sorted(glob.glob(os.path.join(output_root, "extracted_data", "ingredients_*.json"))):
        for pid, raw in json.load(open(f)).items():
            if not isinstance(raw, str) or not raw or _PLACEHOLDER_RE.match(raw.strip()):
                continue
            out[str(pid)] = {"ingredients": raw, "_file": os.path.basename(f)}
    return out


def build_rows(output_root: str) -> tuple[list[dict], Counter, list[str]]:
    """output_root 를 훑어 upsert 할 행 목록을 만든다. DB 접근 없음(테스트에서 직접 호출)."""
    extracted = load_extracted(output_root)
    stats = Counter()
    by_pid = {}  # 같은 상품이 여러 카테고리 폴더에 등장할 수 있다 — 명시적으로 병합

    candidates = sorted(
        d for d in os.listdir(output_root)
        if os.path.isdir(os.path.join(output_root, d)) and d != "extracted_data"
        and glob.glob(os.path.join(output_root, d, "products*.json"))
    )
    # output/ 은 롯데마트제타 크롤러와 공유된다 — 그쪽 상품 행은 여기서 뺀다.
    products_by_folder = {}
    zetta_pids: set[str] = set()  # 아래 고아 원재료 행에서도 막아야 한다
    for folder_name in candidates:
        products, skipped = split_zetta_rows(load_products(os.path.join(output_root, folder_name)))
        zetta_pids |= skipped
        stats["skipped_row_lottemartzetta"] += len(skipped)
        if not products:
            stats["skipped_folder_lottemartzetta"] += 1
            continue
        products_by_folder[folder_name] = products
    folders = list(products_by_folder)

    for folder_name in folders:
        folder = os.path.join(output_root, folder_name)
        manual = load_manual_ingredients(folder, stats)
        for pid, entry in products_by_folder[folder_name].items():
            p = entry["product"]
            brand, name, size = parse_title(p.get("title") or "")

            barcode = p.get("barcode")
            if barcode is not None:
                barcode = str(barcode)
                # UPC-A(12자리)는 앞에 0을 붙이면 동일 체크digit의 EAN-13(GTIN-13)이 된다.
                if len(barcode) == 12 and barcode.isdigit():
                    barcode = "0" + barcode
                    stats["barcode_upca_normalized"] += 1
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
                "source": "cp",
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
                "category": nfc_category(folder_name),
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
        dd = os.path.join(output_root, folder_name, "detail")
        if os.path.isdir(dd):
            for pid in os.listdir(dd):
                detail_folder.setdefault(pid, folder_name)
    for pid, ing in extracted.items():
        if pid in listed or not (ing.get("ingredients") or "").strip():
            continue
        # 목록에서 뺀 롯데마트제타 상품이 여기로 되살아나면 출처 필터를 우회한다.
        if pid in zetta_pids:
            stats["skipped_orphan_lottemartzetta"] += 1
            continue
        rows.append({
            "source": "cp",
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
            "category": nfc_category(detail_folder.get(pid)),
            "barcode": None,
            "ingredients_raw": ing["ingredients"],
            "confidence": None,
        })
        stats["rows"] += 1
        stats["orphan_ingredients"] += 1

    return rows, stats, folders


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dsn", default=None)
    ap.add_argument("--output-root", default=COUPANG_OUTPUT)
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    rows, stats, folders = build_rows(args.output_root)
    print(f"folders={len(folders)} {dict(stats)}")
    if args.dry_run:
        return
    with connect(args.dsn) as conn:
        upsert_parsed(conn, rows)
        with conn.cursor() as cur:
            cur.execute("select count(*) from collected_products where source='cp'")
            print(f"collected_products(coupang) = {cur.fetchone()[0]}")


if __name__ == "__main__":
    main()
