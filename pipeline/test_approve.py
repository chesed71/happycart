"""approve_service_products RPC(0022) 테스트 — 일괄 노출 승인의 원자성·낙관적 동시성.

운영 대상 역할의 테스트 DB happycart_test_target(testdb.connect_test)에서 돌린다. 픽스처는 트랜잭션 안에서 만들고
rollback 하며, 두 연결을 겹치는 경쟁 테스트만 커밋형이고 끝에서 합성 행(99 접두 바코드·APPROVETEST 브랜드)을 지운다.
운영 happycart·운영 Supabase 에는 연결하지 않는다.

사용: pipeline/.venv/bin/python test_approve.py
"""
from __future__ import annotations

import json
import sys
import threading
import uuid

import psycopg

from test_upload import _ean, _master, _wait_lock_wait
from testdb import connect_test, target_dsn

results = []


def check(name, cond, detail=""):
    results.append((name, cond, detail))


B1, B2 = _ean("990000000220"), _ean("990000000221")
BRAND = "APPROVETEST"
RACE_BRAND = "APPROVETEST_RACE"


def _insert(cur, ing, status="unverified", brand=BRAND):
    cur.execute("""insert into product_masters
        (brand,name,ingredients_raw,verdict,rule_version,computed_at,source,source_checked_at,verified_status)
        values (%s,'N',%s,'okay','v1',now(),'t',now(),%s) returning id""", (brand, ing, status))
    return str(cur.fetchone()[0])


def _token(cur, mid, delta=None):
    """데스크가 PostgREST 로 받는 것과 같은 ISO 문자열 updated_at. delta 는 interval 문자열."""
    expr = "updated_at" if delta is None else f"updated_at + interval '{delta}'"
    cur.execute(f"select to_jsonb({expr}) #>> '{{}}' from product_masters where id=%s", (mid,))
    return cur.fetchone()[0]


def _item(mid, at, status="unverified"):
    return {"id": mid, "updated_at": at, "expected_status": status}


def _approve(cur, items):
    cur.execute("select public.approve_service_products(%s::jsonb)", (json.dumps(items),))
    return cur.fetchone()[0]


def _state(cur, ids):
    cur.execute("""select id::text, verified_status::text, updated_at from product_masters
                   where id = any(%s::uuid[]) order by id""", (ids,))
    return cur.fetchall()


def _status(cur, mid):
    cur.execute("select verified_status::text from product_masters where id=%s", (mid,))
    r = cur.fetchone()
    return r[0] if r else None


def test_all_match_approves():
    with connect_test(target_dsn()) as conn, conn.cursor() as cur:
        a, b = _insert(cur, "i-ok-a"), _insert(cur, "i-ok-b")
        r = _approve(cur, [_item(a, _token(cur, a)), _item(b, _token(cur, b))])
        check("전부 맞음: ok 참", r.get("ok") is True, str(r))
        check("전부 맞음: count 2", r.get("count") == 2, str(r))
        check("전부 맞음: mismatches 빈 배열", r.get("mismatches") == [], str(r))
        check("전부 맞음: 둘 다 verified", (_status(cur, a), _status(cur, b)) == ("verified", "verified"))
        conn.rollback()


def test_any_mismatch_changes_nothing():
    with connect_test(target_dsn()) as conn, conn.cursor() as cur:
        good = _insert(cur, "i-mm-good")
        content = _insert(cur, "i-mm-content")
        review = _insert(cur, "i-mm-review", status="needs_review")
        missing = str(uuid.uuid4())
        cur.execute("select 1 from product_masters where id=%s", (missing,))
        assert cur.fetchone() is None
        content_bad = _item(content, _token(cur, content, "1 microsecond"))
        review_bad = _item(review, _token(cur, review), "unverified")
        missing_bad = _item(missing, _token(cur, good))
        cases = [
            ("content_changed", [content_bad], {content: "content_changed"}),
            ("status_changed", [review_bad], {review: "status_changed"}),
            ("missing", [missing_bad], {missing: "missing"}),
            ("섞임", [_item(good, _token(cur, good)), content_bad, review_bad, missing_bad],
             {content: "content_changed", review: "status_changed", missing: "missing"}),
        ]
        for label, items, want in cases:
            ids = [i["id"] for i in items]
            before = _state(cur, ids)
            r = _approve(cur, items)
            after = _state(cur, ids)
            got = {m["id"]: m["reason"] for m in r.get("mismatches", [])}
            check(f"어긋남({label}): ok 거짓", r.get("ok") is False, str(r))
            check(f"어긋남({label}): count 0", r.get("count") == 0, str(r))
            check(f"어긋남({label}): 사유 정확(항목마다 하나)",
                  got == want and len(r.get("mismatches", [])) == len(want), str(r.get("mismatches")))
            check(f"어긋남({label}): 요청 행 전부 그대로", before == after, f"{before} != {after}")
        conn.rollback()


