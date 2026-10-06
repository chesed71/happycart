"""extract_coupang 의 출처 선별·정규화 회귀 테스트 (DB 불필요).

output/ 이 롯데마트제타 크롤러와 공유되면서 생긴 세 가지 오염을 막는 장치를 검증한다:
  - zettaSku 보유 행을 쿠팡 추출에서 제외 (source 뒤바뀜 방지)
  - manual_ingredients_direct*.json 중 쿠팡 형식(dict)이 아닌 파일 건너뛰기
  - extracted_data/ 의 분석·리포트 JSON 대신 ingredients_*.json 만 읽기
그리고 category 컬럼의 NFC 정규화(macOS 디렉터리명은 NFD)를 확인한다.

helper 단위 테스트만 두면 호출부에서 필터가 빠져도 통과하므로, 임시 output 트리를 만들어
build_rows(폴더 탐색 → load_products → 출처 선별 → manual 회피 → 행 생성) 전체를 돌린다.

사용: pipeline/.venv/bin/python test_extract_coupang.py
"""
from __future__ import annotations

import json
import os
import sys
import tempfile
import unicodedata
from collections import Counter

from extract_coupang import (
    build_rows,
    load_extracted,
    load_manual_ingredients,
    nfc_category,
    split_zetta_rows,
)

results = []


def check(name, cond, detail=""):
    results.append((name, cond, detail))


def _folder(*products):
    """load_products 반환 형태({pid: {"product": ...}})로 감싼다."""
    return {str(p["productId"]): {"product": p, "pages": ["products.json"]} for p in products}


def test_zetta_rows_all_excluded():
    zetta = _folder(
        {"productId": "8801392177118", "zettaSku": "OS8801392177118", "title": "햇반 (500ML)"},
        {"productId": "8801392177119", "zettaSku": "OS8801392177119", "title": "햇반 (200ML)"},
    )
    kept, skipped = split_zetta_rows(zetta)
    check("zettaSku 행은 전부 제외",
          kept == {} and skipped == {"8801392177118", "8801392177119"},
          f"kept={len(kept)} skipped={skipped}")


def test_coupang_rows_kept():
    coupang = _folder(
        {"productId": "9355738365", "title": "롯데웰푸드 칸쵸 초코, 54g, 4개", "barcode": None},
        {"productId": "9355738366", "title": "오리온 초코파이, 12개", "barcode": None},
    )
    kept, skipped = split_zetta_rows(coupang)
    check("쿠팡 행은 남는다", sorted(kept) == ["9355738365", "9355738366"] and skipped == set())


def test_empty_folder():
    check("빈 폴더는 (빈 결과, 빈 집합)", split_zetta_rows({}) == ({}, set()))


def test_mixed_folder_splits_per_row():
    # 폴더 단위 all() 판정은 zettaSku 가 한 행만 빠져도 폴더 전체를 쿠팡으로 넘기는 fail-open 이다.
    mixed = _folder(
        {"productId": "8801392177118", "zettaSku": "OS8801392177118", "title": "햇반"},
        {"productId": "9355738365", "title": "칸쵸"},
    )
    kept, skipped = split_zetta_rows(mixed)
    check(
        "혼재 폴더는 행 단위로 갈린다(제타 제외·쿠팡 보존)",
        sorted(kept) == ["9355738365"] and skipped == {"8801392177118"},
        f"kept={sorted(kept)} skipped={skipped}",
    )


def test_zetta_marker_wins_over_page_order():
    """같은 pid 가 여러 페이지에 있고 한쪽에만 zettaSku 가 있으면 제외 쪽으로 고정된다.

    load_products 는 첫 객체만 대표로 남기므로, 마커를 올리지 않으면 파일 정렬 순서가
    출처를 결정한다.
    """
    import extract_coupang
    with tempfile.TemporaryDirectory() as folder:
        # page1 에는 마커 없음, page2 에만 있음 — 정렬상 page1 이 대표가 된다.
        _write(os.path.join(folder, "products_page1.json"),
               [{"productId": "8801392177118", "title": "햇반"}])
        _write(os.path.join(folder, "products_page2.json"),
               [{"productId": "8801392177118", "zettaSku": "OS8801392177118", "title": "햇반"}])
        kept, skipped = split_zetta_rows(extract_coupang.load_products(folder))
        check("뒤 페이지의 zettaSku 도 제외로 반영", kept == {} and skipped == {"8801392177118"},
              f"kept={sorted(kept)} skipped={skipped}")


