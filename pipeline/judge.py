"""룰 엔진 판정 — Dart compute_verdicts --json 서브프로세스 호출.

대상 선정 (resync 설계, §4.5):
  - collected_products: stage='tokenized' 또는
    (stage='judged' and rule_version is distinct from 엔진 현재 버전)
  - --target masters: product_masters에서 rule_version is distinct from 현재 버전인
    행 재계산 (룰 버전 변경 시, §7)

사용: .venv/bin/python judge.py [--dsn DSN] [--target collected|masters]
"""
from __future__ import annotations

import argparse
import json
import subprocess
from collections import Counter

from common import connect

HAPPYCART_APP_DIR = "/Users/innovator/Project/HappyCart/happycart"
REVIEW_GATED_SOURCES = {"lottemartzetta"}


def run_rules(items: list[dict]) -> list[dict]:
    """[{ref, tokens}] → [{ref, verdict, bad..., good..., reason..., rule_version}]"""
    proc = subprocess.run(
        ["dart", "run", "--verbosity=error", "tool/compute_verdicts.dart", "--json"],
        cwd=HAPPYCART_APP_DIR,
        input=json.dumps(items, ensure_ascii=False),
        capture_output=True, text=True, check=True,
    )
    return json.loads(proc.stdout)


def current_rule_version() -> str:
    # 2-verdict 이후 빈 토큰은 룰 엔진이 거절하므로 더미 토큰으로 rule_version만 얻는다.
    return run_rules([{"ref": "_probe", "tokens": ["물"]}])[0]["rule_version"]


def judge_collected(
    conn,
    rule_version: str,
    stats: Counter,
    source: str | None = None,
    source_ref: str | None = None,
    ids: list[str] | None = None,
) -> None:
    with conn.cursor() as cur:
        query = """
            select id, ingredients_tokens from collected_products
            where (
                stage = 'tokenized'
                or (stage = 'judged' and rule_version is distinct from %s)
            )
              and (source <> all(%s) or review_decision = 'verified')
        """
        params = [rule_version, list(REVIEW_GATED_SOURCES)]
        if source:
            query += " and source = %s"
            params.append(source)
        if source_ref:
            query += " and source_ref = %s"
            params.append(source_ref)
        if ids:
            query += " and id = any(%s::uuid[])"
            params.append(ids)
        cur.execute(query, params)
        rows = cur.fetchall()
        if not rows:
            return
        results = run_rules([{"ref": str(cid), "tokens": tokens or []} for cid, tokens in rows])
        for r in results:
            cur.execute("""
                update collected_products
                set verdict = %s::verdict_enum,
                    bad_ingredients_detected = %s,
                    good_ingredients_detected = %s,
                    verdict_reason_codes = %s,
                    rule_version = %s,
                    computed_at = now(),
                    stage = 'judged'
                where id = %s
            """, (r["verdict"], r["bad_ingredients_detected"], r["good_ingredients_detected"],
                  r["verdict_reason_codes"], r["rule_version"], r["ref"]))
            stats[f"collected_{r['verdict']}"] += 1


def judge_masters(conn, rule_version: str, stats: Counter) -> None:
    """룰 버전 변경 시 재계산. verdict 뒤집힘은 diff로 출력 — 검토 후 운영 반영 (§7)."""
    with conn.cursor() as cur:
        cur.execute("""
            select id, ingredients_tokens, verdict::text from product_masters
            where rule_version is distinct from %s
        """, (rule_version,))
        rows = cur.fetchall()
        if not rows:
            return
        prev = {str(mid): v for mid, _, v in rows}
        results = run_rules([{"ref": str(mid), "tokens": tokens or []} for mid, tokens, _ in rows])
        for r in results:
            cur.execute("""
                update product_masters
                set verdict = %s::verdict_enum,
                    bad_ingredients_detected = %s,
                    good_ingredients_detected = %s,
                    verdict_reason_codes = %s,
                    rule_version = %s,
                    computed_at = now()
                where id = %s
            """, (r["verdict"], r["bad_ingredients_detected"], r["good_ingredients_detected"],
                  r["verdict_reason_codes"], r["rule_version"], r["ref"]))
            stats[f"masters_{r['verdict']}"] += 1
            if prev[r["ref"]] != r["verdict"]:
                stats["masters_flipped"] += 1
                print(f"FLIP master {r['ref']}: {prev[r['ref']]} -> {r['verdict']}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dsn", default=None)
    ap.add_argument("--target", choices=["collected", "masters"], default="collected")
    ap.add_argument("--source", default=None)
    ap.add_argument("--source-ref", default=None)
    ap.add_argument("--ids", default=None,
                    help="콤마구분 collected_products.id 만 판정 (데이터데스크 승격보류 일괄용)")
    args = ap.parse_args()

    stats = Counter()
    rule_version = current_rule_version()
    print(f"rule_version = {rule_version}")
    ids = [x for x in args.ids.split(",") if x] if args.ids else None

    with connect(args.dsn) as conn:
        if args.target == "collected":
            judge_collected(conn, rule_version, stats, args.source, args.source_ref, ids)
        else:
            judge_masters(conn, rule_version, stats)
        conn.commit()
        with conn.cursor() as cur:
            cur.execute("select stage, count(*) from collected_products group by stage order by 1")
            print(dict(stats))
            print("stage:", dict(cur.fetchall()))


if __name__ == "__main__":
    main()