def test_status_reason_precedes_content():
    """상태와 updated_at 이 둘 다 다르면 상태 사유를 우선한다."""
    with connect_test(target_dsn()) as conn, conn.cursor() as cur:
        m = _insert(cur, "i-prec", status="needs_review")
        r = _approve(cur, [_item(m, _token(cur, m, "1 second"), "unverified")])
        check("우선순위: status_changed", r.get("mismatches") == [{"id": m, "reason": "status_changed"}], str(r))
        conn.rollback()


def test_needs_review_single():
    with connect_test(target_dsn()) as conn, conn.cursor() as cur:
        m = _insert(cur, "i-nr", status="needs_review")
        r = _approve(cur, [_item(m, _token(cur, m), "needs_review")])
        check("needs_review 단건: ok 참·count 1", r.get("ok") is True and r.get("count") == 1, str(r))
        check("needs_review 단건: verified", _status(cur, m) == "verified")
        conn.rollback()


def test_rejects_bad_input():
    some = str(uuid.uuid4())
    at = "2026-10-11T00:00:00.123456+00:00"
    cases = [
        ("배열 아님(객체)", {"id": some, "updated_at": at, "expected_status": "unverified"}),
        ("빈 배열", []),
        ("같은 id 두 번", [_item(some, at), _item(some, at)]),
        ("같은 id 대소문자 다름", [_item(some, at), _item(some.upper(), at)]),
        ("UUID 아닌 id", [_item("not-a-uuid", at)]),
        ("updated_at 누락", [{"id": some, "expected_status": "unverified"}]),
        ("updated_at 해석 불가", [_item(some, "어제")]),
        ("expected_status verified", [_item(some, at, "verified")]),
        ("expected_status 누락", [{"id": some, "updated_at": at}]),
        ("항목이 객체 아님", ["x"]),
    ]
    with connect_test(target_dsn()) as conn, conn.cursor() as cur:
        for label, payload in cases:
            code = None
            try:
                cur.execute("select public.approve_service_products(%s::jsonb)", (json.dumps(payload),))
            except psycopg.Error as e:
                code = e.sqlstate
            conn.rollback()
            check(f"거부({label}): SQLSTATE 22023", code == "22023", str(code))
        code = None
        try:
            cur.execute("select public.approve_service_products(null)")
        except psycopg.Error as e:
            code = e.sqlstate
        conn.rollback()
        check("거부(null): SQLSTATE 22023", code == "22023", str(code))


def _bc(b):
    return {"barcode": b, "size": "1", "image_url": None, "image_source_url": None}


def _upload(cur, barcodes):
    m = _master(brand=RACE_BRAND, ing="i-approve-race")
    cur.execute("select public.upload_promoted_product(%s::jsonb, %s::jsonb)",
                (json.dumps(m), json.dumps(barcodes)))
    return cur.fetchone()[0]


def _race_setup():
    """B1 하나가 붙은 unverified master 를 커밋하고, 그 뒤 별 트랜잭션에서 화면 토큰(updated_at)을 읽는다."""
    with connect_test(target_dsn()) as c, c.cursor() as cur:
        r = _upload(cur, [_bc(B1)])
        c.commit()
        mid = str(r["master_id"])
        tok = _token(cur, mid)
        c.commit()
    return mid, tok


def _race_cleanup():
    with connect_test(target_dsn()) as c, c.cursor() as cur:
        cur.execute("delete from product_barcodes where barcode = any(%s)", ([B1, B2],))
        cur.execute("delete from product_masters where brand=%s", (RACE_BRAND,))


