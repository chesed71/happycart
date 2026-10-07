"""승격 — collected_products의 완성 행을 product_masters / product_barcodes로.

승격 조건 (§4.6):
  stage='judged' AND barcode AND ingredients_raw/tokens AND brand·name·size NOT NULL
  AND confidence is distinct from 'low'

그룹핑: brand + ingredients_raw + master 이름(clean_product_name — 끝 용량 괄호 제거)
완전 일치 = 같은 master(= DB master_key 와 같은 기준). 용량·개수만 다른 포장 변형은 이름이 같아 master 1개 + 바코드 N개로,
원재료 표기가 같아도 상품명이 다른 상품(맛·종류 차이)은 master 를 따로 만든다(0019).
  - 2건 이상 그룹은 전수 리포트 출력

승격 대상 = 후보 멤버 + 각 멤버에 머지된 자식 바코드(사람이 바코드 합치기로 '같은
상품'이라 판단한 관계 근거로 동반 승격). 자식은 사람 검수 필드(review_decision 등)를
건드리지 않고 stage/promoted_master_id 만 갱신한다.

master upsert는 master_key(brand|name|ingredients_raw, UNIQUE)를 conflict target으로 — 초기 dedupe 전용.
영속 식별은 uuid (§3.4). verified_status='unverified' — 앱 비노출.

사용: .venv/bin/python promote.py [--dsn DSN] [--dry-run]
"""
from __future__ import annotations

import argparse
import re
from collections import Counter

from common import connect

# product_masters.source 는 collected_products.source 와 같은 약어 어휘를 쓴다(cp/kk/lz)
# — 2026-10-07 운영까지 약어로 통일. 예전에는 사람이 읽는 문구로 매핑했으나 이제 항등이라
# rep[1] 을 그대로 넣는다. 크롤링이 아닌 출처('제조사 라벨 (오뚜기)' 등)는 사람이 직접 적은
# 값으로 승격 경로를 타지 않으므로 여기서 다루지 않는다.

# 앱 표시명은 브랜드+상품명(brand·size 는 별도 컬럼). 수집 타이틀에서 앞 브랜드와
# 끝 용량 괄호를 떼어 product_masters.name 을 제품명만으로 만든다. 용량 괄호 = 괄호 안 전체가
# 수량 문법인 것 — "숫자[단위]" 를 *·x·×·+·-·/·, 로 이은 형태("(200)", "(1KG)", "(7G*16입)",
# "(1박스-8개)", "(약 150개입)", "(2인)"). 맛/버전 괄호("(밀크)")와 숫자가 섞인 구분자
# ("(비타민 B12)", "(제1인산칼슘)", "(비타민 500mg)", "(Ver.2)")는 보존한다 — master 는 이
# 이름으로 나뉘므로(master_key) 구분자를 지우면 별개 상품이 합쳐진다.
_QTY_UNIT = r"(?:kg|mg|ml|g|l|m|cc|인분|개입|인|입|개|봉지|봉|팩|매|구|캔|병|포|박스|통|ea|p)"
_QTY = r"(?:약\s*)?\d+(?:\.\d+)?\s*" + _QTY_UNIT + "?"
_SIZE_PAREN = re.compile(
    r"\s*\(\s*" + _QTY + r"(?:\s*[*x×+\-/,]\s*" + _QTY + r")*\s*\)\s*$", re.IGNORECASE
)

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
      and coalesce(raw->>'review_tag', '') <> 'flagged'  -- 검토 필요(검수자 플래그)는 승격 제외
      -- 삭제 RPC는 raw.deleted_at 만 찍고 stage·review_decision 은 그대로 둔다. 데이터데스크는
      -- 목록에서 숨기지만 여기서 거르지 않으면 지워진 행이 전체 배치에서 승격된다(자식 조회는
      -- 이미 같은 조건으로 거르고 있었다).
      and (raw->>'deleted_at') is null
    order by source, source_ref
    for update   -- 후보 행을 트랜잭션 동안 잠가 review RPC와의 경쟁 차단