def test_manual_skips_non_coupang_shape():
    # 롯데마트제타 crawler 는 같은 파일명으로 최상위 list 를 쓴다 — dict.get 으로 읽으면 터진다.
    with tempfile.TemporaryDirectory() as folder:
        with open(os.path.join(folder, "manual_ingredients_direct_page1.json"), "w") as f:
            json.dump([{"productId": "8801392177118", "ingredients": "쌀"}], f)
        with open(os.path.join(folder, "manual_ingredients_direct_page2.json"), "w") as f:
            json.dump({"items": [{"productId": "9355738365", "ingredients": "밀가루, 설탕"}]}, f)
        stats = Counter()
        out = load_manual_ingredients(folder, stats)
        check("list 형식 manual 은 건너뛴다", sorted(out) == ["9355738365"], f"got {sorted(out)}")
        check("건너뛴 manual 을 센다", stats["skipped_manual_not_coupang_shape"] == 1)


def test_load_extracted_picks_ingredients_only():
    with tempfile.TemporaryDirectory() as root:
        d = os.path.join(root, "extracted_data")
        os.makedirs(d)
        with open(os.path.join(d, "ingredients_snack_batch1.json"), "w") as f:
            json.dump({"9355738365": "밀가루, 설탕", "9355738366": "not found"}, f)
        # 과거 세션 리포트: 값이 dict/list/int 라 그대로 읽으면 AttributeError 로 죽는다.
        with open(os.path.join(d, "collection_db_gap_2026-06-29.json"), "w") as f:
            json.dump({"과자_초콜릿_시리얼": {"absentFromDb": 146}, "generatedAt": "2026-06-29"}, f)
        with open(os.path.join(d, "vision_ingredient_candidates.json"), "w") as f:
            json.dump({"count": 3, "items": [{"productId": "1"}]}, f)

        out = load_extracted(root)
        check("ingredients_*.json 만 읽는다", sorted(out) == ["9355738365"], f"got {sorted(out)}")
        check("원재료 원문 보존", out.get("9355738365", {}).get("ingredients") == "밀가루, 설탕")
        check("not found placeholder 제외", "9355738366" not in out)


def test_load_extracted_skips_non_string_value():
    with tempfile.TemporaryDirectory() as root:
        d = os.path.join(root, "extracted_data")
        os.makedirs(d)
        with open(os.path.join(d, "ingredients_mixed.json"), "w") as f:
            json.dump({"111": "물, 소금", "222": {"note": "dict"}, "333": None}, f)
        out = load_extracted(root)
        check("ingredients_* 안에 섞인 비문자열 값은 건너뛴다", sorted(out) == ["111"], f"got {sorted(out)}")


def test_nfc_category():
    nfd = unicodedata.normalize("NFD", "과자_초콜릿_시리얼")
    check("NFD 디렉터리명은 NFC 로 정규화", nfc_category(nfd) == unicodedata.normalize("NFC", nfd))
    check("이미 NFC 면 그대로", nfc_category("수입식품관") == "수입식품관")
    check("None 은 None (detail 전용 고아 행)", nfc_category(None) is None)


def _write(path, obj):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        json.dump(obj, f, ensure_ascii=False)


def _output_tree(root):
    """쿠팡 폴더(NFD 이름) / 제타 폴더 / 혼재 폴더 + extracted_data 를 가진 output 트리."""
    coupang = unicodedata.normalize("NFD", "과자_초콜릿_시리얼")
    _write(os.path.join(root, coupang, "products_page1.json"),
           [{"productId": "9355738365", "title": "롯데웰푸드 칸쵸 초코, 54g, 4개"}])
    _write(os.path.join(root, coupang, "manual_ingredients_direct_page1.json"),
           {"items": [{"productId": "9355738365", "ingredients": "밀가루, 설탕", "confidence": "high"}]})

    _write(os.path.join(root, "롯데마트제타_생수_음료", "products_page1.json"),
           [{"productId": "8801056170073", "zettaSku": "OS8801056170073", "title": "칠성사이다 500ml"}])
    _write(os.path.join(root, "롯데마트제타_생수_음료", "manual_ingredients_direct_page1.json"),
           [{"productId": "8801056170073", "ingredients": "정제수, 과당"}])

    _write(os.path.join(root, "혼재폴더", "products_page1.json"),
           [{"productId": "8801392177118", "zettaSku": "OS8801392177118", "title": "햇반 210g"},
            {"productId": "9355738366", "title": "오리온 초코파이, 444g, 12개"}])
    _write(os.path.join(root, "혼재폴더", "manual_ingredients_direct_page1.json"),
           [{"productId": "8801392177118", "ingredients": "쌀"}])

    # 8801056170073 은 제외한 제타 상품 — 고아 원재료 경로로 되살아나면 출처 필터 우회다.
    _write(os.path.join(root, "extracted_data", "ingredients_snack_batch1.json"),
           {"9355738366": "밀가루, 코코아매스", "7777777777": "물, 소금",
            "8801056170073": "정제수, 과당"})
    _write(os.path.join(root, "extracted_data", "collection_db_gap_2026-06-29.json"),
           {"과자_초콜릿_시리얼": {"absentFromDb": 146}})
    return coupang