def test_race_upload_then_approve():
    """화면 토큰을 읽은 뒤 0021 업로드로 바코드가 붙으면(미커밋) 승인은 잠금 대기했다가 content_changed 로 거절."""
    out = {}
    try:
        _race_cleanup()
        mid, tok = _race_setup()
        with connect_test(target_dsn()) as a, connect_test(target_dsn()) as b:
            ca, cb = a.cursor(), b.cursor()
            ru = _upload(ca, [_bc(B1), _bc(B2)])
            check("경쟁1: 업로드 existing·B2 inserted",
                  ru["master_status"] == "existing" and {"barcode": B2, "status": "inserted"} in ru["barcodes"], str(ru))

            def run_b():
                try:
                    out["r"] = _approve(cb, [_item(mid, tok)])
                    b.commit()
                except Exception as e:  # noqa
                    out["e"] = e
                    b.rollback()
            t = threading.Thread(target=run_b)
            t.start()
            check("경쟁1: 승인이 업로드 커밋 전 잠금 대기", _wait_lock_wait(b.info.backend_pid))
            a.commit()
            t.join(timeout=30)
            r = out.get("r", {})
            check("경쟁1: 승인 완료(예외 없음)", "r" in out, str(out.get("e")))
            check("경쟁1: ok 거짓·content_changed",
                  r.get("ok") is False and r.get("mismatches") == [{"id": mid, "reason": "content_changed"}], str(r))
        with connect_test(target_dsn()) as c, c.cursor() as cur:
            check("경쟁1: master unverified 그대로", _status(cur, mid) == "unverified", _status(cur, mid))
    finally:
        _race_cleanup()


def test_race_approve_then_upload():
    """승인(미커밋) 중 같은 master 로 0021 업로드가 오면 잠금 대기했다가 verified_held, 새 바코드 미연결."""
    out = {}
    try:
        _race_cleanup()
        mid, tok = _race_setup()
        with connect_test(target_dsn()) as a, connect_test(target_dsn()) as b:
            ca, cb = a.cursor(), b.cursor()
            ra = _approve(ca, [_item(mid, tok)])
            check("경쟁2: 승인 ok 참", ra.get("ok") is True and ra.get("count") == 1, str(ra))

            def run_b():
                try:
                    out["r"] = _upload(cb, [_bc(B1), _bc(B2)])
                    b.commit()
                except Exception as e:  # noqa
                    out["e"] = e
                    b.rollback()
            t = threading.Thread(target=run_b)
            t.start()
            check("경쟁2: 업로드가 승인 커밋 전 잠금 대기", _wait_lock_wait(b.info.backend_pid))
            a.commit()
            t.join(timeout=30)
            r = out.get("r", {})
            check("경쟁2: 업로드 완료(예외 없음)", "r" in out, str(out.get("e")))
            check("경쟁2: verified_held", r.get("master_status") == "verified_held", str(r))
            check("경쟁2: 보류 결과는 B1 exists 만", r.get("barcodes") == [{"barcode": B1, "status": "exists"}], str(r))
        with connect_test(target_dsn()) as c, c.cursor() as cur:
            cur.execute("select exists(select 1 from product_barcodes where barcode=%s)", (B2,))
            check("경쟁2: 새 바코드 B2 미연결", cur.fetchone()[0] is False)
            check("경쟁2: master verified", _status(cur, mid) == "verified", _status(cur, mid))
    finally:
        _race_cleanup()


def test_execute_privilege():
    """0022 실행 권한: anon·authenticated 불가, service_role 만(0018 과 같은 회수). 권한 카탈로그로 확인."""
    fn = "public.approve_service_products(jsonb)"
    with connect_test(target_dsn()) as c, c.cursor() as cur:
        cur.execute("select exists(select 1 from pg_roles where rolname='anon')")
        if not cur.fetchone()[0]:
            print("  SKIP  test_execute_privilege: 롤 없음(anon)")
            return
        for role, want in (("anon", False), ("authenticated", False), ("service_role", True)):
            cur.execute("select has_function_privilege(%s, %s, 'execute')", (role, fn))
            got = cur.fetchone()[0]
            check(f"0022 권한: {role} execute={want}", got is want, str(got))
        cur.execute("""select p.prosecdef, p.proconfig from pg_proc p
                       where p.oid = %s::regprocedure""", (fn,))
        secdef, conf = cur.fetchone()
        check("0022: security definer", secdef is True)
        check("0022: search_path 고정", conf is not None and any(x.startswith("search_path=") for x in conf), str(conf))
        c.rollback()


def main():
    for t in [test_all_match_approves, test_any_mismatch_changes_nothing, test_status_reason_precedes_content,
              test_needs_review_single, test_rejects_bad_input,
              test_race_upload_then_approve, test_race_approve_then_upload,
              test_execute_privilege]:
        try:
            t()
        except Exception as e:  # noqa
            check(t.__name__, False, f"예외: {e}")
    failed = sum(1 for _, ok, _ in results if not ok)
    for name, ok, detail in results:
        print(f"  {'PASS' if ok else 'FAIL'}  {name}" + (f"  [{detail}]" if detail and not ok else ""))
    print(f"\n{len(results) - failed}/{len(results)} pass")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
