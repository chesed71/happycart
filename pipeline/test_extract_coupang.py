"""extract_coupang 의 출처 선별·정규화 회귀 테스트 (DB 불필요).

output/ 이 롯데마트제타 크롤러와 공유되면서 생긴 두 가지 오염을 막는 장치를 검증한다:
  - zettaSku 폴더를 쿠팡 추출에서 제외 (source 뒤바뀜 방지)
  - extracted_data/ 의 분석·리포트 JSON 대신 ingredients_*.json 만 읽기
그리고 category 컬럼의 NFC 정규화(macOS 디렉터리명은 NFD)를 확인한다.

사용: pipeline/.venv/bin/python test_extract_coupang.py
"""
from __future__ import annotations

import json
import os
import sys
import tempfile
import unicodedata

from extract_coupang import is_lottemartzetta_folder, load_extracted, nfc_category

results = []


def check(name, cond, detail=""):
    results.append((name, cond, detail))


def _folder(*products):
    """load_products 반환 형태({pid: {"product": ...}})로 감싼다."""
    return {str(p["productId"]): {"product": p, "pages": ["products.json"]} for p in products}


def test_zetta_folder_detected():
    zetta = _folder(
        {"productId": "8801392177118", "zettaSku": "OS8801392177118", "title": "햇반 (500ML)"},
        {"productId": "8801392177119", "zettaSku": "OS8801392177119", "title": "햇반 (200ML)"},
    )
    check("zettaSku 폴더는 롯데마트제타로 판정", is_lottemartzetta_folder(zetta) is True)


def test_coupang_folder_not_detected():
    coupang = _folder(
        {"productId": "9355738365", "title": "롯데웰푸드 칸쵸 초코, 54g, 4개", "barcode": None},
        {"productId": "9355738366", "title": "오리온 초코파이, 12개", "barcode": None},
    )
    check("쿠팡 폴더는 제외되지 않음", is_lottemartzetta_folder(coupang) is False)


def test_empty_folder_not_detected():
    # 상품이 없는 폴더를 all() 의 공집합 참으로 제외해 버리면 안 된다.
    check("빈 폴더는 제외되지 않음", is_lottemartzetta_folder({}) is False)


def test_mixed_folder_not_detected():
    mixed = _folder(
        {"productId": "8801392177118", "zettaSku": "OS8801392177118", "title": "햇반"},
        {"productId": "9355738365", "title": "칸쵸"},
    )
    check("혼재 폴더는 제외되지 않음(쿠팡 상품 유실 방지)", is_lottemartzetta_folder(mixed) is False)


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


def main():
    for t in [test_zetta_folder_detected, test_coupang_folder_not_detected,
              test_empty_folder_not_detected, test_mixed_folder_not_detected,
              test_load_extracted_picks_ingredients_only,
              test_load_extracted_skips_non_string_value, test_nfc_category]:
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
