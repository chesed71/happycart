"""upload_prod.py 형제 바코드 분기(add_barcode_to_master, 0024) 테스트.

이미 운영 master 가 있는 LOCAL master 에 새 승격 행(형제 바코드)이 생기면 미연결 바코드만 0024 로 붙이는지,
영수증 규칙, prod_master_id 갈라짐, 버전 사전 검사(REST·postgres), dry-run 분류, 복구(운영 커밋 뒤 LOCAL 기록
전 멈춤)를 검증한다. 전용 테스트 DB happycart_test(원본)·happycart_test_target(운영 대상)에만 연결한다.

사용: pipeline/.venv/bin/python test_upload_add.py
"""
from __future__ import annotations

import io
import json
import os
import sys
import tempfile
import urllib.error

import upload_prod
from test_upload import (U1, U2, U3, UP_BRAND, _cleanup_upload, _FakeUploader, _HookTarget, _judged_row,
                         _NoUploader, _row_state, _run, _seed_upload, _target_owner)
from testdb import connect_test, source_dsn, target_dsn
from upload_prod import add_receipt_rows

results = []


def check(name, cond, detail=""):
    results.append((name, cond, detail))


P = "44444444-4444-4444-4444-444444444444"


def _e(b):
    return {"collected_id": "c-" + b, "barcode": b, "promoted_at": None}


def test_add_receipt_rows():
    E = [_e("A"), _e("B"), _e("C")]
    r = add_receipt_rows("L", E, {"master_id": P, "master_status": "existing", "barcodes": [
        {"barcode": "A", "status": "inserted"}, {"barcode": "B", "status": "exists"},
        {"barcode": "C", "status": "conflict"}]})
    check("영수증: inserted→existing·연결", (r[0]["result"], r[0]["prod_master_id"]) == ("existing", P), str(r[0]))
    check("영수증: exists 그대로·연결", (r[1]["result"], r[1]["prod_master_id"]) == ("exists", P), str(r[1]))
    check("영수증: conflict·미연결", (r[2]["result"], r[2]["prod_master_id"]) == ("conflict", None), str(r[2]))
    r = add_receipt_rows("L", E[:2], {"master_id": P, "master_status": "existing",
                                      "barcodes": [{"barcode": "A", "status": "inserted"}]})
    check("영수증: existing 인데 누락 → error·missing_barcode_result",
          (r[1]["result"], r[1]["error"], r[1]["prod_master_id"]) == ("error", "missing_barcode_result", None), str(r[1]))
    for st, want, err in (("review_held", "review_held", None), ("identity_mismatch", "error", "identity_mismatch"),
                          ("not_found", "error", "not_found")):
        r = add_receipt_rows("L", E[:2], {"master_id": P, "master_status": st,
                                          "barcodes": [{"barcode": "A", "status": "exists"}]})
        check(f"영수증({st}): 보류여도 exists 는 연결", (r[0]["result"], r[0]["prod_master_id"]) == ("exists", P), str(r[0]))
        check(f"영수증({st}): 누락은 {want}·{err}·미연결",
              (r[1]["result"], r[1]["error"], r[1]["prod_master_id"]) == (want, err, None), str(r[1]))
    r = add_receipt_rows("L", [_e("A")], {"master_id": P, "master_status": "existing", "barcodes": [
        {"barcode": "A", "status": "inserted"}, {"barcode": "A", "status": "exists"}]})
    check("영수증: 같은 바코드 중복이면 첫 결과", r[0]["result"] == "existing", str(r[0]))
    allowed = {"inserted", "existing", "exists", "conflict", "verified_held", "review_held", "renamed_held",
               "empty_held", "error"}
    check("영수증: result 는 upload_receipts CHECK 안", all(x["result"] in allowed for x in r))


