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

from common import COUNT_RE, connect, id_list_arg

# 검토 필요(flagged)와 종료 판정(missing_*) 태그 — 후보 쿼리와 머지 자식 보류 판정이 같은
# 집합을 쓴다(데이터데스크 레인 설계 2026-10-08)
BLOCKING_TAGS = ("flagged", "missing_barcode", "missing_image", "missing_ingredients")

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
      -- 검토 필요·종료 태그는 승격 제외 -- BLOCKING_TAGS와 같은 집합
      and coalesce(raw->>'review_tag', '') not in ('flagged','missing_barcode','missing_image','missing_ingredients')
      -- 삭제 RPC는 raw.deleted_at 만 찍고 stage·review_decision 은 그대로 둔다. 데이터데스크는
      -- 목록에서 숨기지만 여기서 거르지 않으면 지워진 행이 전체 배치에서 승격된다(자식 조회는
      -- 이미 같은 조건으로 거르고 있었다).
      and (raw->>'deleted_at') is null
    order by source, source_ref
    for update   -- 후보 행을 트랜잭션 동안 잠가 review RPC와의 경쟁 차단
"""

def candidate_query(*, id=None, ids=None, source=None, source_ref=None):
    """CANDIDATE_SELECT 에 범위 조건을 `order by`·`for update` 앞 WHERE 로 붙여 (sql, params) 반환.
    범위를 주면 범위 밖 후보는 잠기지 않는다(예전엔 전체를 잠근 뒤 Python 으로 걸렀다).
    비교 규칙은 예전 Python 필터와 같다: id 는 uuid 문자열(str(r[0]))과 정확히 일치, ids 는 문자열
    집합 포함, source·source_ref 는 정확히 일치. 범위가 없으면 CANDIDATE_SELECT 와 []."""
    conds, params = [], []
    if id:
        conds.append("id::text = %s")
        params.append(id)
    if ids is not None:
        conds.append("id::text = any(%s)")
        params.append([str(x) for x in ids])
    if source:
        conds.append("source = %s")
        params.append(source)
    if source_ref:
        conds.append("source_ref = %s")
        params.append(source_ref)
    if not conds:
        return CANDIDATE_SELECT, []
    marker = "    order by source, source_ref\n"
    head, tail = CANDIDATE_SELECT.split(marker)
    extra = "".join(f"      and {c}\n" for c in conds)
    return head + extra + marker + tail, params


# 그룹의 머지 자식을 한 번에 잠그고 태그까지 같이 읽는다. 잠그기 전에 태그만 세어 보면 그 사이
# 데이터데스크 RPC 가 flagged 를 걸어도 승격이 그대로 진행된다(TOCTOU) — 보류 판정과 실제 승격이
# 같은 잠긴 행 집합을 보도록 여기서 먼저 잠근다. 태그·검수 RPC 는 행을 FOR UPDATE 로 잡으므로
# 이 잠금 동안 대기한다. test_invariants.py 가 이 상수를 그대로 써서 경쟁을 재현한다.
# rejected(자격 박탈)·promoted(이미 승격)·삭제 자식은 제외 — attach RPC 의 머지 대상 탐색 필터와
# 동일 기준. 단일 홉만 훑는다(자식의 자식은 비대상).
MERGED_CHILDREN_LOCK = """
    select id, barcode, size, raw->>'merged_into', coalesce(raw->>'review_tag', ''),
           coalesce(raw->>'original_name', name)
    from collected_products
    where (raw->>'merged_into') = any(%s)
      and (raw->>'deleted_at') is null
      and stage not in ('promoted', 'rejected')
    order by id   -- 교착 회피: 항상 같은 순서로 잠근다
    for update
