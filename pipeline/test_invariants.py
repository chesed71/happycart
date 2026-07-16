"""불변식 반복 테스트 — 코드리뷰 HIGH/MEDIUM 대응 (rollback-wrapped).

각 테스트는 자체 픽스처를 트랜잭션 안에서 만들고 rollback 하므로 DB를 오염시키지
않는다. datadesk_review 롤 권한·RPC 불변식·rollback 스코프·no-clobber·경쟁을 검증한다.

사용: pipeline/.venv/bin/python test_invariants.py
참고: docs/superpowers/specs/2026-06-16-datadesk-collected-products-plan.md §9
"""
from __future__ import annotations

import sys

import psycopg

from common import dsn

REVIEW_DSN = "postgresql://datadesk_review:datadesk_review@127.0.0.1:54322/happycart"

results: list[tuple[str, bool, str]] = []


def ean13(prefix12: str) -> str:
    """12자리 prefix에 EAN-13 체크 디지트를 붙인다 (is_valid_ean과 동일 규칙)."""
    total = 0
    for idx, c in enumerate(prefix12):
        i = idx + 1
        total += int(c) * (3 if (12 - i) % 2 == 0 else 1)
    return prefix12 + str((10 - total % 10) % 10)


# 시드/실데이터와 충돌하지 않는 합성 바코드 (prefix '99...')
SYN_BC_1 = ean13("990000000000")
SYN_BC_2 = ean13("990000000001")


def check(name: str, cond: bool, detail: str = "") -> None:
    results.append((name, cond, detail))


_ctr = [0]


def _fixture(cur, *, stage="judged", barcode="8801037088168", ingredients="밀가루, 설탕",
             confidence="high", review_decision=None, verdict="not_okay") -> str:
    """collected_products 테스트 행 1개 생성, id 반환. (호출 트랜잭션 내에서만 유효)"""
    _ctr[0] += 1
    cur.execute(
        """
        insert into collected_products
          (source, source_ref, raw, brand, name, size, category, barcode,
           ingredients_raw, confidence, ingredients_tokens, verdict, rule_version,
           computed_at, stage, review_decision)
        values ('coupang', %s, '{}'::jsonb, 'B', 'N', '10g', 'cat', %s, %s, %s,
                '{밀가루,설탕}', %s::verdict_enum, 'v1.1.0', now(), %s, %s)
        returning id
        """,
        (f"test-{_ctr[0]}-{stage}-{barcode}", barcode, ingredients,
         confidence, verdict, stage, review_decision),
    )
    return cur.fetchone()[0]


def _promotable_parent(cur, barcode, name="N-parent"):
    """승격 가능한 부모(verified/judged, master NOT NULL 배열까지 채움) 생성, id 반환."""
    pid = _fixture(cur, stage="judged", barcode=barcode,
                   review_decision="verified", confidence="high")
    cur.execute(
        """update collected_products set name=%s,
             bad_ingredients_detected='{}', good_ingredients_detected='{}',
             verdict_reason_codes='{}' where id=%s""",
        (name, pid),
    )
    return pid


def _merged_child(cur, parent, barcode, *, stage="parsed", review_decision="needs_fix",
                  confidence="high"):
    """부모에 머지된 자식 행(raw.merged_into=parent) 생성, id 반환.
    stage='judged'+review_decision='verified'로 주면 자체 후보 게이트도 통과하게 된다."""
    cur.execute(
        """
        insert into collected_products
          (source, source_ref, raw, brand, name, size, category, barcode,
           ingredients_raw, confidence, ingredients_tokens, verdict, rule_version,
           computed_at, stage, review_decision,
           bad_ingredients_detected, good_ingredients_detected, verdict_reason_codes)
        values ('coupang', %s, jsonb_build_object('merged_into', %s::text),
                'B', 'N-child', '20g', 'cat', %s, '밀가루, 설탕', %s,
                '{밀가루,설탕}', 'not_okay'::verdict_enum, 'v1.1.0', now(),
                %s, %s, '{}', '{}', '{}')
        returning id
        """,
        (f"test-child-{barcode}", parent, barcode, confidence, stage, review_decision),
    )
    return cur.fetchone()[0]