def _add_child(rows, base_bc, new_bc, name):
    """기존 승격 행(base_bc)의 LOCAL master 에 형제 바코드 승격 행을 만든다(과제 2 붙이기 결과 흉내)."""
    with connect_test(source_dsn()) as c, c.cursor() as cur:
        cur.execute("select promoted_master_id, ingredients_raw from collected_products where id=%s", (rows[base_bc],))
        lm, ing = cur.fetchone()
        rid = _judged_row(cur, new_bc, name, ing)
        cur.execute("""update collected_products set stage='promoted', promoted_master_id=%s, promoted_at=now()
                       where id=%s""", (lm, rid))
        cur.execute("insert into product_barcodes(barcode, master_id, size) values (%s,%s,'20g')", (new_bc, lm))
    return rid, lm


class _RecTarget(_HookTarget):
    """실제 대상 DB 로 부르되 두 RPC 의 호출과 보낸 바코드 순서를 기록한다. stop_after_add 면 0024 커밋 뒤 중단."""

    def __init__(self, stop_after_add=False):
        super().__init__()
        self.adds, self.ups, self.stop = [], [], stop_after_add

    def upload(self, master, barcodes):
        self.ups.append([b["barcode"] for b in barcodes])
        return super().upload(master, barcodes)

    def add_barcodes(self, master_id, expected, barcodes):
        self.adds.append((str(master_id), expected, [b["barcode"] for b in barcodes]))
        res = upload_prod.PgTarget.add_barcodes(self, master_id, expected, barcodes)
        if self.stop:
            raise _Stop()
        return res


class _Stop(BaseException):
    pass


def test_real_add_flow():
    """첫 업로드로 연결된 master 에 형제 바코드 2개 → 기본 실행이 0024 를 한 번, 정렬된 미연결 바코드로 부른다."""
    _cleanup_upload()
    t = None
    try:
        rows = _seed_upload([("업티S", [U1])])
        t = _RecTarget()
        _run(t)
        pm, _, _ = _row_state(rows[U1])
        check("add: 첫 업로드 연결", pm is not None, str(pm))
        r3, _ = _add_child(rows, U1, U3, "업티S")
        r2, _ = _add_child(rows, U1, U2, "업티S")
        t.ups.clear()
        stats = _run(t)
        check("add: 0021 호출 없음", t.ups == [], str(t.ups))
        check("add: 0024 한 번, 운영 master·정렬된 미연결 바코드만",
              len(t.adds) == 1 and t.adds[0][0] == str(pm) and t.adds[0][2] == sorted([U2, U3]), str(t.adds))
        with connect_test(target_dsn()) as c, c.cursor() as cur:
            cur.execute("select master_key, ingredients_hash from product_masters where id=%s", (pm,))
            mk, ih = cur.fetchone()
        check("add: 기대 identity = 운영 master_key·ingredients_hash",
              t.adds and t.adds[0][1] == {"master_key": mk, "ingredients_hash": ih}, str(t.adds and t.adds[0][1]))
        for bc, rid in ((U2, r2), (U3, r3)):
            p, allr, cur_r = _row_state(rid)
            check(f"add {bc[-2:]}: 운영 소속", str(_target_owner(bc)) == str(pm))
            check(f"add {bc[-2:]}: prod_master_id·existing 영수증", str(p) == str(pm) and cur_r == "existing",
                  f"{p} {allr}")
        check("add: 통계 add_existing 1", stats.get("add_existing") == 1, str(dict(stats)))
        t.adds.clear()
        _run(t)
        check("add: 다시 실행하면 대상 없음(호출 0)", t.adds == [] and t.ups == [], f"{t.adds} {t.ups}")
        # --all: 다 연결된 master 는 0024 를 부르지 않는다
        _run(t, all_=True)
        check("add: --all 도 미연결 없으면 호출 0", t.adds == [] and t.ups == [], f"{t.adds} {t.ups}")
    finally:
        if t:
            t.conn.close()
        _cleanup_upload()


