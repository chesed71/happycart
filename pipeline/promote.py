"""승격 — collected_products의 완성 행을 product_masters / product_barcodes로.

승격 조건 (§4.6):
  stage='judged' AND barcode AND ingredients_raw/tokens AND brand·name·size NOT NULL
  AND confidence is distinct from 'low'

그룹핑: brand + ingredients_raw 완전 일치 = 같은 master (분리 계획과 동일 기준).
  - 2건 이상 그룹은 전수 리포트 출력
  - 그룹 내 정규화 name이 서로 다르면 (변형이 아니라 별개 상품 의심) 승격 보류

승격 대상 = 후보 멤버 + 각 멤버에 머지된 자식 바코드(사람이 바코드 합치기로 '같은
상품'이라 판단한 관계 근거로 동반 승격). 자식은 사람 검수 필드(review_decision 등)를
건드리지 않고 stage/promoted_master_id 만 갱신한다.

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

# 선두 판촉/채널 브래킷: "[SCO]", "【단독행사】", "《기획》", "<한정>" 등 이름 맨 앞의
# 대괄호/모난괄호 블록을 앞에서 반복 제거한다(상품명 자체와 무관한 채널·행사 표기).
_LEAD_BRACKET = re.compile(r"^\s*(?:\[[^\]]*\]|【[^】]*】|《[^》]*》|<[^>]*>)\s*")


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
        t2 = _LEAD_BRACKET.sub("", t, count=1).strip()
        if t2 == t:
            break
        t = t2
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
      and (raw->>'merged_into') is null  -- 머지 자식은 부모를 통해서만 승격(중복 후보→stage 오염 방지)
    order by source, source_ref
    for update   -- 후보 행을 트랜잭션 동안 잠가 review RPC와의 경쟁 차단
"""


def run_promotion(cur, *, id=None, ids=None, source=None, source_ref=None,
                  dry_run=False, stats=None):
    """승격 로직 본체 — 주어진 커서로 실행하고 commit 하지 않는다(호출자가 commit/rollback).
    덕분에 test_invariants.py가 트랜잭션 안에서 실행 후 rollback 하며 검증할 수 있다.

    반환: (promoted_masters, promoted_barcodes). stats(Counter)에 보류/충돌 등 집계.
    ids 는 콤마구분 문자열 또는 id 집합(set) 모두 허용.
    """
    if stats is None:
        stats = Counter()
    if isinstance(ids, str):
        id_set = {x for x in ids.split(",") if x}
    elif ids:
        id_set = set(ids)
    else:
        id_set = None

    cur.execute(CANDIDATE_SELECT)
    rows = cur.fetchall()
    if id:
        rows = [r for r in rows if str(r[0]) == id]
    if id_set is not None:
        rows = [r for r in rows if str(r[0]) in id_set]
    if source:
        rows = [r for r in rows if r[1] == source]
    if source_ref:
        rows = [r for r in rows if r[2] == source_ref]

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
    # 후보와 동일하게 스코프(id/ids/source/source_ref)를 반영 — 스코프 승격 시 held
    # 카운트가 전역 judged 를 세어 운영자를 오도하지 않도록.
    if id:
        held_sql += " and id = %s::uuid"
        held_params.append(id)
    if id_set is not None:
        held_sql += " and id = any(%s::uuid[])"
        held_params.append(list(id_set))
    if source:
        held_sql += " and source = %s"
        held_params.append(source)
    if source_ref:
        held_sql += " and source_ref = %s"
        held_params.append(source_ref)
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

        if dry_run:
            # 미리보기 — 머지 자식 바코드까지 세어 실측(부모+자식)에 근접시킨다.
            # 충돌/중복은 예측 불가라 실제 붙는 바코드 수의 상한 근사다.
            promoted_masters += 1
            child_bc = 0
            for m in members:
                cur.execute("""
                    select count(*) from collected_products
                    where (raw->>'merged_into') = %s
                      and (raw->>'deleted_at') is null
                      and stage not in ('promoted', 'rejected')
                      and barcode is not null
                """, (str(m[0]),))
                child_bc += cur.fetchone()[0]
            promoted_barcodes += len(members) + child_bc
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
            # 이 멤버(부모) 자신 + 그에 머지된 자식 바코드를 같은 master 로 승격한다.
            # 자식은 사람 검수 필드를 건드리지 않고 stage/promoted_master_id 만 쓴다.
            # rejected(자격 박탈)·promoted(이미 승격)·삭제 자식은 제외 — attach RPC의
            # 머지 대상 탐색 필터와 동일 기준. 단일 홉만 훑는다(자식의 자식은 비대상).
            targets = [(m[0], m[7], m[5])]  # (id, barcode, size)
            cur.execute("""
                select id, barcode, size from collected_products
                where (raw->>'merged_into') = %s
                  and (raw->>'deleted_at') is null
                  and stage not in ('promoted', 'rejected')
                  and barcode is not null
                for update
            """, (str(m[0]),))
            targets.extend(cur.fetchall())
            # targets[0] = 멤버(부모) 자신, 이후는 머지 자식. 부모 바코드가 이 master 에
            # 못 붙으면(다른 master 충돌) 자식도 붙이지 않는다 — 부모 없이 자식만 달린
            # shadow master 로 같은 상품이 갈라지는 것을 막는다.
            for pos, (tid, tbarcode, tsize) in enumerate(targets):
                cur.execute("""
                    insert into product_barcodes (barcode, master_id, size)
                    values (%s, %s, %s)
                    on conflict (barcode) do nothing
                    returning master_id
                """, (tbarcode, master_id, tsize))
                ins = cur.fetchone()
                if not ins:
                    # 바코드가 이미 존재 — 어느 master 소속인지 확인
                    cur.execute("select master_id from product_barcodes where barcode=%s", (tbarcode,))
                    owner = cur.fetchone()[0]
                    if str(owner) != str(master_id):
                        # 다른 master 의 바코드 — promoted 로 마킹하면 링크가 어긋난다. 보류.
                        cur.execute("""
                            update collected_products set stage='conflict',
                              conflict_reason = 'barcode '||%s||' belongs to different master '||%s
                            where id = %s
                        """, (tbarcode, str(owner), tid))
                        stats["barcode_conflict_held"] += 1
                        if pos == 0:
                            # 부모 바코드가 다른 master 로 충돌 — 자식은 이 master 에 붙이지
                            # 않고 parsed 로 남겨(다음 실행에서 부모와 함께 재시도) shadow
                            # master 생성을 막는다. 아무것도 안 붙으면 빈 master 는 아래서 정리.
                            break
                        continue
                    # 같은 master (재실행 멱등) — 정상 진행
                attached += 1
                promoted_barcodes += 1 if ins else 0
                if tid != m[0]:
                    stats["child_barcode_promoted"] += 1 if ins else 0
                cur.execute("""
                    update collected_products
                    set stage = 'promoted', promoted_master_id = %s, promoted_at = now()
                    where id = %s
                """, (master_id, tid))

        # 이 그룹의 어떤 바코드도 master 에 붙지 못했다면(전부 충돌) 빈 master 정리.
        if attached == 0 and got:
            cur.execute("delete from product_masters where id = %s", (master_id,))
            promoted_masters -= 1
            stats["empty_master_removed"] += 1

    return promoted_masters, promoted_barcodes


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

    with connect(args.dsn) as conn, conn.cursor() as cur:
        promoted_masters, promoted_barcodes = run_promotion(
            cur, id=args.id, ids=args.ids, source=args.source,
            source_ref=args.source_ref, dry_run=args.dry_run, stats=stats)

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