def test_rpc_invariants():
    """RPC: stage=parsed 복원 + 파생 비움 + reviewed_at + confidence 보존/정합."""
    with psycopg.connect(dsn()) as conn, conn.cursor() as cur:
        cur.execute("begin")
        cid = _fixture(cur, confidence="high")
        cur.execute("select public.review_collected_product(%s,%s,%s,%s,%s,%s)",
                    (cid, "8801037088168", "원재료 그대로", "", "verified", "n"))
        cur.execute("""select stage, confidence, review_decision, reviewed_at is not null,
                       ingredients_tokens, verdict from collected_products where id=%s""", (cid,))
        stage, conf, dec, reviewed, tokens, verdict = cur.fetchone()
        check("RPC stage→parsed", stage == "parsed", stage)
        check("RPC 파생 비움(tokens)", tokens is None, str(tokens))
        check("RPC 파생 비움(verdict)", verdict is None, str(verdict))
        check("RPC reviewed_at 기록", reviewed is True)
        check("RPC decision 저장", dec == "verified", str(dec))
        check("RPC confidence 보존(미지정)", conf == "high", str(conf))
        # 원재료 비우면 confidence null (unreadable 정합)
        cur.execute("select public.review_collected_product(%s,%s,%s,%s,%s,%s)",
                    (cid, "8801037088168", "", "", "needs_fix", ""))
        cur.execute("select ingredients_raw, confidence from collected_products where id=%s", (cid,))
        ing, conf2 = cur.fetchone()
        check("RPC unreadable→ingredients NULL", ing is None, str(ing))
        check("RPC unreadable→confidence NULL", conf2 is None, str(conf2))
        conn.rollback()


def test_promoted_lock():
    """RPC: promoted 행은 잠금(예외)."""
    with psycopg.connect(dsn()) as conn, conn.cursor() as cur:
        cur.execute("begin")
        cid = _fixture(cur, stage="promoted")
        try:
            cur.execute("select public.review_collected_product(%s,%s,%s,%s,%s,%s)",
                        (cid, "8801037088168", "x", "high", "verified", ""))
            check("promoted 잠금", False, "예외 안 남")
        except psycopg.Error as e:
            check("promoted 잠금", "promoted" in str(e), str(e)[:50])
        conn.rollback()


def test_bad_inputs():
    """RPC: 잘못된 바코드/decision 거부. 각 케이스를 독립 트랜잭션에서."""
    cases = [
        ("바코드 체크섬 거부", "8801037088160", "x", "high", "verified", "invalid barcode"),
        ("decision 거부", "8801037088168", "x", "high", "bogus", "invalid decision"),
    ]
    for label, bc, ing, conf, dec, marker in cases:
        with psycopg.connect(dsn()) as conn, conn.cursor() as cur:
            cur.execute("begin")
            cid = _fixture(cur)
            try:
                cur.execute("select public.review_collected_product(%s,%s,%s,%s,%s,%s)",
                            (cid, bc, ing, conf, dec, ""))
                check(label, False, "예외 안 남")
            except psycopg.Error as e:
                check(label, marker in str(e), str(e)[:40])
            conn.rollback()


def test_least_privilege():
    """datadesk_review: 직접 UPDATE/타테이블 거부, RPC만 허용."""
    with psycopg.connect(REVIEW_DSN) as conn, conn.cursor() as cur:
        for label, q in [
            ("직접 UPDATE 거부", "update collected_products set stage='promoted'"),
            ("타테이블 SELECT 거부", "select count(*) from product_masters"),
            ("직접 INSERT 거부", "insert into collected_products(source,source_ref,raw) values('x','y','{}')"),
        ]:
            try:
                cur.execute(q)
                check(label, False, "허용됨")
            except psycopg.Error as e:
                check(label, "permission denied" in str(e), str(e)[:40])
            conn.rollback()


def test_for_update_race():
    """FOR UPDATE: 다른 트랜잭션이 행을 잠그면 RPC가 대기(경쟁 차단)."""
    with psycopg.connect(dsn()) as setup, setup.cursor() as scur:
        scur.execute("begin")
        cid = _fixture(scur, stage="judged")
        setup.commit()  # 픽스처 커밋 (다른 연결에서 보이도록)
    try:
        locker = psycopg.connect(dsn())
        lcur = locker.cursor()
        lcur.execute("begin")
        lcur.execute("select id from collected_products where id=%s for update", (cid,))  # 행 잠금
        # 두 번째 연결: RPC가 잠긴 행을 기다려야 한다 → statement_timeout 으로 블로킹 확인
        with psycopg.connect(dsn()) as conn2, conn2.cursor() as c2:
            c2.execute("set statement_timeout = '800ms'")
            try:
                c2.execute("select public.review_collected_product(%s,%s,%s,%s,%s,%s)",
                           (cid, "8801037088168", "x", "high", "verified", ""))
                check("FOR UPDATE 경쟁 대기", False, "대기 안 하고 진행함")
            except psycopg.Error as e:
                check("FOR UPDATE 경쟁 대기", "timeout" in str(e).lower(), str(e)[:40])
        locker.rollback()
        lcur.close(); locker.close()
    finally:
        with psycopg.connect(dsn()) as cleanup, cleanup.cursor() as cc:
            cc.execute("delete from collected_products where id=%s", (cid,))
            cleanup.commit()