def test_new_master_payload_sorted():
    """기존 경로(0021)도 바코드를 정렬해 보낸다(회귀: 결과·연결은 그대로)."""
    _cleanup_upload()
    t = None
    try:
        rows = _seed_upload([("업티O", [U3, U1, U2])])
        t = _RecTarget()
        _run(t, ids=list(rows.values()))
        check("0021: 한 번·정렬된 바코드", t.ups == [sorted([U1, U2, U3])] and t.adds == [], f"{t.ups} {t.adds}")
        for bc, rid in rows.items():
            p, _, cur_r = _row_state(rid)
            check(f"0021 {bc[-2:]}: inserted·연결", p is not None and cur_r == "inserted", f"{p} {cur_r}")
    finally:
        if t:
            t.conn.close()
        _cleanup_upload()


def test_split_prod_ids_not_called():
    _cleanup_upload()
    t = None
    try:
        rows = _seed_upload([("업티X", [U1])])
        r2, _ = _add_child(rows, U1, U2, "업티X")
        r3, _ = _add_child(rows, U1, U3, "업티X")
        with connect_test(source_dsn()) as c, c.cursor() as cur:
            cur.execute("update collected_products set prod_master_id=%s where id=%s", (P, rows[U1]))
            cur.execute("update collected_products set prod_master_id=%s where id=%s",
                        ("55555555-5555-5555-5555-555555555555", r2))
        t = _RecTarget()
        stats = _run(t)
        check("split: RPC 호출 없음", t.adds == [] and t.ups == [], f"{t.adds} {t.ups}")
        p, allr, cur_r = _row_state(r3)
        check("split: 미연결 행 error 영수증·사유", p is None and cur_r == "error"
              and allr and allr[-1][2].startswith("multiple_prod_master_ids"), str(allr))
        check("split: 연결된 행엔 영수증 없음", _row_state(rows[U1])[1] == [] and _row_state(r2)[1] == [])
        check("split: 통계", stats.get("master_split_error") == 1, str(dict(stats)))
    finally:
        if t:
            t.conn.close()
        _cleanup_upload()


def test_dryrun_add():
    _cleanup_upload()
    t = None
    try:
        rows = _seed_upload([("업티D", [U1])])
        t = _RecTarget()
        _run(t)
        pm, _, _ = _row_state(rows[U1])
        r2, _ = _add_child(rows, U1, U2, "업티D")
        stats = _run(t, dry_run=True)
        check("dry-run add: 기존 master 에 바코드 추가로 분류", stats.get("add_existing") == 1
              and stats.get("barcode_inserted") == 1, str(dict(stats)))
        check("dry-run add: 쓰기 없음", t.adds == [] and _target_owner(U2) is None and _row_state(r2)[1] == [])
        with t.conn.cursor() as cur:
            cur.execute("update product_masters set name='바뀜' where id=%s", (pm,))
        t.conn.commit()
        stats = _run(t, dry_run=True)
        check("dry-run add: 이름 바뀌면 identity_mismatch", stats.get("add_identity_mismatch") == 1, str(dict(stats)))
    finally:
        if t:
            t.conn.close()
        _cleanup_upload()


def test_recovery_after_remote_commit():
    """0024 가 운영에 커밋된 뒤 LOCAL 기록 전에 멈춤 → 운영 master 를 needs_review / 이름 변경 → 재실행하면
    exists 영수증과 prod_master_id 가 채워진다."""
    for label, sql in (("needs_review", "update product_masters set verified_status='needs_review' where id=%s"),
                       ("이름변경", "update product_masters set name='운영에서바뀐이름' where id=%s")):
        _cleanup_upload()
        t = None
        try:
            rows = _seed_upload([("업티R", [U1])])
            t = _RecTarget()
            _run(t)
            pm, _, _ = _row_state(rows[U1])
            r2, _ = _add_child(rows, U1, U2, "업티R")
            t.stop = True
            stopped = False
            try:
                _run(t)
            except _Stop:
                stopped = True
            check(f"복구({label}): 0024 커밋 뒤 중단", stopped and str(_target_owner(U2)) == str(pm))
            check(f"복구({label}): 중단 직후 LOCAL 기록 없음", _row_state(r2)[0] is None and _row_state(r2)[1] == [])
            with t.conn.cursor() as cur:
                cur.execute(sql, (pm,))
            t.conn.commit()
            t.stop = False
            stats = _run(t)
            p, allr, cur_r = _row_state(r2)
            check(f"복구({label}): prod_master_id 채워짐", str(p) == str(pm), f"{p} {pm}")
            check(f"복구({label}): 현재 영수증 exists", cur_r == "exists", str(allr))
            want = "add_review_held" if label == "needs_review" else "add_identity_mismatch"
            check(f"복구({label}): master 결과 {want}", stats.get(want) == 1, str(dict(stats)))
        finally:
            if t:
                t.conn.close()
            _cleanup_upload()