def test_build_rows_end_to_end():
    with tempfile.TemporaryDirectory() as root:
        coupang_nfd = _output_tree(root)
        rows, stats, folders = build_rows(root)
        by_ref = {r["source_ref"]: r for r in rows}

        check("제타 전용 폴더는 폴더째로 빠진다", stats["skipped_folder_lottemartzetta"] == 1,
              f"got {stats['skipped_folder_lottemartzetta']}")
        check("혼재 폴더는 남고 제타 행만 빠진다",
              sorted(folders) == sorted([coupang_nfd, "혼재폴더"]), f"got {sorted(folders)}")
        check("제외한 제타 행 수를 센다", stats["skipped_row_lottemartzetta"] == 2,
              f"got {stats['skipped_row_lottemartzetta']}")
        check("제타 상품은 행으로 만들어지지 않는다",
              "8801056170073" not in by_ref and "8801392177118" not in by_ref,
              f"got {sorted(by_ref)}")
        check("제외한 제타 pid 는 고아 원재료로도 되살아나지 않는다",
              stats["skipped_orphan_lottemartzetta"] == 1,
              f"got {stats['skipped_orphan_lottemartzetta']}")
        check("혼재 폴더의 쿠팡 상품은 유실되지 않는다", "9355738366" in by_ref)
        # 제타 전용 폴더는 manual 을 읽기 전에 빠지므로, 건너뛴 manual 은 혼재 폴더의 1개뿐이다.
        check("혼재 폴더의 제타 형식 manual 을 건너뛴다",
              stats["skipped_manual_not_coupang_shape"] == 1,
              f"got {stats['skipped_manual_not_coupang_shape']}")
        check("쿠팡 manual 원재료는 읽힌다",
              by_ref["9355738365"]["ingredients_raw"] == "밀가루, 설탕")
        check("extracted_data 원재료는 ingredients_* 에서만 읽힌다",
              by_ref["9355738366"]["ingredients_raw"] == "밀가루, 코코아매스")
        check("목록 밖 원재료는 고아 행으로 보존", "7777777777" in by_ref)

        # category = NFC, raw.category_folder = 원값(NFD) 계약. prepare_images 가 후자로 경로를 짠다.
        row = by_ref["9355738365"]
        check("category 는 NFC", row["category"] == unicodedata.normalize("NFC", coupang_nfd))
        check("raw.category_folder 는 디렉터리 원값 유지",
              row["raw"]["category_folder"] == coupang_nfd)
        check("NFD 디렉터리에서 category 와 category_folder 가 실제로 다르다",
              row["category"] != row["raw"]["category_folder"])


def main():
    for t in [test_zetta_rows_all_excluded, test_coupang_rows_kept,
              test_empty_folder, test_mixed_folder_splits_per_row,
              test_zetta_marker_wins_over_page_order,
              test_manual_skips_non_coupang_shape,
              test_load_extracted_picks_ingredients_only,
              test_load_extracted_skips_non_string_value, test_nfc_category,
              test_build_rows_end_to_end]:
        try:
            t()
        except Exception as e:  # noqa
            check(t.__name__, False, f"예외: {e}")
    failed = sum(1 for _, ok, _ in results if not ok)
    for name, ok, detail in results:
        print(f"  {'PASS' if ok else 'FAIL'}  {name}" + (f"  [{detail}]" if detail and not ok else ""))
    print(f"\n{len(results) - failed}/{len(results)} pass")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
