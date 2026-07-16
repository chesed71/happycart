"""corpus_diff·judge 순수/DB 함수 테스트 — self-run 러너 (test_invariants.py 패턴).

DB 불필요한 순수 함수는 항상 실행하고, DB 필요한 함수는 접속 실패 시 SKIP 한다
(DB 없는 CI 통과). 각 DB 테스트는 트랜잭션 안에서 픽스처를 만들고 rollback 한다.

사용: pipeline/.venv/bin/python test_corpus_diff.py
"""
from __future__ import annotations

import hashlib
import json
import os
import sys
import tempfile

import psycopg

from common import dsn
from test_invariants import ean13

# judge.resolve_app_dir 의 기본값과 동일해야 한다 (현재 머신 실경로).
DEFAULT_APP_DIR = "/Users/ronen/Project/HappyCart/happycart"

# (name, ok) — ok=True PASS / ok=False FAIL / ok=None SKIP
results: list[tuple[str, bool | None, str]] = []


def check(name: str, cond: bool, detail: str = "") -> None:
    results.append((name, bool(cond), detail))


def skip(name: str, reason: str) -> None:
    results.append((name, None, reason))


def test_resolve_app_dir_precedence():
    """resolve_app_dir: CLI 인자 > 환경변수 HAPPYCART_APP_DIR > 기본값."""
    import judge

    saved = os.environ.get("HAPPYCART_APP_DIR")
    try:
        # (a) CLI 값이 주어지면 env 가 있어도 CLI 우선
        os.environ["HAPPYCART_APP_DIR"] = "/env/path"
        check("resolve_app_dir: CLI 우선",
              judge.resolve_app_dir("/cli/path") == "/cli/path")
        # (b) CLI 없으면 env 사용
        check("resolve_app_dir: env 사용",
              judge.resolve_app_dir(None) == "/env/path")
        # (c) 둘 다 없으면 기본값
        os.environ.pop("HAPPYCART_APP_DIR", None)
        check("resolve_app_dir: 기본값",
              judge.resolve_app_dir(None) == DEFAULT_APP_DIR)
    finally:
        if saved is None:
            os.environ.pop("HAPPYCART_APP_DIR", None)
        else:
            os.environ["HAPPYCART_APP_DIR"] = saved


def test_write_snapshot_shape():
    """write_snapshot: rows + 메타(catalog sha256·git ref·count)를 JSON 으로 저장."""
    import corpus_diff

    with tempfile.TemporaryDirectory() as d:
        catalog_path = os.path.join(d, "cat.json")
        payload = b'{"schemaVersion":1,"bad":[],"good":[]}'
        with open(catalog_path, "wb") as f:
            f.write(payload)
        expected_sha = hashlib.sha256(payload).hexdigest()
        rows = [{"ref": "1", "tokens": ["밀가루"], "prev_verdict": "okay",
                 "prev_bad": [], "prev_reason": []}]
        snap_path = os.path.join(d, "snap.json")
        corpus_diff.write_snapshot(rows, snap_path, catalog_path, DEFAULT_APP_DIR)
        with open(snap_path, encoding="utf-8") as f:
            snap = json.load(f)
        check("write_snapshot: catalog_sha256 일치",
              snap.get("catalog_sha256") == expected_sha,
              f"{snap.get('catalog_sha256')} != {expected_sha}")
        check("write_snapshot: count", snap.get("count") == 1)
        check("write_snapshot: rows 보존", snap.get("rows") == rows)
        check("write_snapshot: git_ref 문자열",
              isinstance(snap.get("git_ref"), str) and len(snap["git_ref"]) > 0)


def test_fetch_corpus_shape():
    """fetch_corpus: 대상 행을 ref/tokens/prev_* 로 반환하고 빈 토큰은 제외 (DB 필요)."""
    import corpus_diff

    try:
        conn = psycopg.connect(dsn())
    except psycopg.Error as e:
        skip("test_fetch_corpus_shape", f"DB 없음: {e}")
        return
    with conn, conn.cursor() as cur:
        cur.execute("begin")
        # 대상 행: stage=judged, 비어있지 않은 토큰, 비-게이트 source(coupang)
        cur.execute(
            """
            insert into collected_products
              (source, source_ref, raw, brand, name, size, category, barcode,
               ingredients_raw, confidence, ingredients_tokens, verdict, rule_version,
               bad_ingredients_detected, verdict_reason_codes, computed_at, stage)
            values ('coupang', %s, '{}'::jsonb, 'B', 'N', '10g', 'cat', %s,
                    '밀가루, 적색40호', 'high', '{밀가루,적색40호}',
                    'not_okay'::verdict_enum, 'v1.1.0',
                    '{red_40}', '{artificial_color}', now(), 'judged')
            returning id
            """,
            ("cd-test-target", ean13("990000000010")),
        )
        target_id = str(cur.fetchone()[0])
        # 제외 행: 빈 토큰
        cur.execute(
            """
            insert into collected_products
              (source, source_ref, raw, brand, name, size, category, barcode,
               ingredients_raw, confidence, ingredients_tokens, verdict, rule_version,
               computed_at, stage)
            values ('coupang', %s, '{}'::jsonb, 'B', 'N', '10g', 'cat', %s,
                    '', 'high', '{}', 'okay'::verdict_enum, 'v1.1.0', now(), 'judged')
            returning id
            """,
            ("cd-test-empty", ean13("990000000011")),
        )
        empty_id = str(cur.fetchone()[0])

        rows = corpus_diff.fetch_corpus(conn)
        by_ref = {r["ref"]: r for r in rows}
        check("fetch_corpus: 대상 행 포함", target_id in by_ref)
        if target_id in by_ref:
            r = by_ref[target_id]
            check("fetch_corpus: tokens", r["tokens"] == ["밀가루", "적색40호"],
                  f"tokens={r['tokens']}")
            check("fetch_corpus: prev_verdict", r["prev_verdict"] == "not_okay")
            check("fetch_corpus: prev_bad", r["prev_bad"] == ["red_40"])
            check("fetch_corpus: prev_reason", r["prev_reason"] == ["artificial_color"])
        check("fetch_corpus: 빈 토큰 행 제외", empty_id not in by_ref)
        conn.rollback()


def main():
    tests = [
        test_resolve_app_dir_precedence,
        test_write_snapshot_shape,
        test_fetch_corpus_shape,
    ]
    for t in tests:
        try:
            t()
        except Exception as e:  # noqa
            check(t.__name__, False, f"테스트 예외: {e}")

    failed = skipped = 0
    for name, ok, detail in results:
        if ok is None:
            mark, skipped = "SKIP", skipped + 1
        elif ok:
            mark = "PASS"
        else:
            mark, failed = "FAIL", failed + 1
        show = detail and (ok is None or not ok)
        print(f"  {mark}  {name}" + (f"  [{detail}]" if show else ""))
    passed = len(results) - failed - skipped
    print(f"\n{passed} pass, {failed} fail, {skipped} skip")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