"""


# 이름 속 용량(+바로 붙은 곱셈 포장 "22gx20개"·"37.5g×24개"·"44g x 3"). 단위 뒤 영문자는 곱셈 x 만 허용.
SIZE_ANYWHERE_RE = re.compile(
    r"(?<![\d.])(\d+(?:\.\d+)?)\s*(kg|g|ml|l|L|G|ML|KG)(?!(?![xX])[A-Za-z])"
    r"(?:\s*[xX×*]\s*(\d+)\s*(개|입|봉|팩|병|캔|매|스틱)?)?"
)


def size_from_name(name: str | None) -> str | None:
    """머지 자식 상품명에서 용량을 뽑는다("바다마을 날치알 180g" → "180g", "22gx20개" → "22g × 20개").
    확실할 때만 돌려준다. 다음은 None(그룹 보류 → 사람이 입력):
      - 용량이 없음("2개입")
      - 서로 다른 용량이 둘 이상("단백질 20g (250 ml)", "210g (70g x 3번들)")
      - 용량과 떨어진 개수("54g, 4개", "540g(1박스- 10팩)", "(1박스-4통)") — 총량인지 낱개인지
        알 수 없다. "(1통)"처럼 1 은 무시.
    """
    # 천 단위 쉼표("1,000g")는 구분자가 아니다.
    text = re.sub(r"(?<=\d),(?=\d{3}(?!\d))", "", name or "")
    sizes = set()
    for m in SIZE_ANYWHERE_RE.finditer(text):
        if re.match(r"0\d", m.group(1)):  # "000g" 같은 잘린 숫자 제외
            continue
        size = f"{m.group(1)}{m.group(2)}"
        if m.group(3):
            size += f" × {m.group(3)}{m.group(4) or ''}"
        sizes.add(size)
    if len(sizes) != 1:
        return None
    rest = SIZE_ANYWHERE_RE.sub(" ", text)
    # 연속 곱셈("28gx20개x4통")은 한 단계만 읽혔으니 남은 배수가 있으면 보류.
    if re.search(r"[xX×*]\s*\d", rest):
        return None
    if any((COUNT_RE.fullmatch(t) or re.fullmatch(r"\d+(통|박스)", t)) and not re.match(r"1\D", t)
           for t in re.split(r"[\s,()\[\]/\-]+", rest)):
        return None
    return sizes.pop()


# 승격 실행끼리 직렬화하는 트랜잭션 advisory lock 키(고정값, 다른 advisory lock 사용처와 겹치지 않음).
# 후보 잠금이 범위로 좁아져 서로 다른 배치가 동시에 돌 수 있는데, 두 배치가 같은 신규 master 를
# 반대 순서로 INSERT 하면 master_key unique 대기로 교착한다. advisory lock 은 행을 잠그지 않아
# 범위 밖 검수 저장은 막지 않는다.
PROMOTE_ADVISORY_LOCK_KEY = 7_204_001_001


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

    cur.execute("select pg_advisory_xact_lock(%s)", (PROMOTE_ADVISORY_LOCK_KEY,))
    cand_sql, cand_params = candidate_query(
        id=id, ids=id_set, source=source, source_ref=source_ref)
    cur.execute(cand_sql, cand_params)
    rows = cur.fetchall()

    # 승격 보류 사유별 카운트 (judged인데 조건 미달). 검토 필요(flagged)와 종료 태그
    # (missing_*, BLOCKING_TAGS)는 보류 사유가 다르므로(사람이 다시 볼 필요 vs 데이터 자체가
    # 불완전) 각각 따로 센다 — 합치면 승격 0건·보류 0건으로 보여도 어느 사유인지 알 수 없다.
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
            and confidence is distinct from 'low') as held_flagged,
          -- 종료 태그(missing_barcode/missing_image/missing_ingredients) 때문에 후보에서 빠진
          -- 행. held_flagged 와 조건은 같고 review_tag 집합만 다르다 — 완결된 부모가 종료
          -- 태그 하나로 후보에서 빠지면 여기서 세지 않으면 held_flagged 처럼 원인 없이 사라진다.
          count(*) filter (where review_decision = 'verified'
            and coalesce(raw->>'review_tag', '') in
              ('missing_barcode', 'missing_image', 'missing_ingredients')
            and barcode is not null and ingredients_raw is not null
            and coalesce(array_length(ingredients_tokens, 1), 0) > 0
            and brand is not null and name is not null and size is not null
            and confidence is distinct from 'low') as held_closed
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
    not_reviewed, reviewed_incomplete, held_flagged, held_closed = cur.fetchone()
    stats["held_not_reviewed"] = not_reviewed
    stats["held_reviewed_incomplete"] = reviewed_incomplete
    stats["held_flagged"] = held_flagged
    stats["held_closed"] = held_closed

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

        # 검토 필요·종료 태그(BLOCKING_TAGS) 머지 자식이 하나라도 있으면 그룹째 보류한다. 자식만
        # 건너뛰고 부모를 승격하면 부모는 promoted 로 데스크에서 빠지고 자식은 merged_into 라
        # 독립 승격도 막혀, 태그를 풀어도 되살릴 수 없는 상태가 된다(demote 를 거쳐야만 복구).
        # 보류는 되돌릴 수 있다.
        if any(c[4] in BLOCKING_TAGS for c in children):
            print("  -> HOLD: 머지 자식이 검토 필요/종료 태그, 그룹 승격 보류")
            stats["held_flagged_child"] += len(members)
            continue

        # 용량이 빈 머지 자식은 자식 상품명에서 뽑아 쓴다. 자식 이름은 부모를 따르므로(데이터데스크
        # 2026-10-21_child_name_follows_parent.sql) 머지 전 원래 이름(raw.original_name)을 먼저 본다. 못 뽑으면 그룹째 보류한다 —
        # product_barcodes.size 는 NOT NULL 이라 그대로 넣으면 승격 전체가 실패하고, 자식만 빼면
        # 위 태그 보류와 같은 이유로 되살릴 수 없게 된다. 데스크에서 자식 용량을 넣으면 풀린다.
        child_sizes = {}
        no_size = []
        for c in children:
            if c[1] is None or c[2]:
                continue
            guessed = size_from_name(c[5])
            if guessed:
                child_sizes[c[0]] = guessed
            else:
                no_size.append(c[1])
        if no_size:
            print(f"  -> HOLD: 합쳐진 바코드 용량 없음: {', '.join(no_size)}")
            stats["held_child_no_size"] += len(members)
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
            targets.extend((c[0], c[1], c[2] or child_sizes.get(c[0])) for c in children
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
                    set stage = 'promoted', promoted_master_id = %s, promoted_at = now(),
                        prod_master_id = null, size = coalesce(size, %s)
                    where id = %s
                """, (master_id, tsize, tid))

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
    ap.add_argument("--ids", type=id_list_arg, default=None,
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
        print(f"  held_flagged(검토 필요 보류)={stats['held_flagged']} "
              f"held_closed(종료 태그 보류)={stats['held_closed']}")
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