def _expect_stop(label, target, up, rows):
    msg = None
    try:
        with connect_test(source_dsn()) as src:
            upload_prod.run_upload(src, target, manifest=up[1], uploader=up[0])
    except SystemExit as ex:
        msg = str(ex)
    check(f"{label}: SystemExit(0024)", msg is not None and "0024" in msg, str(msg))
    check(f"{label}: 이미지 업로드 0회", up[0].calls == [], str(len(up[0].calls)))
    check(f"{label}: 영수증 0건", sum(len(_row_state(r)[1]) for r in rows) == 0)


def test_version_check_pg():
    """postgres: add_barcode_to_master_version 이 없거나 24 가 아니면 이미지·RPC 전에 멈춘다."""
    with open(os.path.join(os.path.dirname(__file__), "..", "supabase", "migrations",
                           "0024_add_barcode_to_master.sql")) as f:
        mig = f.read()
    data = b"\xff\xd8ver"
    for label, sql in (("없음", "drop function public.add_barcode_to_master_version()"),
                       ("23", "create or replace function public.add_barcode_to_master_version() returns integer "
                              "language sql immutable set search_path = '' as $$ select 23 $$")):
        _cleanup_upload()
        t = None
        try:
            rows = _seed_upload([("업티V", [U1])])
            t = _RecTarget()
            with t.conn.cursor() as cur:
                cur.execute(sql)
            t.conn.commit()
            check(f"pg 버전({label}): 값", t.add_barcode_version() == (None if label == "없음" else 23))
            with tempfile.TemporaryDirectory() as d:
                fp = os.path.join(d, "u1.jpg")
                with open(fp, "wb") as fh:
                    fh.write(data)
                up = _FakeUploader()
                _expect_stop(f"pg 버전({label})", t, (up, {U1: {"barcode": U1, "local_path": fp}}), rows.values())
            check(f"pg 버전({label}): RPC 0회", t.ups == [] and t.adds == [] and _target_owner(U1) is None)
        finally:
            if t:
                with t.conn.cursor() as cur:
                    cur.execute(mig)
                t.conn.commit()
                check(f"pg 버전({label}): 0024 복원", t.add_barcode_version() == 24)
                t.conn.close()
            _cleanup_upload()


def test_version_check_rest():
    """REST: 버전 21 은 맞고 add_barcode_to_master_version 이 404/23 이면 그 뒤 요청 없이 멈춘다. 24 면 경로 확인."""
    orig = upload_prod.urllib.request.urlopen
    env = {k: os.environ.get(k) for k in ("SUPABASE_URL", "SUPABASE_SERVICE_ROLE_KEY")}
    for label, add_resp in (("404", (404, '{"code":"PGRST202"}')), ("23", (200, "23")), ("24", (200, "24"))):
        _cleanup_upload()
        seen = []

        def fake(req, *a, **k):
            seen.append(req.full_url)
            if req.full_url.endswith("/rpc/upload_promoted_product_version"):
                return io.BytesIO(b"21")
            if req.full_url.endswith("/rpc/add_barcode_to_master_version"):
                st, body = add_resp
                if st == 200:
                    return io.BytesIO(body.encode())
                raise urllib.error.HTTPError(req.full_url, st, "x", {}, io.BytesIO(body.encode()))
            raise AssertionError("버전 확인 뒤 요청: " + req.full_url)
        try:
            os.environ["SUPABASE_URL"], os.environ["SUPABASE_SERVICE_ROLE_KEY"] = "https://sb.test", "k"
            rest = upload_prod.RestTarget()
            upload_prod.urllib.request.urlopen = fake
            if label == "24":
                check("rest 버전 24", rest.add_barcode_version() == 24)
                check("rest 버전 경로", seen[-1] == "https://sb.test/rest/v1/rpc/add_barcode_to_master_version", seen[-1])
                continue
            rows = _seed_upload([("업티W", [U1])])
            up = _FakeUploader()
            _expect_stop(f"rest 버전({label})", rest, (up, {}), rows.values())
            check(f"rest 버전({label}): 버전 확인 두 번 뒤 요청 없음",
                  [u.rsplit("/", 1)[1] for u in seen] == ["upload_promoted_product_version",
                                                          "add_barcode_to_master_version"], str(seen))
        finally:
            upload_prod.urllib.request.urlopen = orig
            for k, v in env.items():
                if v is None:
                    os.environ.pop(k, None)
                else:
                    os.environ[k] = v
            _cleanup_upload()


