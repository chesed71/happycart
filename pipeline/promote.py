"""승격 — collected_products의 완성 행을 product_masters / product_barcodes로.

승격 조건 (§4.6):
  stage='judged' AND barcode AND ingredients_raw/tokens AND brand·name·size NOT NULL
  AND confidence is distinct from 'low'

그룹핑: brand + ingredients_raw 완전 일치 = 같은 master (분리 계획과 동일 기준).
  - 2건 이상 그룹은 전수 리포트 출력
  - 그룹 내 정규화 name이 서로 다르면 (변형이 아니라 별개 상품 의심) 승격 보류

master upsert는 ingredients_hash(UNIQUE)를 conflict target으로 — 초기 dedupe 전용.
영속 식별은 uuid (§3.4). verified_status='unverified' — 앱 비노출.

사용: .venv/bin/python promote.py [--dsn DSN] [--dry-run]
"""
from __future__ import annotations

import argparse
from collections import Counter

from common import connect
from match_enrich import norm

SOURCE_BY_COLLECTED = {
    "coupang": "쿠팡 크롤링 + 직접 판독",
    "kakamuka": "kakamuka 크롤링",
}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dsn", default=None)
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()
    stats = Counter()

    with connect(args.dsn) as conn, conn.cursor() as cur:
        cur.execute("""
            select id, source, source_ref, brand, name, size, category, barcode,
                   ingredients_raw, ingredients_tokens,
                   bad_ingredients_detected, good_ingredients_detected,
                   verdict_reason_codes, verdict::text, rule_version, computed_at,
                   confidence, raw->>'source_url'
            from collected_products
            where stage = 'judged'
              and barcode is not null
              and ingredients_raw is not null
              and coalesce(array_length(ingredients_tokens, 1), 0) > 0
              and brand is not null and name is not null and size is not null
              and confidence is distinct from 'low'
              and review_decision = 'verified'   -- 확인완료 게이트 (§8-1 확정)
            order by source, source_ref
        """)
        rows = cur.fetchall()
        # 승격 보류 사유별 카운트 (judged인데 조건 미달)
        cur.execute("""
            select
              count(*) filter (where review_decision is distinct from 'verified') as not_reviewed,
              count(*) filter (where review_decision = 'verified' and (
                barcode is null or ingredients_raw is null
                or coalesce(array_length(ingredients_tokens, 1), 0) = 0
                or brand is null or name is null or size is null
                or confidence = 'low')) as reviewed_but_incomplete
            from collected_products where stage = 'judged'
        """)
        not_reviewed, reviewed_incomplete = cur.fetchone()
        stats["held_not_reviewed"] = not_reviewed
        stats["held_reviewed_incomplete"] = reviewed_incomplete

        # 그룹핑: (brand, ingredients_raw)
        groups: dict[tuple, list] = {}
        for r in rows:
            groups.setdefault((r[3], r[8]), []).append(r)

        promoted_masters = 0
        promoted_barcodes = 0
        for (brand, ingredients_raw), members in groups.items():
            names = {norm(m[4]) for m in members}
            if len(members) > 1:
                print(f"GROUP [{brand}] x{len(members)}: "
                      + "; ".join(f"{m[4]} ({m[5]}, {m[7]})" for m in members))
                if len(names) > 1:
                    # 별개 상품 의심 — 보류 (잘못된 병합은 위험, 보류는 안전)
                    print("  -> HOLD: 그룹 내 name 불일치, 승격 보류")
                    stats["group_held"] += len(members)
                    continue
            # 그룹 내 판정 일치 assert (같은 raw → 같은 tokens → 같은 verdict)
            verdicts = {m[13] for m in members}
            if len(verdicts) > 1:
                print(f"  -> HOLD: 그룹 내 verdict 불일치 {verdicts} — 점검 필요")
                stats["group_verdict_mismatch"] += len(members)
                continue

            if args.dry_run:
                promoted_masters += 1
                promoted_barcodes += len(members)
                continue

            rep = members[0]
            cur.execute("""
                insert into product_masters
                  (brand, name, category, ingredients_raw, ingredients_tokens,
                   bad_ingredients_detected, good_ingredients_detected,
                   verdict_reason_codes, verdict, rule_version, computed_at,
                   source, source_url, source_checked_at, verified_status)
                values (%s, %s, %s, %s, %s, %s, %s, %s, %s::verdict_enum, %s, %s,
                        %s, %s, now(), 'unverified')
                on conflict (ingredients_hash) do nothing
                returning id
            """, (rep[3], rep[4], rep[6], rep[8], rep[9], rep[10], rep[11],
                  rep[12], rep[13], rep[14], rep[15],
                  SOURCE_BY_COLLECTED[rep[1]], rep[17]))
            got = cur.fetchone()
            if got:
                master_id = got[0]
                promoted_masters += 1
            else:
                # 이미 존재 (재실행 또는 기존 운영 master와 hash 일치)
                cur.execute("""
                    select id, verified_status::text from product_masters
                    where ingredients_hash = md5(%s || '|' || %s)
                """, (rep[3], rep[8]))
                master_id, vstatus = cur.fetchone()
                stats["master_existing_reused"] += 1
                if vstatus == "verified":
                    # 기존 verified master에 새 바코드 연결은 즉시 노출이라 수동 검토 (§6.3)
                    print(f"  -> HOLD: verified master 재사용 감지 ({brand} / {rep[4]}) — 수동 연결 필요")
                    stats["verified_master_hold"] += len(members)
                    continue

            for m in members:
                cur.execute("""
                    insert into product_barcodes (barcode, master_id, size)
                    values (%s, %s, %s)
                    on conflict (barcode) do nothing
                """, (m[7], master_id, m[5]))
                promoted_barcodes += cur.rowcount
                cur.execute("""
                    update collected_products
                    set stage = 'promoted', promoted_master_id = %s, promoted_at = now()
                    where id = %s
                """, (master_id, m[0]))

        if not args.dry_run:
            conn.commit()

        # ── 검증 + 리포트 ──
        print(f"\npromoted: masters +{promoted_masters}, barcodes +{promoted_barcodes}")
        print(dict(stats))
        with conn.cursor() as c2:
            c2.execute("""
                select source, coalesce(confidence, '(extracted)') conf, count(*)
                from collected_products where stage = 'promoted'
                group by 1, 2 order by 1, 2
            """)
            print("promoted by source/confidence:", c2.fetchall())
            c2.execute("""
                select count(*) from product_barcodes b
                left join product_masters m on m.id = b.master_id where m.id is null
            """)
            orphans = c2.fetchone()[0]
            c2.execute("select count(*) from product_masters")
            masters = c2.fetchone()[0]
            c2.execute("select count(*) from product_barcodes")
            barcodes = c2.fetchone()[0]
            print(f"service tables: masters={masters} barcodes={barcodes} fk_orphans={orphans}")
            assert orphans == 0, "FK orphan 발견"


if __name__ == "__main__":
    main()