def test_rollback_scope():
    """rollback: verified 승격분은 보존, non-verified만 되돌림."""
    with psycopg.connect(dsn()) as conn, conn.cursor() as cur:
        cur.execute("begin")
        # 가짜 master 2개 + collected 2개 (verified / non-verified) promoted
        cur.execute("""insert into product_masters
            (brand,name,ingredients_raw,verdict,rule_version,computed_at,source,source_checked_at)
            values ('B','N1','i1','okay','v1',now(),'t',now()),
                   ('B','N2','i2','okay','v1',now(),'t',now())
            returning id""")
        m1 = cur.fetchone()[0]
        cur.execute("select id from product_masters order by created_at desc limit 1 offset 0")
        cur.execute("select id from product_masters where ingredients_raw='i2'")
        m2 = cur.fetchone()[0]
        cur.execute("select id from product_masters where ingredients_raw='i1'")
        m1 = cur.fetchone()[0]
        vid = _fixture(cur, stage="promoted", barcode="8801037088168", review_decision="verified")
        nid = _fixture(cur, stage="promoted", barcode="4006381333931", review_decision=None)
        cur.execute("update collected_products set promoted_master_id=%s where id=%s", (m1, vid))
        cur.execute("update collected_products set promoted_master_id=%s where id=%s", (m2, nid))
        # 스코프 로직(스크립트와 동일): non-verified만 대상
        cur.execute("""select count(*) from collected_products
                       where stage='promoted' and review_decision is distinct from 'verified'
                       and id in (%s,%s)""", (vid, nid))
        scoped = cur.fetchone()[0]
        check("rollback 스코프=non-verified만", scoped == 1, f"대상 {scoped}개(1 기대)")
        conn.rollback()


def test_promote_locks_during_review():
    """promote 측 잠금: 후보 FOR UPDATE 가 잡힌 동안 review RPC 가 대기(경쟁 차단).

    이전 테스트(test_for_update_race)는 RPC가 기존 잠금 뒤에서 대기함만 봤다.
    여기선 promote.py 와 동일한 후보 SELECT ... FOR UPDATE 가 review 를 막는지 본다.
    """
    with psycopg.connect(dsn()) as s, s.cursor() as sc:
        sc.execute("begin")
        cid = _fixture(sc, stage="judged", review_decision="verified", barcode="8801037088168")
        s.commit()
    try:
        promoter = psycopg.connect(dsn())
        pc = promoter.cursor()
        pc.execute("begin")
        # promote.py 의 실제 후보 잠금 쿼리를 그대로 실행 (복제 아님 — FOR UPDATE가 빠지면
        # 잠금이 안 걸려 아래 review 가 대기하지 않으므로 테스트가 깨진다 = 회귀 방지).
        from promote import CANDIDATE_SELECT
        pc.execute(CANDIDATE_SELECT)
        locked_ids = {str(r[0]) for r in pc.fetchall()}
        check("promote 후보에 fixture 포함(잠금)", str(cid) in locked_ids)
        with psycopg.connect(dsn()) as c2conn, c2conn.cursor() as c2:
            c2.execute("set statement_timeout='800ms'")
            try:
                c2.execute("select public.review_collected_product(%s,%s,%s,%s,%s,%s)",
                           (cid, "8801037088168", "x", "high", "verified", ""))
                check("promote 잠금 중 review 대기", False, "대기 안 함")
            except psycopg.Error as e:
                check("promote 잠금 중 review 대기", "timeout" in str(e).lower(), str(e)[:40])
        promoter.rollback()
        pc.close(); promoter.close()
    finally:
        with psycopg.connect(dsn()) as cl, cl.cursor() as cc:
            cc.execute("delete from collected_products where id=%s", (cid,))
            cl.commit()