def test_rest_add_request():
    """RestTarget.add_barcodes 요청 경로·본문."""
    orig = upload_prod.urllib.request.urlopen
    env = {k: os.environ.get(k) for k in ("SUPABASE_URL", "SUPABASE_SERVICE_ROLE_KEY")}
    seen = []

    def fake(req, *a, **k):
        seen.append((req.full_url, json.loads(k.get("data") or a[0])))
        return io.BytesIO(b'{"master_id": null, "master_status": "not_found", "barcodes": []}')
    try:
        os.environ["SUPABASE_URL"], os.environ["SUPABASE_SERVICE_ROLE_KEY"] = "https://sb.test", "k"
        upload_prod.urllib.request.urlopen = fake
        upload_prod.RestTarget().add_barcodes(P, {"master_key": "k", "ingredients_hash": "h"}, [{"barcode": "1"}])
        check("rest add 요청", seen == [("https://sb.test/rest/v1/rpc/add_barcode_to_master",
                                        {"p_master_id": P, "p_expected": {"master_key": "k", "ingredients_hash": "h"},
                                         "p_barcodes": [{"barcode": "1"}]})], str(seen))
    finally:
        upload_prod.urllib.request.urlopen = orig
        for k, v in env.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v


def test_link_missing_not_called():
    """링크 누락 승격 행이 Q 를 가진 채 다른 행이 P 면(P+Q 갈라짐) — 집계가 조인 없이 모아 호출 0,
    미연결 행은 local_barcode_link_missing error 영수증."""
    _cleanup_upload()
    t = None
    try:
        rows = _seed_upload([("업티M", [U1])])
        t = _RecTarget()
        _run(t)
        pm, _, _ = _row_state(rows[U1])
        r2, lm = _add_child(rows, U1, U2, "업티M")
        r3, _ = _add_child(rows, U1, U3, "업티M")
        with connect_test(source_dsn()) as c, c.cursor() as cur:
            cur.execute("delete from product_barcodes where barcode=%s and master_id=%s", (U3, lm))
            cur.execute("update collected_products set prod_master_id=%s where id=%s", (P, r3))
        t.adds.clear(); t.ups.clear()
        stats = _run(t)
        check("링크누락: RPC 호출 0", t.adds == [] and t.ups == [], f"{t.adds} {t.ups}")
        p2, allr, cur_r = _row_state(r2)
        check("링크누락: 미연결 행 error·local_barcode_link_missing",
              p2 is None and cur_r == "error" and allr[-1][2] == "local_barcode_link_missing", str(allr))
        check("링크누락: 운영 연결 없음", _target_owner(U2) is None)
        check("링크누락: 통계", stats.get("master_link_missing_error") == 1, str(dict(stats)))
        check("링크누락: 연결된 행엔 영수증 추가 없음",
              [r[0] for r in _row_state(rows[U1])[1]] == ["inserted"] and _row_state(r3)[1] == [])
    finally:
        if t:
            t.conn.close()
        _cleanup_upload()


