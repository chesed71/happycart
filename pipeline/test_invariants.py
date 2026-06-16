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


def _fixture(cur, *, stage="judged", barcode="8801037088168", ingredients="밀가루, 설탕",
             confidence="high", review_decision=None, verdict="not_okay") -> str:
    """collected_products 테스트 행 1개 생성, id 반환. (호출 트랜잭션 내에서만 유효)"""
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
        (f"test-{psycopg.__version__}-{stage}-{barcode}", barcode, ingredients,
         confidence, verdict, stage, review_decision),
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
            values ('B','N1','i1','insufficient','v1',now(),'t',now()),
                   ('B','N2','i2','insufficient','v1',now(),'t',now())
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
        # promote.py 의 후보 잠금과 동일
        pc.execute("""select id from collected_products
                      where id=%s and stage='judged' and review_decision='verified'
                      for update""", (cid,))
        check("promote 후보 FOR UPDATE 획득", pc.fetchone() is not None)
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
            values ('B','N','shared-i','insufficient','v1',now(),'t',now(),'unverified')
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


def test_no_clobber():
    """extract upsert: reviewed_at 있는 행은 갱신 제외 (UPSERT_SQL where 절 검증)."""
    from common import UPSERT_SQL
    ok = "reviewed_at is null" in UPSERT_SQL and "stage in ('raw', 'parsed')" in UPSERT_SQL
    check("no-clobber 가드(UPSERT_SQL)", ok, "reviewed_at is null 조건 존재")


def main():
    for t in [test_rpc_invariants, test_promoted_lock, test_bad_inputs,
              test_least_privilege, test_for_update_race, test_promote_locks_during_review,
              test_rollback_scope, test_rollback_shared_master, test_no_clobber]:
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