def test_rollback_shared_master():
    """rollback 실제 실행: verified/non-verified 가 공유한 master 에서 verified 보존."""
    with psycopg.connect(dsn()) as conn, conn.cursor() as cur:
        cur.execute("begin")
        cur.execute("""insert into product_masters
            (brand,name,ingredients_raw,verdict,rule_version,computed_at,source,
             source_checked_at,verified_status)
            values ('B','N','shared-i','okay','v1',now(),'t',now(),'unverified')
            returning id""")
        m = cur.fetchone()[0]
        vid = _fixture(cur, stage="promoted", barcode=SYN_BC_1, review_decision="verified")
        nid = _fixture(cur, stage="promoted", barcode=SYN_BC_2, review_decision=None)
        cur.execute("update collected_products set promoted_master_id=%s where id in (%s,%s)",
                    (m, vid, nid))
        cur.execute("insert into product_barcodes(barcode,master_id,size) values (%s,%s,'1'),(%s,%s,'1')",
                    (SYN_BC_1, m, SYN_BC_2, m))
        # 실제 rollback 함수 실행
        cur.execute("select public.rollback_ungated_promotions()")
        cur.execute("select exists(select 1 from product_masters where id=%s)", (m,))
        check("rollback: 공유 master 보존", cur.fetchone()[0] is True)
        cur.execute("select exists(select 1 from product_barcodes where barcode=%s)", (SYN_BC_1,))
        check("rollback: verified 바코드 보존", cur.fetchone()[0] is True)
        cur.execute("select exists(select 1 from product_barcodes where barcode=%s)", (SYN_BC_2,))
        check("rollback: non-verified 바코드 제거", cur.fetchone()[0] is False)
        cur.execute("select stage from collected_products where id=%s", (nid,))
        check("rollback: non-verified 행→judged", cur.fetchone()[0] == "judged")
        cur.execute("select stage from collected_products where id=%s", (vid,))
        check("rollback: verified 행 promoted 유지", cur.fetchone()[0] == "promoted")
        conn.rollback()


def test_rollback_shared_barcode():
    """rollback: verified·non-verified가 같은 barcode를 가리키는 손상 데이터에서
    verified의 barcode link가 보존되어야 한다 (HIGH 코멘트 케이스)."""
    with psycopg.connect(dsn()) as conn, conn.cursor() as cur:
        cur.execute("begin")
        cur.execute("""insert into product_masters
            (brand,name,ingredients_raw,verdict,rule_version,computed_at,source,
             source_checked_at,verified_status)
            values ('B','N','shared-bc','okay','v1',now(),'t',now(),'unverified')
            returning id""")
        m = cur.fetchone()[0]
        # 두 행이 같은 barcode (손상 상태). product_barcodes는 PK라 1행만 존재.
        vid = _fixture(cur, stage="promoted", barcode=SYN_BC_1, review_decision="verified")
        nid = _fixture(cur, stage="promoted", barcode=SYN_BC_1, review_decision=None)
        cur.execute("update collected_products set promoted_master_id=%s where id in (%s,%s)",
                    (m, vid, nid))
        cur.execute("insert into product_barcodes(barcode,master_id,size) values (%s,%s,'1')",
                    (SYN_BC_1, m))
        cur.execute("select public.rollback_ungated_promotions()")
        cur.execute("select exists(select 1 from product_barcodes where barcode=%s)", (SYN_BC_1,))
        check("공유 barcode: verified link 보존", cur.fetchone()[0] is True)
        cur.execute("select exists(select 1 from product_masters where id=%s)", (m,))
        check("공유 barcode: master 보존", cur.fetchone()[0] is True)
        cur.execute("select stage from collected_products where id=%s", (vid,))
        check("공유 barcode: verified promoted 유지", cur.fetchone()[0] == "promoted")
        cur.execute("select stage from collected_products where id=%s", (nid,))
        check("공유 barcode: non-verified→judged", cur.fetchone()[0] == "judged")
        conn.rollback()


def test_rollback_divergent_owner():
    """rollback: 같은 barcode를 verified·non-verified가 다른 master로 주장하는(divergent)
    손상 데이터. verified를 진실로 보고, 그 barcode가 verified의 master에 그대로 남고
    link(master_id)도 verified.promoted_master_id와 일치해야 한다."""
    with psycopg.connect(dsn()) as conn, conn.cursor() as cur:
        cur.execute("begin")
        cur.execute("""insert into product_masters
            (brand,name,ingredients_raw,verdict,rule_version,computed_at,source,
             source_checked_at,verified_status)
            values ('B','MV','mv-i','okay','v1',now(),'t',now(),'unverified'),
                   ('B','MN','mn-i','okay','v1',now(),'t',now(),'unverified')
            returning id""")
        mv = cur.fetchone()[0]
        cur.execute("select id from product_masters where ingredients_raw='mn-i'")
        mn = cur.fetchone()[0]
        # verified: barcode X, master MV (일관). non-verified: barcode X, master MN (divergent).
        vid = _fixture(cur, stage="promoted", barcode=SYN_BC_1, review_decision="verified")
        nid = _fixture(cur, stage="promoted", barcode=SYN_BC_1, review_decision=None)
        cur.execute("update collected_products set promoted_master_id=%s where id=%s", (mv, vid))
        cur.execute("update collected_products set promoted_master_id=%s where id=%s", (mn, nid))
        # 실제 link: X → MV (verified 소유)
        cur.execute("insert into product_barcodes(barcode,master_id,size) values (%s,%s,'1')",
                    (SYN_BC_1, mv))
        cur.execute("select public.rollback_ungated_promotions()")
        cur.execute("select master_id from product_barcodes where barcode=%s", (SYN_BC_1,))
        row = cur.fetchone()
        check("divergent: verified barcode 보존", row is not None)
        check("divergent: link == verified.promoted_master_id", row and str(row[0]) == str(mv),
              f"{row and row[0]} vs {mv}")
        cur.execute("select stage from collected_products where id=%s", (vid,))
        check("divergent: verified promoted 유지", cur.fetchone()[0] == "promoted")
        cur.execute("select exists(select 1 from product_masters where id=%s)", (mv,))
        check("divergent: verified master(MV) 보존", cur.fetchone()[0] is True)
        conn.rollback()