class _LateFail(_RecTarget):
    """(이중 방어 시험) RPC 를 부르기 전에 다른 실행 A 를 끝까지 돌려 성공 기록을 남기게 한 뒤, 이 실행(B)은 실패한다."""

    def _a_then_fail(self):
        a = _RecTarget()
        try:
            # 업로더 잠금이 막는 상황이라, 이중 방어(행 재확인)만 시험하려고 A 는 잠금 없이 내부 함수로 돌린다.
            with connect_test(source_dsn()) as src:
                upload_prod._run_upload(src, a, manifest={}, uploader=_NoUploader())
        finally:
            a.conn.close()
        raise RuntimeError("늦은 실패")

    def upload(self, master, barcodes):
        self.ups.append([b["barcode"] for b in barcodes])
        self._a_then_fail()

    def add_barcodes(self, master_id, expected, barcodes):
        self.adds.append(str(master_id))
        self._a_then_fail()


def test_late_failure_keeps_success():
    """A 가 성공 기록을 커밋한 뒤 B 의 늦은 실패 → B 는 그 행에 error 를 쓰지 않고 최신 영수증은 성공 유지."""
    for label in ("0021", "0024"):
        _cleanup_upload()
        b = None
        try:
            rows = _seed_upload([("업티L", [U1])])
            rid, want = rows[U1], "inserted"
            if label == "0024":
                t = _RecTarget()
                _run(t)
                t.conn.close()
                rid, _ = _add_child(rows, U1, U2, "업티L")
                want = "existing"
            b = _LateFail()
            stats = _run(b)
            p, allr, cur_r = _row_state(rid)
            check(f"늦은 실패({label}): B 가 RPC 단계까지 감", (b.ups if label == "0021" else b.adds) != [])
            check(f"늦은 실패({label}): master_error 집계", stats.get("master_error") == 1, str(dict(stats)))
            check(f"늦은 실패({label}): error 영수증 없음", all(r[0] != "error" for r in allr), str(allr))
            check(f"늦은 실패({label}): 최신 영수증 성공·연결 유지", cur_r == want and p is not None, f"{p} {cur_r}")
        finally:
            if b:
                b.conn.close()
            _cleanup_upload()


def test_single_uploader_lock():
    """다른 업로더가 LOCAL advisory lock 'upload_prod' 를 쥐고 있으면 두 번째 실행은 쓰기 0으로 SystemExit.
    정상 실행이 끝나면 잠금이 풀려 있다."""
    from test_upload import _FakeTarget
    _cleanup_upload()
    try:
        rows = _seed_upload([("업티K", [U1])])
        with connect_test(source_dsn(), autocommit=True) as hold:
            hold.execute("select pg_advisory_lock(hashtextextended('upload_prod', 0))")
            t = _FakeTarget("inserted")
            up = _FakeUploader()
            msg = None
            try:
                with connect_test(source_dsn()) as src:
                    upload_prod.run_upload(src, t, manifest={}, uploader=up)
            except SystemExit as ex:
                msg = str(ex)
            check("잠금: 두 번째 실행 SystemExit", msg is not None and "upload_prod" in msg, str(msg))
            check("잠금: RPC·이미지 0회", t.calls == [] and up.calls == [], f"{t.calls} {len(up.calls)}")
            p, allr, _ = _row_state(rows[U1])
            check("잠금: 영수증·연결 0", p is None and allr == [], f"{p} {allr}")
            rt = _RecTarget()
            try:
                with connect_test(source_dsn()) as src:
                    st = upload_prod.run_upload(src, rt, manifest={}, uploader=up, dry_run=True)
            finally:
                rt.conn.close()
            check("잠금: dry-run 은 잠금과 무관하게 동작", st.get("master_inserted") == 1, str(dict(st)))
            hold.execute("select pg_advisory_unlock(hashtextextended('upload_prod', 0))")
        t = _FakeTarget("inserted")
        _run(t)
        check("잠금 해제 뒤: 정상 실행", t.calls == ["업티K"], str(t.calls))
        with connect_test(source_dsn()) as c, c.cursor() as cur:
            cur.execute("""select count(*) from pg_locks where locktype='advisory'
                           and objid = (hashtextextended('upload_prod', 0) & 4294967295)::oid""")
            check("잠금: 실행 끝나면 풀림", cur.fetchone()[0] == 0)
    finally:
        _cleanup_upload()


