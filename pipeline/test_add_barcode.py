"""add_barcode_to_master RPC(0024) 테스트 (rollback-wrapped).

이미 운영에 있는 master 에 바코드만 연결하는 RPC 의 불변식을 검증한다: verified·unverified 연결, needs_review·
identity_mismatch 보류와 보류 시 exists 반환, conflict, 섞인 재시도, updated_at 갱신, master 내용 불변, 권한,
0021 과 동시 실행 시 교착 없음.
RPC 테스트는 전용 테스트 DB happycart_test(testdb.connect_test)에서 트랜잭션 후 rollback 한다. 운영 happycart 에는 연결하지 않는다.

사용: pipeline/.venv/bin/python test_add_barcode.py
"""
from __future__ import annotations

import json
import sys
import threading

import psycopg.errors

from test_upload import _CONTENT_COLS, _call, _ean, _master, _wait_lock_wait
from testdb import connect_test, source_dsn, target_dsn
from upload_prod import ingredients_hash, master_key

results = []


def check(name, cond, detail=""):
    results.append((name, cond, detail))


B1, B2, B3 = _ean("990000002410"), _ean("990000002411"), _ean("990000002412")
BRAND = "ADDBCTEST"


def bc(b):
    return {"barcode": b, "size": "1", "image_url": None, "image_source_url": None}


def _seed(cur, name="N", ing="i-add", status="unverified", barcodes=(B1,)):
    """master 하나와 바코드를 만들고 updated_at 을 하루 전으로 되돌린다(트리거 우회). (id, 기대 identity)."""
    cur.execute("""insert into product_masters
        (brand,name,ingredients_raw,verdict,rule_version,computed_at,source,source_checked_at,verified_status)
        values (%s,%s,%s,'okay','v1',now(),'t',now(),%s) returning id""", (BRAND, name, ing, status))
    mid = cur.fetchone()[0]
    for b in barcodes:
        cur.execute("insert into product_barcodes(barcode,master_id,size) values (%s,%s,'1')", (b, mid))
    cur.execute("set local session_replication_role = replica")
    cur.execute("update product_masters set updated_at = now() - interval '1 day' where id=%s", (mid,))
    cur.execute("set local session_replication_role = origin")
    return mid, {"master_key": master_key(BRAND, name, ing), "ingredients_hash": ingredients_hash(BRAND, ing)}


def _add(cur, mid, expected, barcodes):
    cur.execute("select public.add_barcode_to_master(%s, %s::jsonb, %s::jsonb)",
                (mid, json.dumps(expected), json.dumps(barcodes)))
    return cur.fetchone()[0]


def _snap(cur, mid):
    cur.execute(f"select {', '.join(_CONTENT_COLS)}, updated_at, updated_at < now() - interval '1 hour' "
                "from product_masters where id=%s", (mid,))
    row = cur.fetchone()
    return row[:-2], row[-1]  # (내용 컬럼, updated_at 이 아직 하루 전인지)


def _owner(cur, b):
    cur.execute("select master_id from product_barcodes where barcode=%s", (b,))
    r = cur.fetchone()
    return r[0] if r else None


def test_identity_formula():
    """기대 identity 가 운영 컬럼(0015 ingredients_hash·0019 master_key)과 같은 식인지."""
    with connect_test(source_dsn()) as conn, conn.cursor() as cur:
        cur.execute("begin")
        mid, exp = _seed(cur, name="이름 (400g)", ing="밀가루, 설탕|x")
        cur.execute("select master_key, ingredients_hash from product_masters where id=%s", (mid,))
        check("식: master_key·ingredients_hash 가 upload_prod 계산과 같음",
              cur.fetchone() == (exp["master_key"], exp["ingredients_hash"]))
        conn.rollback()


