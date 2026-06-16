"""collected_products의 ingredients_raw → ingredients_tokens (stage='tokenized').

사용:
  .venv/bin/python tokenize.py --golden   # 시드 golden test (DB products + fixture)
  .venv/bin/python tokenize.py            # 수집 테이블 토큰화 실행

참고: docs/superpowers/specs/2026-06-11-local-db-data-ingestion-plan.md §4.4
"""
from __future__ import annotations

import argparse
import json
from collections import Counter

from common import connect, dsn
from tokenizer import tokenize

FIXTURE = "/Users/innovator/Project/HappyCart/happycart/tool/fixtures/seed_products.json"

# golden 불일치 허용 목록 — 시드 수작업 토큰의 비일관 케이스. 사유 필수.
GOLDEN_EXCEPTIONS: dict[str, str] = {
    # 수작업 토큰이 OCR 깨짐 토큰('내멸린드스')을 임의 제외 — 토크나이저는 보존하는 쪽이 맞다
    "fixture:8801037088168": "수작업에서 OCR 깨짐 토큰을 임의 제외 (토크나이저는 보존)",
    # 수작업 토큰에 원문에 없는 영문 번역('rice bran oil')이 추가됨
    "fixture:8851103220480": "수작업 토큰에 원문에 없는 영문 번역 추가",
    # 수작업 토큰에 원문에 없는 '올리고당'이 추가됨 (이소말토올리고당의 파생)
    "fixture:8801052727523": "수작업 토큰에 원문에 없는 파생 토큰 추가",
}


def golden_pairs():
    """golden 쌍: 시드 fixture(7) + 운영 시드 DB 행 (있으면)."""
    pairs = []
    data = json.load(open(FIXTURE))
    for p in data["products"]:
        pairs.append((f"fixture:{p['barcode']}", p["ingredients_raw"], p["ingredients_tokens"]))
    try:
        with connect(dsn("happycart_test")) as conn:
            with conn.cursor() as cur:
                cur.execute("""
                    select barcode, ingredients_raw, ingredients_tokens from products
                    where barcode <> '8800000000017' order by barcode
                """)
                for barcode, raw, tokens in cur.fetchall():
                    pairs.append((f"seed:{barcode}", raw, tokens))
    except Exception as e:  # happycart_test가 없으면 fixture만으로
        print(f"(seed DB unavailable: {e})")
    # 동일 raw 중복 제거
    seen, out = set(), []
    for ref, raw, tokens in pairs:
        if raw in seen:
            continue
        seen.add(raw)
        out.append((ref, raw, tokens))
    return out


def run_golden() -> int:
    pairs = golden_pairs()
    failed = 0
    for ref, raw, expected in pairs:
        got = tokenize(raw)
        if got == expected:
            print(f"PASS {ref}")
        elif ref in GOLDEN_EXCEPTIONS:
            print(f"SKIP {ref} — {GOLDEN_EXCEPTIONS[ref]}")
        else:
            failed += 1
            print(f"FAIL {ref}")
            missing = [t for t in expected if t not in got]
            extra = [t for t in got if t not in expected]
            if missing:
                print(f"  missing: {missing}")
            if extra:
                print(f"  extra:   {extra}")
            if not missing and not extra:
                print(f"  (순서 불일치)\n  expected: {expected}\n  got:      {got}")
    print(f"golden: {len(pairs) - failed}/{len(pairs)} pass")
    return 1 if failed else 0


def run_tokenize(dsn: str | None) -> None:
    stats = Counter()
    with connect(dsn) as conn, conn.cursor() as cur:
        cur.execute("""
            select id, ingredients_raw from collected_products
            where stage = 'parsed' and ingredients_raw is not null
        """)
        rows = cur.fetchall()
        for cid, raw in rows:
            tokens = tokenize(raw)
            if tokens:
                cur.execute("""
                    update collected_products
                    set ingredients_tokens = %s, stage = 'tokenized'
                    where id = %s
                """, (tokens, cid))
                stats["tokenized"] += 1
            else:
                stats["empty_result"] += 1  # stage 유지 — 실패 목록은 SQL로 조회
        conn.commit()
        print(dict(stats))
        cur.execute("select stage, count(*) from collected_products group by stage order by 1")
        print("stage:", dict(cur.fetchall()))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dsn", default=None)
    ap.add_argument("--golden", action="store_true")
    args = ap.parse_args()
    if args.golden:
        raise SystemExit(run_golden())
    run_tokenize(args.dsn)


if __name__ == "__main__":
    main()