def test_rollback_preserves_merged_child():
    """rollback: 머지 자식(promoted∧non-verified)은 되돌리지 않는다.

    게이트 도입 후 non-verified promoted 는 '사람이 바코드 합친 자식'뿐이다(부모는
    verified 게이트 통과). pre-gate 미검수 승격(merged_into 없음)만 롤백 대상이어야 하며,
    의도된 머지 자식은 stage·바코드 링크가 보존돼야 한다(PR #12 MEDIUM 대응)."""
    from collections import Counter
    from promote import run_promotion
    with psycopg.connect(dsn()) as conn, conn.cursor() as cur:
        cur.execute("begin")
        parent = _promotable_parent(cur, SYN_BC_1)
        child = _merged_child(cur, parent, SYN_BC_2)  # stage=parsed, needs_fix
        run_promotion(cur, id=str(parent), stats=Counter())
        # 사전조건: 자식이 실제로 부모와 동반 승격됐는지
        cur.execute("select stage from collected_products where id=%s", (child,))
        check("사전: 머지 자식 동반 승격", cur.fetchone()[0] == "promoted")
        # 실제 rollback 함수 실행
        cur.execute("select public.rollback_ungated_promotions()")
        cur.execute("select stage from collected_products where id=%s", (child,))
        cstage = cur.fetchone()[0]
        check("rollback: 머지 자식 promoted 유지", cstage == "promoted", str(cstage))
        cur.execute("select exists(select 1 from product_barcodes where barcode=%s)", (SYN_BC_2,))
        check("rollback: 머지 자식 바코드 링크 보존", cur.fetchone()[0] is True)
        cur.execute("select stage from collected_products where id=%s", (parent,))
        check("rollback: verified 부모 promoted 유지", cur.fetchone()[0] == "promoted")
        conn.rollback()


def test_no_clobber():
    """extract upsert: reviewed_at 있는 행은 갱신 제외 (UPSERT_SQL where 절 검증)."""
    from common import UPSERT_SQL
    ok = "reviewed_at is null" in UPSERT_SQL and "stage in ('raw', 'parsed')" in UPSERT_SQL
    check("no-clobber 가드(UPSERT_SQL)", ok, "reviewed_at is null 조건 존재")


def test_clean_product_name():
    """표시명 정제: 선두 판촉/채널 브래킷([SCO],【단독행사】) 제거 + 끝용량·앞브랜드 제거,
    맛/버전 괄호는 보존 (DB 불필요한 순수함수 검증)."""
    from promote import clean_product_name as c
    cases = [
        # (name, brand, expected)
        ("[SCO] 롯데 죠스바젤리 (70G)", "롯데", "죠스바젤리"),      # 선두 브래킷+브랜드+용량 모두 제거
        ("【단독행사】 코르도리바 엑스트라버진 올리브오일", "미성패밀리",
         "코르도리바 엑스트라버진 올리브오일"),                     # 선두 모난괄호 제거
        ("[SCO] 마즈 트윅스싱글 (46G)", "한국마즈", "마즈 트윅스싱글"),  # 브랜드 불일치 토큰은 보존
        ("오레오 샌드쿠키 화이트 (100G)", "오레오", "샌드쿠키 화이트"),  # 기존 동작(브랜드+용량) 회귀 방지
        ("(밀크) 초코바", "오레오", "(밀크) 초코바"),                 # 맛 괄호는 보존(브래킷 아님)
        ("그냥상품", "브랜드", "그냥상품"),                          # 접두 없으면 무변화
    ]
    for name, brand, exp in cases:
        got = c(name, brand)
        check(f"clean_product_name({name!r})", got == exp, f"got={got!r} exp={exp!r}")