def test_link_unverified_and_verified():
    for status in ("unverified", "verified"):
        with connect_test(source_dsn()) as conn, conn.cursor() as cur:
            cur.execute("begin")
            mid, exp = _seed(cur, status=status)
            before, _ = _snap(cur, mid)
            r = _add(cur, mid, exp, [bc(B2)])
            check(f"연결({status}): existing", r["master_status"] == "existing", r["master_status"])
            check(f"연결({status}): master_id", str(r["master_id"]) == str(mid))
            check(f"연결({status}): B2 inserted", r["barcodes"] == [{"barcode": B2, "status": "inserted"}], str(r["barcodes"]))
            check(f"연결({status}): B2 소속", _owner(cur, B2) == mid)
            after, still_old = _snap(cur, mid)
            check(f"연결({status}): updated_at 갱신", still_old is False)
            check(f"연결({status}): 내용 컬럼 불변", before == after)
            cur.execute("select verified_status from product_masters where id=%s", (mid,))
            check(f"연결({status}): 상태 불변", cur.fetchone()[0] == status)
            conn.rollback()


def test_exists_no_bump():
    """이미 연결된 바코드만 다시 보내면 exists, updated_at 은 그대로."""
    with connect_test(source_dsn()) as conn, conn.cursor() as cur:
        cur.execute("begin")
        mid, exp = _seed(cur)
        r = _add(cur, mid, exp, [bc(B1)])
        check("exists: B1 exists", r["barcodes"] == [{"barcode": B1, "status": "exists"}], str(r["barcodes"]))
        check("exists: updated_at 그대로", _snap(cur, mid)[1] is True)
        conn.rollback()


def test_review_held():
    with connect_test(source_dsn()) as conn, conn.cursor() as cur:
        cur.execute("begin")
        mid, exp = _seed(cur, status="needs_review")
        before, _ = _snap(cur, mid)
        r = _add(cur, mid, exp, [bc(B1), bc(B2)])
        check("review_held: 상태", r["master_status"] == "review_held", r["master_status"])
        check("review_held: 이미 연결된 B1 만 exists", r["barcodes"] == [{"barcode": B1, "status": "exists"}], str(r["barcodes"]))
        check("review_held: B2 미연결", _owner(cur, B2) is None)
        after, still_old = _snap(cur, mid)
        check("review_held: master 불변(updated_at 포함)", before == after and still_old is True)
        conn.rollback()


def test_identity_mismatch():
    with connect_test(source_dsn()) as conn, conn.cursor() as cur:
        cur.execute("begin")
        mid, exp = _seed(cur)
        cur.execute("update product_masters set name='운영에서바뀐이름' where id=%s", (mid,))
        r = _add(cur, mid, exp, [bc(B1), bc(B2)])
        check("mismatch(이름): 상태", r["master_status"] == "identity_mismatch", r["master_status"])
        check("mismatch(이름): B1 만 exists", r["barcodes"] == [{"barcode": B1, "status": "exists"}], str(r["barcodes"]))
        check("mismatch(이름): B2 미연결", _owner(cur, B2) is None)
        conn.rollback()

    with connect_test(source_dsn()) as conn, conn.cursor() as cur:
        cur.execute("begin")
        mid, exp = _seed(cur)
        r = _add(cur, mid, dict(exp, ingredients_hash="0" * 32), [bc(B2)])
        check("mismatch(원재료 해시): 상태", r["master_status"] == "identity_mismatch", r["master_status"])
        check("mismatch(원재료 해시): 연결 없음", r["barcodes"] == [] and _owner(cur, B2) is None, str(r["barcodes"]))
        r = _add(cur, mid, {}, [bc(B2)])
        check("mismatch(기대값 없음): 상태", r["master_status"] == "identity_mismatch", r["master_status"])
        conn.rollback()


def test_conflict_and_mixed_retry():
    with connect_test(source_dsn()) as conn, conn.cursor() as cur:
        cur.execute("begin")
        mid, exp = _seed(cur, barcodes=(B1,))
        other, _ = _seed(cur, name="다른", ing="i-other", barcodes=(B3,))
        r = _add(cur, mid, exp, [bc(B1), bc(B2), bc(B3)])
        want = [{"barcode": B1, "status": "exists"}, {"barcode": B2, "status": "inserted"},
                {"barcode": B3, "status": "conflict"}]
        check("섞임: exists·inserted·conflict", r["barcodes"] == want, str(r["barcodes"]))
        check("섞임: B3 은 다른 master 그대로", _owner(cur, B3) == other)
        check("섞임: 다른 master updated_at 그대로", _snap(cur, other)[1] is True)
        r = _add(cur, mid, exp, [bc(B1), bc(B2)])
        check("재시도: 모두 exists", r["barcodes"] == [{"barcode": B1, "status": "exists"},
                                                     {"barcode": B2, "status": "exists"}], str(r["barcodes"]))
        conn.rollback()