"""

# 그룹의 머지 자식을 한 번에 잠그고 태그까지 같이 읽는다. 잠그기 전에 태그만 세어 보면 그 사이
# 데이터데스크 RPC 가 flagged 를 걸어도 승격이 그대로 진행된다(TOCTOU) — 보류 판정과 실제 승격이
# 같은 잠긴 행 집합을 보도록 여기서 먼저 잠근다. 태그·검수 RPC 는 행을 FOR UPDATE 로 잡으므로
# 이 잠금 동안 대기한다. test_invariants.py 가 이 상수를 그대로 써서 경쟁을 재현한다.
# rejected(자격 박탈)·promoted(이미 승격)·삭제 자식은 제외 — attach RPC 의 머지 대상 탐색 필터와
# 동일 기준. 단일 홉만 훑는다(자식의 자식은 비대상).
MERGED_CHILDREN_LOCK = """
    select id, barcode, size, raw->>'merged_into', coalesce(raw->>'review_tag', '')
    from collected_products
    where (raw->>'merged_into') = any(%s)
      and (raw->>'deleted_at') is null
      and stage not in ('promoted', 'rejected')
    order by id   -- 교착 회피: 항상 같은 순서로 잠근다
    for update
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
            or confidence = 'low')) as reviewed_but_incomplete,
          -- 오직 검토 필요(flagged) 때문에 후보에서 빠진 행. 세지 않으면 승격 0건·보류 0건으로
          -- 보여 운영자가 원인을 알 수 없다. 모집단은 CANDIDATE_SELECT 와 같게 두고(머지 자식
          -- 제외 포함) review_tag 조건만 반대로 둔다 — 다른 사유로 빠진 행이 섞이면 오도한다.
          count(*) filter (where review_decision = 'verified'
            and coalesce(raw->>'review_tag', '') = 'flagged'
            and barcode is not null and ingredients_raw is not null
            and coalesce(array_length(ingredients_tokens, 1), 0) > 0
            and brand is not null and name is not null and size is not null
            and confidence is distinct from 'low') as held_flagged
        from collected_products
        -- 모집단은 후보 쿼리·데이터데스크 목록과 같게 둔다. 삭제 행과 머지 자식은 후보가 아니고
        -- 데스크 목록에도 안 보이므로, 보류로 세면 운영자가 손댈 수 없는 수만 남는다.
        where stage = 'judged'
          and (raw->>'deleted_at') is null
          and (raw->>'merged_into') is null
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
    not_reviewed, reviewed_incomplete, held_flagged = cur.fetchone()
    stats["held_not_reviewed"] = not_reviewed
    stats["held_reviewed_incomplete"] = reviewed_incomplete
    stats["held_flagged"] = held_flagged

    # 그룹핑: (brand, ingredients_raw, master 이름). master 이름은 저장·유일키(master_key)와
    # 똑같이 clean_product_name 결과 그대로 쓴다 — 별도 정규화를 하면 일괄/개별 승격의 master
    # 수가 달라진다. 끝 용량 괄호만 다른 포장 변형은 한 그룹, 이름이 다르면 다른 master.
    groups: dict[tuple, list] = {}
    for r in rows:
        groups.setdefault((r[3], r[8], clean_product_name(r[4], r[3])), []).append(r)

    promoted_masters = 0
    promoted_barcodes = 0
    for (brand, ingredients_raw, master_name), members in groups.items():
        if len(members) > 1:
            print(f"GROUP [{brand}] x{len(members)}: "
                  + "; ".join(f"{m[4]} ({m[5]}, {m[7]})" for m in members))
        # 그룹 내 판정 일치 assert (같은 raw → 같은 tokens → 같은 verdict)
        verdicts = {m[13] for m in members}
        if len(verdicts) > 1:
            print(f"  -> HOLD: 그룹 내 verdict 불일치 {verdicts} — 점검 필요")
            stats["group_verdict_mismatch"] += len(members)
            continue

        # 그룹의 머지 자식을 먼저 잠그고, 이 잠긴 집합 하나로 보류 판정과 승격을 모두 한다.
        cur.execute(MERGED_CHILDREN_LOCK, ([str(m[0]) for m in members],))
        children = cur.fetchall()

        # 검토 필요(flagged) 머지 자식이 하나라도 있으면 그룹째 보류한다. 자식만 건너뛰고 부모를
        # 승격하면 부모는 promoted 로 데스크에서 빠지고 자식은 merged_into 라 독립 승격도 막혀,
        # 태그를 풀어도 되살릴 수 없는 상태가 된다(demote 를 거쳐야만 복구). 보류는 되돌릴 수 있다.
        if any(c[4] == "flagged" for c in children):
            print("  -> HOLD: 머지 자식이 검토 필요(flagged), 그룹 승격 보류")
            stats["held_flagged_child"] += len(members)
            continue

        if dry_run:
            # 미리보기 — 머지 자식 바코드까지 세어 실측(부모+자식)에 근접시킨다.
            # 충돌/중복은 예측 불가라 실제 붙는 바코드 수의 상한 근사다.
            promoted_masters += 1
            promoted_barcodes += len(members) + sum(1 for c in children if c[1] is not None)
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
            on conflict (master_key) do nothing
            returning id
        """, (rep[3], master_name, rep[6], rep[8], rep[9], rep[10], rep[11],
              rep[12], rep[13], rep[14], rep[15],
              rep[1], rep[17]))
        got = cur.fetchone()
        if got:
            master_id = got[0]
            promoted_masters += 1
        else:
            # 이미 존재 (재실행 또는 기존 master와 brand·상품명·원재료 일치)
            cur.execute("""
                select id, verified_status::text from product_masters
                where master_key = md5(%s || '|' || %s || '|' || %s)
            """, (rep[3], master_name, rep[8]))
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
            # 위에서 잠근 children 에서 이 멤버의 자식만 고른다 — 다시 조회하면 잠금 이후 바뀐
            # 값을 볼 수 있어(판정과 승격이 어긋남) 같은 집합을 그대로 쓴다.
            targets = [(m[0], m[7], m[5])]  # (id, barcode, size)
            targets.extend((c[0], c[1], c[2]) for c in children
                           if c[3] == str(m[0]) and c[1] is not None)
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