def test_merged_child_promotes_with_parent():
    """승격: verified 부모에 머지된 자식 바코드는 부모 master 로 동반 승격되고,
    자식의 사람 검수 필드(review_decision)는 건드리지 않는다(머지 관계 근거)."""
    from collections import Counter
    from promote import run_promotion
    with psycopg.connect(dsn()) as conn, conn.cursor() as cur:
        cur.execute("begin")
        # 승격 후보 부모(verified, judged, 모든 게이트 통과)
        parent = _fixture(cur, stage="judged", barcode=SYN_BC_1,
                          review_decision="verified", confidence="high")
        # product_masters 는 detected/reason 배열이 NOT NULL — 부모에 빈 배열을 채운다.
        cur.execute("""update collected_products set
                         bad_ingredients_detected='{}', good_ingredients_detected='{}',
                         verdict_reason_codes='{}' where id=%s""", (parent,))
        # 머지 자식: 자체 바코드+용량, review_decision='needs_fix', stage='parsed'.
        # 부모에 raw.merged_into 로 붙어 있다(바코드 합치기 결과).
        cur.execute(
            """
            insert into collected_products
              (source, source_ref, raw, brand, name, size, category, barcode,
               ingredients_raw, confidence, ingredients_tokens, verdict, rule_version,
               computed_at, stage, review_decision)
            values ('coupang', %s, jsonb_build_object('merged_into', %s::text),
                    'B', 'N-child', '20g', 'cat', %s, '밀가루, 설탕', 'high',
                    '{밀가루,설탕}', 'not_okay'::verdict_enum, 'v1.1.0', now(),
                    'parsed', 'needs_fix')
            returning id
            """,
            (f"test-child-{SYN_BC_2}", parent, SYN_BC_2),
        )
        child = cur.fetchone()[0]

        run_promotion(cur, id=str(parent), stats=Counter())

        cur.execute(
            "select stage, review_decision, promoted_master_id from collected_products where id=%s",
            (child,),
        )
        cstage, creview, cmaster = cur.fetchone()
        check("자식 동반 승격(stage=promoted)", cstage == "promoted", str(cstage))
        check("자식 review_decision 불변(needs_fix)", creview == "needs_fix", str(creview))
        cur.execute("select master_id from product_barcodes where barcode=%s", (SYN_BC_2,))
        bcrow = cur.fetchone()
        check("자식 바코드 product_barcodes 생성", bcrow is not None)
        cur.execute("select promoted_master_id from collected_products where id=%s", (parent,))
        pmaster = cur.fetchone()[0]
        check("자식·부모 동일 master 연결",
              bcrow is not None and str(bcrow[0]) == str(pmaster) == str(cmaster),
              f"child_bc={bcrow and bcrow[0]} parent={pmaster} child={cmaster}")
        conn.rollback()


def test_rejected_merged_child_not_promoted():
    """머지 자식이 stage='rejected'(자격 박탈)면 부모 승격에 딸려가지 않는다."""
    from collections import Counter
    from promote import run_promotion
    with psycopg.connect(dsn()) as conn, conn.cursor() as cur:
        cur.execute("begin")
        parent = _promotable_parent(cur, SYN_BC_1)
        child = _merged_child(cur, parent, SYN_BC_2, stage="rejected")
        run_promotion(cur, id=str(parent), stats=Counter())
        cur.execute("select stage from collected_products where id=%s", (child,))
        check("rejected 자식 미승격", cur.fetchone()[0] == "rejected")
        cur.execute("select count(*) from product_barcodes where barcode=%s", (SYN_BC_2,))
        check("rejected 자식 바코드 미생성", cur.fetchone()[0] == 0)
        conn.rollback()


def test_merged_child_barcode_conflict_held():
    """자식 바코드가 다른 master 소유면 재링크하지 않고 conflict 보류(health-critical)."""
    from collections import Counter
    from promote import run_promotion
    with psycopg.connect(dsn()) as conn, conn.cursor() as cur:
        cur.execute("begin")
        cur.execute("""insert into product_masters
            (brand,name,ingredients_raw,verdict,rule_version,computed_at,source,source_checked_at)
            values ('B','other','i-other','okay','v1',now(),'t',now()) returning id""")
        other_master = cur.fetchone()[0]
        cur.execute("insert into product_barcodes (barcode, master_id, size) values (%s,%s,%s)",
                    (SYN_BC_2, other_master, "99g"))
        parent = _promotable_parent(cur, SYN_BC_1)
        child = _merged_child(cur, parent, SYN_BC_2)
        run_promotion(cur, id=str(parent), stats=Counter())
        cur.execute("select stage from collected_products where id=%s", (child,))
        check("conflict 자식 보류(stage=conflict)", cur.fetchone()[0] == "conflict")
        cur.execute("select master_id from product_barcodes where barcode=%s", (SYN_BC_2,))
        check("자식 바코드 재링크 안 됨(원 master 유지)",
              str(cur.fetchone()[0]) == str(other_master))
        conn.rollback()