def test_not_found():
    with connect_test(source_dsn()) as conn, conn.cursor() as cur:
        cur.execute("begin")
        r = _add(cur, "00000000-0000-0000-0000-000000000000", {"master_key": "x", "ingredients_hash": "y"}, [bc(B2)])
        check("not_found: 상태", r["master_status"] == "not_found", r["master_status"])
        check("not_found: 연결 없음", r["barcodes"] == [] and _owner(cur, B2) is None)
        conn.rollback()


def test_execute_revoked():
    for dsn_fn in (source_dsn, target_dsn):
        with connect_test(dsn_fn()) as c, c.cursor() as cur:
            db = c.execute("select current_database()").fetchone()[0]
            cur.execute("select public.add_barcode_to_master_version()")
            check(f"0024 버전({db}) = 24", cur.fetchone()[0] == 24)
            for fn in ("public.add_barcode_to_master(uuid, jsonb, jsonb)", "public.add_barcode_to_master_version()"):
                short = fn.split("(")[0].split(".")[1]
                for role, want in (("anon", False), ("authenticated", False), ("public", False), ("service_role", True)):
                    if role == "public":
                        cur.execute("select exists(select 1 from pg_proc p, aclexplode(p.proacl) a "
                                    "where p.oid=%s::regprocedure and a.grantee=0)", (fn,))
                    else:
                        cur.execute("select has_function_privilege(%s, %s, 'execute')", (role, fn))
                    got = cur.fetchone()[0]
                    check(f"0024 권한({db}) {short}: {role} execute={want}", got is want, str(got))
            for role in ("anon", "authenticated"):
                cur.execute("savepoint s")
                try:
                    cur.execute(f"set local role {role}")
                    cur.execute("select public.add_barcode_to_master(null, '{}'::jsonb, '[]'::jsonb)")
                    check(f"0024 실제 호출({db}) {role} 거부", False, "실행됨")
                except psycopg.errors.InsufficientPrivilege:
                    check(f"0024 실제 호출({db}) {role} 거부", True)
                cur.execute("rollback to savepoint s")
            cur.execute("select prosecdef, proconfig from pg_proc where oid='public.add_barcode_to_master(uuid, jsonb, jsonb)'::regprocedure")
            sd, cfg = cur.fetchone()
            check(f"0024 security definer·빈 search_path({db})", sd is True and cfg == ['search_path=""'], str(cfg))
            c.rollback()