class _HookConn:
    """원본 연결을 감싸 master 조회 직후 hook 을 한 번 부른다(두 조회 사이에 다른 커밋을 끼워 넣기)."""

    def __init__(self, conn, hook):
        self._c, self._hook, self.sqls = conn, hook, []

    def __getattr__(self, k):
        return getattr(self._c, k)

    def cursor(self, *a, **k):
        cur, outer = self._c.cursor(*a, **k), self

        class _Cur:
            def __enter__(self):
                return self

            def __exit__(self, *x):
                cur.close()

            def __getattr__(self, k):
                return getattr(cur, k)

            def execute(self, sql, *a, **k):
                r = cur.execute(sql, *a, **k)
                outer.sqls.append(sql)
                if outer._hook and "select distinct m.id" in sql:
                    h, outer._hook = outer._hook, None
                    h()
                return r
        return _Cur()


def test_link_check_single_query():
    """master 조회와 행 조회 사이에 형제 행+LOCAL 바코드 링크가 함께 커밋돼도, 행·링크를 한 LEFT JOIN 으로 읽으므로
    링크 누락으로 오판하지 않는다(두 조회를 비교하면 새 행이 '링크 없음'으로 보일 수 있던 경우)."""
    _cleanup_upload()
    try:
        rows = _seed_upload([("업티J", [U1])])
        made = {}
        with connect_test(source_dsn()) as src:
            hc = _HookConn(src, lambda: made.update(rid=_add_child(rows, U1, U2, "업티J")[0]))
            masters, bcs, _, all_rows = upload_prod.fetch_promoted(hc, with_rows=True)
        (lm, rws), = all_rows.items()
        row_q = [q for q in hc.sqls if "from collected_products c" in q and "product_barcodes b" in q]
        check("단일조회: 행·링크는 LEFT JOIN 조회 하나", len(row_q) == 1 and "left join product_barcodes" in row_q[0],
              str(len(row_q)))
        check("단일조회: 사이에 끼운 형제 행이 보임", made.get("rid") in {r["collected_id"] for r in rws}, str(rws))
        check("단일조회: 링크 누락 0", all(r["linked"] for r in rws), str(rws))
        check("단일조회: entries 와 linked 행이 같음",
              {e["collected_id"] for e in bcs[lm]} == {r["collected_id"] for r in rws if r["linked"]})
        with connect_test(source_dsn()) as c, c.cursor() as cur:
            cur.execute("delete from product_barcodes where barcode=%s and master_id=%s", (U2, lm))
            c.commit()
            m2, b2, _, r2 = upload_prod.fetch_promoted(c, with_rows=True)
        miss = [r for r in r2[lm] if not r["linked"]]
        check("단일조회: 실제 링크 누락은 linked=false·entries 제외",
              [r["collected_id"] for r in miss] == [made.get("rid")]
              and made.get("rid") not in {e["collected_id"] for e in b2[lm]}, str(miss))
    finally:
        _cleanup_upload()


def main():
    for t in [test_add_receipt_rows, test_real_add_flow, test_new_master_payload_sorted,
              test_split_prod_ids_not_called, test_dryrun_add, test_recovery_after_remote_commit,
              test_version_check_pg, test_version_check_rest, test_rest_add_request,
              test_link_missing_not_called, test_late_failure_keeps_success,
              test_single_uploader_lock, test_link_check_single_query]:
        try:
            t()
        except Exception as e:  # noqa
            check(t.__name__, False, f"예외: {e!r}")
    failed = sum(1 for _, ok, _ in results if not ok)
    for name, ok, detail in results:
        print(f"  {'PASS' if ok else 'FAIL'}  {name}" + (f"  [{detail}]" if detail and not ok else ""))
    print(f"\n{len(results) - failed}/{len(results)} pass")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