def test_held_group_child_not_promoted():
    """그룹이 name 불일치로 보류되면 그 멤버의 머지 자식도 승격되지 않는다."""
    from collections import Counter
    from promote import run_promotion
    with psycopg.connect(dsn()) as conn, conn.cursor() as cur:
        cur.execute("begin")
        p1 = _promotable_parent(cur, SYN_BC_1, name="이름하나")
        p2 = _promotable_parent(cur, SYN_BC_2, name="이름다름")  # 같은 brand+ingredients, 다른 name
        child = _merged_child(cur, p1, ean13("990000000002"))
        stats = Counter()
        run_promotion(cur, ids={str(p1), str(p2)}, stats=stats)
        cur.execute("select stage from collected_products where id=%s", (child,))
        check("held 그룹 자식 미승격", cur.fetchone()[0] == "parsed")
        check("그룹 보류 집계", stats.get("group_held", 0) == 2, str(dict(stats)))
        conn.rollback()


def test_merged_child_verified_promotes_via_parent_only():
    """자식이 자체적으로 judged+verified 여도 부모를 통해서만 승격 —
    중복 후보로 처리돼 stage 가 conflict 로 오염되지 않는다(순서 비의존)."""
    from collections import Counter
    from promote import run_promotion
    with psycopg.connect(dsn()) as conn, conn.cursor() as cur:
        cur.execute("begin")
        parent = _promotable_parent(cur, SYN_BC_1)
        child = _merged_child(cur, parent, SYN_BC_2, stage="judged",
                              review_decision="verified", confidence="high")
        stats = Counter()
        run_promotion(cur, ids={str(parent), str(child)}, stats=stats)
        cur.execute("select stage, promoted_master_id from collected_products where id=%s", (child,))
        cstage, cmaster = cur.fetchone()
        check("verified 자식 승격(conflict 아님)", cstage == "promoted", str(cstage))
        cur.execute("select promoted_master_id from collected_products where id=%s", (parent,))
        pmaster = cur.fetchone()[0]
        check("verified 자식 부모 master 로", str(cmaster) == str(pmaster),
              f"child={cmaster} parent={pmaster}")
        check("중복 후보 충돌 미발생", stats.get("barcode_conflict_held", 0) == 0, str(dict(stats)))
        conn.rollback()


def test_dryrun_counts_merged_child_barcodes():
    """dry-run 바코드 카운트가 머지 자식까지 포함한다(LOW: 자식 과소보고 방지).

    실제 실행은 부모+머지 자식 바코드를 붙이는데 dry-run 이 부모만 세면 미리보기가
    실측과 어긋난다. 자식 수를 더해 상한 근사로 맞춘다."""
    from collections import Counter
    from promote import run_promotion
    with psycopg.connect(dsn()) as conn, conn.cursor() as cur:
        cur.execute("begin")
        parent = _promotable_parent(cur, SYN_BC_1)
        _merged_child(cur, parent, SYN_BC_2)  # parsed, needs_fix
        pm, pb = run_promotion(cur, id=str(parent), dry_run=True, stats=Counter())
        check("dry-run master=1", pm == 1, f"pm={pm}")
        check("dry-run 바코드=부모+자식(2)", pb == 2, f"pb={pb}")
        # dry-run 은 쓰지 않는다 — 승격 흔적이 없어야
        cur.execute("select stage from collected_products where id=%s", (parent,))
        check("dry-run 미기록(부모 judged 유지)", cur.fetchone()[0] == "judged")
        conn.rollback()