def test_concurrent_with_0021_no_deadlock():
    """0021 과 동시에 서로의 master 바코드를 건드려도 교착이 없다(둘 다 id 순서 한 번 잠금).

    M1(B1)·M2(B2). A = add_barcode_to_master(M1, [B2]) — M1·M2 잠금, B = upload_promoted_product(M2 와 같은
    master_key, [B1]) — M1·M2 잠금. 제3 연결이 M1 을 쥔 채 두 순서(B 먼저/A 먼저)로 대기시킨 뒤 푼다."""
    for first in ("B", "A"):
        errs, res = {}, {}
        try:
            with connect_test(source_dsn()) as c, c.cursor() as cur:
                ids, exp = {}, {}
                for nm, ing, b in (("N1", "i-dl-1", B1), ("N2", "i-dl-2", B2)):
                    ids[nm], exp[nm] = _seed(cur, name=nm, ing=ing, barcodes=(b,))
            with connect_test(source_dsn()) as hold, connect_test(source_dsn()) as a, connect_test(source_dsn()) as b:
                h = hold.cursor()
                h.execute("select 1 from product_masters where id=%s for update", (min(ids.values()),))

                def run(conn, key, fn):
                    try:
                        with conn.cursor() as cx:
                            res[key] = fn(cx)
                        conn.commit()
                    except psycopg.errors.DeadlockDetected as e:
                        errs[key] = e
                        conn.rollback()
                fa = lambda cx: _add(cx, ids["N1"], exp["N1"], [bc(B2)])
                fb = lambda cx: _call(cx, dict(_master(brand=BRAND, ing="i-dl-2"), name="N2"), [bc(B1)])
                order = [(b, "B", fb), (a, "A", fa)] if first == "B" else [(a, "A", fa), (b, "B", fb)]
                ts = []
                for conn, key, fn in order:
                    t = threading.Thread(target=run, args=(conn, key, fn))
                    t.start(); ts.append(t)
                    check(f"동시({first} 먼저): {key} 잠금 대기", _wait_lock_wait(conn.info.backend_pid))
                hold.rollback()
                for t in ts:
                    t.join(timeout=30)
                check(f"동시({first} 먼저): 교착 없음", not errs, str({k: str(v)[:60] for k, v in errs.items()}))
                check(f"동시({first} 먼저): 둘 다 완료", set(res) == {"A", "B"}, str(sorted(res)))
                check(f"동시({first} 먼저): A 는 B2 conflict",
                      res.get("A", {}).get("barcodes") == [{"barcode": B2, "status": "conflict"}], str(res.get("A")))
                check(f"동시({first} 먼저): B 는 existing·B1 conflict",
                      res.get("B", {}).get("master_status") == "existing"
                      and res.get("B", {}).get("barcodes") == [{"barcode": B1, "status": "conflict"}], str(res.get("B")))
        finally:
            with connect_test(source_dsn()) as c, c.cursor() as cur:
                cur.execute("delete from product_barcodes where barcode = any(%s)", ([B1, B2, B3],))
                cur.execute("delete from product_masters where brand=%s", (BRAND,))


X1, X2 = _ean("990000002420"), _ean("990000002421")  # X1 < X2, 아직 어디에도 없는 신규 바코드


