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
import re
from collections import Counter

from common import connect
from match_enrich import norm

SOURCE_BY_COLLECTED = {
    "coupang": "쿠팡 크롤링 + 직접 판독",
    "kakamuka": "kakamuka 크롤링",
    "lottemartzetta": "롯데마트 제타 크롤링 + 직접 판독",
}

# 앱 표시명은 브랜드+상품명(brand·size 는 별도 컬럼). 수집 타이틀에서 앞 브랜드와
# 끝 용량(숫자 든 괄호)을 떼어 product_masters.name 을 제품명만으로 만든다.
# 맛/버전 괄호("(밀크)", "(오리지널)")는 숫자가 없으므로 보존한다.
_SIZE_PAREN = re.compile(r"\s*\((?=[^()]*\d)[^()]*\)\s*$")


def _strip_brand(t: str, brand: str) -> str:
    if not brand:
        return t
    bnorm = brand.replace(" ", "")
    toks = t.split()
    acc = ""
    for i, tok in enumerate(toks):
        acc += tok
        if acc == bnorm:
            return " ".join(toks[i + 1:])
        if not bnorm.startswith(acc):
            break
    if t.startswith(brand):
        return t[len(brand):].strip()
    return t


def clean_product_name(name: str, brand: str | None) -> str:
    if not name:
        return name
    t = name.strip()
    while True:
        t2 = _SIZE_PAREN.sub("", t).strip()
        if t2 == t:
            break
        t = t2
    t = _strip_brand(t, (brand or "").strip()).strip()
    t = re.sub(r"[\s,·/]+$", "", t).strip()
    return t or name

# 승격 후보 잠금 쿼리. test_invariants.py가 이 상수를 그대로 써서 잠금 회귀를 막는다
# (promote.py에서 FOR UPDATE가 빠지면 잠금 테스트도 깨지도록).
CANDIDATE_SELECT = """
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
    for update   -- 후보 행을 트랜잭션 동안 잠가 review RPC와의 경쟁 차단
"""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dsn", default=None)
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--source", default=None)
    ap.add_argument("--source-ref", default=None)
    ap.add_argument("--id", default=None,
                    help="단일 collected_products.id만 승격 (데이터데스크 카드별 승격용)")
    ap.add_argument("--ids", default=None,
                    help="콤마구분 collected_products.id 집합만 승격 (데이터데스크 승격보류 일괄용)")
    args = ap.parse_args()
    stats = Counter()
    id_set = {x for x in args.ids.split(",") if x} if args.ids else None

    with connect(args.dsn) as conn, conn.cursor() as cur:
        cur.execute(CANDIDATE_SELECT)
        rows = cur.fetchall()
        if args.id:
            rows = [r for r in rows if str(r[0]) == args.id]
        if id_set is not None:
            rows = [r for r in rows if str(r[0]) in id_set]
        if args.source:
            rows = [r for r in rows if r[1] == args.source]
        if args.source_ref:
            rows = [r for r in rows if r[2] == args.source_ref]
        # 승격 보류 사유별 카운트 (judged인데 조건 미달)
        held_sql = """
            select
              count(*) filter (where review_decision is distinct from 'verified') as not_reviewed,
              count(*) filter (where review_decision = 'verified' and (
                barcode is null or ingredients_raw is null
                or coalesce(array_length(ingredients_tokens, 1), 0) = 0
                or brand is null or name is null or size is null
                or confidence = 'low')) as reviewed_but_incomplete
            from collected_products where stage = 'judged'
        """
        held_params = []
        if args.source:
            held_sql += " and source = %s"
            held_params.append(args.source)
        if args.source_ref:
            held_sql += " and source_ref = %s"
            held_params.append(args.source_ref)
        cur.execute(held_sql, held_params)
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
            # 앱 표시명 = 브랜드+상품명. 수집 타이틀에서 앞 브랜드·끝 용량을 떼어 제품명만 저장.
            master_name = clean_product_name(rep[4], rep[3])
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
            """, (rep[3], master_name, rep[6], rep[8], rep[9], rep[10], rep[11],
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

            attached = 0
            for m in members:
                cur.execute("""
                    insert into product_barcodes (barcode, master_id, size)
                    values (%s, %s, %s)
                    on conflict (barcode) do nothing
                    returning master_id
                """, (m[7], master_id, m[5]))
                ins = cur.fetchone()
                if not ins:
                    # 바코드가 이미 존재 — 어느 master 소속인지 확인
                    cur.execute("select master_id from product_barcodes where barcode=%s", (m[7],))
                    owner = cur.fetchone()[0]
                    if str(owner) != str(master_id):
                        # 다른 master 의 바코드 — promoted 로 마킹하면 링크가 어긋난다. 보류.
                        cur.execute("""
                            update collected_products set stage='conflict',
                              conflict_reason = 'barcode '||%s||' belongs to different master '||%s
                            where id = %s
                        """, (m[7], str(owner), m[0]))
                        stats["barcode_conflict_held"] += 1
                        continue
                    # 같은 master (재실행 멱등) — 정상 진행
                attached += 1
                promoted_barcodes += 1 if ins else 0
                cur.execute("""
                    update collected_products
                    set stage = 'promoted', promoted_master_id = %s, promoted_at = now()
                    where id = %s
                """, (master_id, m[0]))

            # 이 그룹의 어떤 바코드도 master 에 붙지 못했다면(전부 충돌) 빈 master 정리.
            if attached == 0 and got:
                cur.execute("delete from product_masters where id = %s", (master_id,))
                promoted_masters -= 1
                stats["empty_master_removed"] += 1

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