def test_held_counts_scoped_to_ids():
    """held 카운트가 --id/--ids 스코프를 반영한다(LOW: 전역 카운트 오도 방지).

    스코프 승격 시 held_not_reviewed 가 전역 judged 를 세면 운영자를 오도한다.
    스코프된 id 집합으로 한정해야 한다."""
    from collections import Counter
    from promote import run_promotion
    with psycopg.connect(dsn()) as conn, conn.cursor() as cur:
        cur.execute("begin")
        # 미검수 judged 행 2개(둘 다 held: not_reviewed). 실 DB 에 다른 held 가 있어도
        # 스코프가 걸리면 대상 id 만 세야 하므로 결정적.
        h1 = _fixture(cur, stage="judged", barcode=SYN_BC_1, review_decision=None)
        _fixture(cur, stage="judged", barcode=SYN_BC_2, review_decision=None)
        stats = Counter()
        run_promotion(cur, id=str(h1), dry_run=True, stats=stats)
        check("held 스코프=1(전역 아님)", stats["held_not_reviewed"] == 1,
              f'held_not_reviewed={stats["held_not_reviewed"]}')
        conn.rollback()


def test_parent_barcode_conflict_holds_merged_child():
    """parent 바코드가 다른 master 소속이면 그 멤버의 자식도 붙이지 않는다.

    parent 만 conflict 처리하고 자식을 새 master 에 붙이면, parent 없이 자식만 달린
    shadow master 가 남아 '같은 상품=한 master' 병합 의도가 깨진다(PR #12 재검토 MEDIUM).
    자식은 parsed 로 hold 해 다음 실행에서 parent 와 함께 재시도하고, 빈 master 는 정리돼야."""
    from collections import Counter
    from promote import run_promotion
    with psycopg.connect(dsn()) as conn, conn.cursor() as cur:
        cur.execute("begin")
        # 기존의 '다른 상품' master 가 parent 바코드(SYN_BC_1)를 이미 소유(충돌 유발)
        cur.execute("""insert into product_masters
            (brand,name,ingredients_raw,verdict,rule_version,computed_at,source,source_checked_at)
            values ('B','다른상품','다른-원재료','okay','v1',now(),'t',now()) returning id""")
        other = cur.fetchone()[0]
        cur.execute("insert into product_barcodes(barcode,master_id,size) values (%s,%s,'1')",
                    (SYN_BC_1, other))
        # 승격 후보 parent(바코드 SYN_BC_1 → other 와 충돌) + 여유 바코드 자식(SYN_BC_2)
        parent = _promotable_parent(cur, SYN_BC_1)   # brand='B', ingredients='밀가루, 설탕'
        child = _merged_child(cur, parent, SYN_BC_2)
        run_promotion(cur, id=str(parent), stats=Counter())
        cur.execute("select stage from collected_products where id=%s", (parent,))
        check("parent 바코드 충돌→conflict", cur.fetchone()[0] == "conflict")
        cur.execute("select stage from collected_products where id=%s", (child,))
        cstage = cur.fetchone()[0]
        check("자식 hold(parsed) — shadow master 방지", cstage == "parsed", str(cstage))
        cur.execute("select count(*) from product_barcodes where barcode=%s", (SYN_BC_2,))
        check("자식 바코드 미attach", cur.fetchone()[0] == 0)
        # parent 데이터(brand='B', ingredients='밀가루, 설탕')로 만든 shadow master 미존재
        cur.execute("select count(*) from product_masters where ingredients_hash = md5(%s||'|'||%s)",
                    ("B", "밀가루, 설탕"))
        check("shadow master 미생성(빈 master 정리)", cur.fetchone()[0] == 0)
        # 기존 다른 master 는 보존
        cur.execute("select exists(select 1 from product_masters where id=%s)", (other,))
        check("기존 다른 master 보존", cur.fetchone()[0] is True)
        conn.rollback()


def main():
    for t in [test_rpc_invariants, test_promoted_lock, test_bad_inputs,
              test_least_privilege, test_for_update_race, test_promote_locks_during_review,
              test_rollback_scope, test_rollback_shared_master,
              test_rollback_shared_barcode, test_rollback_divergent_owner,
              test_rollback_preserves_merged_child, test_no_clobber,
              test_clean_product_name, test_merged_child_promotes_with_parent,
              test_rejected_merged_child_not_promoted, test_merged_child_barcode_conflict_held,
              test_held_group_child_not_promoted,
              test_merged_child_verified_promotes_via_parent_only,
              test_dryrun_counts_merged_child_barcodes, test_held_counts_scoped_to_ids,
              test_parent_barcode_conflict_holds_merged_child]:
        try:
            t()
        except Exception as e:  # noqa
            check(t.__name__, False, f"테스트 예외: {e}")

    failed = 0
    for name, ok, detail in results:
        mark = "PASS" if ok else "FAIL"
        if not ok:
            failed += 1
        print(f"  {mark}  {name}" + (f"  [{detail}]" if detail and not ok else ""))
    print(f"\n{len(results) - failed}/{len(results)} pass")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