def test_concurrent_new_barcodes_sorted_no_deadlock():
    """서로 다른 master 에 아직 없는 같은 신규 바코드 둘을 0024·0021 이 동시에 넣어도 교착이 없다.

    0024 는 입력이 [X2,X1] 이어도 바코드 순서로 삽입하고, 0021 은 업로더처럼 정렬된 입력 [X1,X2] 를 받는다.
    제3 연결이 두 master 를 쥔 채 둘을 대기시킨 뒤 풀어 동시에 출발시킨다(여러 번 반복).
    참고: 0021 입력을 역순 [X2,X1] 으로 주면 두 트랜잭션이 X1·X2 UNIQUE 대기를 엇갈려 쥐어 교착할 수 있다 —
    그래서 업로더가 0021 호출에도 정렬해 보낸다(과제 3). 그 재현 테스트는 두지 않는다."""
    rounds = 10
    for i in range(rounds):
        res, errs = {}, {}
        try:
            with connect_test(source_dsn()) as c, c.cursor() as cur:
                ids, exp = {}, {}
                for nm, ing, b in (("N1", "i-nb-1", B1), ("N2", "i-nb-2", B2)):
                    ids[nm], exp[nm] = _seed(cur, name=nm, ing=ing, barcodes=(b,))
            with connect_test(source_dsn()) as hold, connect_test(source_dsn()) as a, connect_test(source_dsn()) as b:
                h = hold.cursor()
                h.execute("select 1 from product_masters where id = any(%s) order by id for update",
                          (list(ids.values()),))

                def run(conn, key, fn):
                    try:
                        with conn.cursor() as cx:
                            res[key] = fn(cx)
                        conn.commit()
                    except Exception as e:  # noqa — 교착뿐 아니라 모든 예외를 실패로 모은다
                        errs[key] = f"{type(e).__name__}: {str(e)[:60]}"
                        conn.rollback()
                fa = lambda cx: _add(cx, ids["N1"], exp["N1"], [bc(X2), bc(X1)])
                fb = lambda cx: _call(cx, dict(_master(brand=BRAND, ing="i-nb-2"), name="N2"), [bc(X1), bc(X2)])
                ts = [threading.Thread(target=run, args=(a, "A", fa)), threading.Thread(target=run, args=(b, "B", fb))]
                waited = []
                for t, conn in zip(ts, (a, b)):
                    t.start()
                    waited.append(_wait_lock_wait(conn.info.backend_pid))
                hold.rollback()
                for t in ts:
                    t.join(timeout=30)
                alive = [t.is_alive() for t in ts]
            p = f"신규 동시 {i + 1}/{rounds}"
            check(f"{p}: A·B 잠금 대기", waited == [True, True], str(waited))
            check(f"{p}: 두 스레드 종료", alive == [False, False], str(alive))
            check(f"{p}: 예외 없음", not errs, str(errs))
            check(f"{p}: A·B 결과 있음", set(res) == {"A", "B"}, str(sorted(res)))
            ra, rb = res.get("A", {}), res.get("B", {})
            check(f"{p}: 0024 결과는 입력 순서", [x["barcode"] for x in ra.get("barcodes", [])] == [X2, X1], str(ra))
            with connect_test(source_dsn()) as c, c.cursor() as cur:
                owners = {_owner(cur, X1), _owner(cur, X2)}
            check(f"{p}: X1·X2 는 한 master 소속", len(owners) == 1 and owners <= set(ids.values()), str(owners))
            win = "A" if owners == {ids["N1"]} else "B"
            st = lambda r: sorted(x["status"] for x in r.get("barcodes", []))
            check(f"{p}: 이긴 쪽 inserted 둘·진 쪽 conflict 둘",
                  st(res.get(win, {})) == ["inserted", "inserted"]
                  and st(res.get("B" if win == "A" else "A", {})) == ["conflict", "conflict"], str(res))
        finally:
            with connect_test(source_dsn()) as c, c.cursor() as cur:
                cur.execute("delete from product_barcodes where barcode = any(%s)", ([B1, B2, X1, X2],))
                cur.execute("delete from product_masters where brand=%s", (BRAND,))


def test_duplicate_input():
    """입력에 같은 바코드가 두 번 와도 처음 결과(inserted)를 유지한다(업로더 receipt_rows 의 첫 결과 규칙과 같음)."""
    with connect_test(source_dsn()) as conn, conn.cursor() as cur:
        cur.execute("begin")
        mid, exp = _seed(cur, barcodes=(B1,))
        r = _add(cur, mid, exp, [bc(X1), bc(X1)])
        want = [{"barcode": X1, "status": "inserted"}, {"barcode": X1, "status": "inserted"}]
        check("중복 입력: 둘 다 inserted", r["barcodes"] == want, str(r["barcodes"]))
        check("중복 입력: updated_at 갱신", _snap(cur, mid)[1] is False)
        cur.execute("select count(*) from product_barcodes where barcode=%s", (X1,))
        check("중복 입력: 바코드 행 1개", cur.fetchone()[0] == 1)
        conn.rollback()


def test_result_input_order():
    with connect_test(source_dsn()) as conn, conn.cursor() as cur:
        cur.execute("begin")
        mid, exp = _seed(cur, barcodes=(B1,))
        r = _add(cur, mid, exp, [bc(X2), bc(B1), bc(X1)])
        want = [{"barcode": X2, "status": "inserted"}, {"barcode": B1, "status": "exists"},
                {"barcode": X1, "status": "inserted"}]
        check("결과 순서: 입력 순서 유지", r["barcodes"] == want, str(r["barcodes"]))
        conn.rollback()


def main():
    for t in [test_identity_formula, test_link_unverified_and_verified, test_exists_no_bump,
              test_review_held, test_identity_mismatch, test_conflict_and_mixed_retry, test_not_found,
              test_execute_revoked, test_concurrent_with_0021_no_deadlock,
              test_concurrent_new_barcodes_sorted_no_deadlock, test_result_input_order,
              test_duplicate_input]:
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
