"""upload_promoted_product RPC + dry-run 분류 테스트 (rollback-wrapped).

운영 업로드의 핵심 불변식을 검증한다: verified 가드, barcode 충돌, 멱등, dry-run 분류.
RPC 테스트는 로컬 happycart(운영과 동일 스키마)에서 트랜잭션 후 rollback 한다.

사용: pipeline/.venv/bin/python test_upload.py
참고: PR #6 리뷰 대응 (HIGH 1·2, MEDIUM 1·4)
"""
from __future__ import annotations

import json
import sys

import psycopg

from common import dsn
from upload_prod import classify_dryrun

results = []


def check(name, cond, detail=""):
    results.append((name, cond, detail))


def _ean(p):
    t = sum(int(c) * (3 if (12 - (i + 1)) % 2 == 0 else 1) for i, c in enumerate(p))
    return p + str((10 - t % 10) % 10)


B1, B2 = _ean("990000000010"), _ean("990000000011")


def _master(brand="UPLOADTEST", ing="물, 소금", verdict="okay", bad=None):
    return {
        "brand": brand, "name": "N", "category": "c", "ingredients_raw": ing,
        "ingredients_tokens": ["물", "소금"], "bad_ingredients_detected": bad or [],
        "good_ingredients_detected": [], "verdict_reason_codes": [],
        "verdict": verdict, "rule_version": "v1.1.0",
        "computed_at": "2026-06-17T00:00:00Z", "source": "테스트",
        "source_url": None, "source_checked_at": "2026-06-17T00:00:00Z",
        "verified_status": "unverified",
    }


def _call(cur, master, barcodes):
    cur.execute("select public.upload_promoted_product(%s::jsonb, %s::jsonb)",
                (json.dumps(master), json.dumps(barcodes)))
    return cur.fetchone()[0]


def test_rpc_insert_and_idempotent():
    with psycopg.connect(dsn()) as conn, conn.cursor() as cur:
        cur.execute("begin")
        m = _master(brand="UPLOADTEST_INS")
        bcs = [{"barcode": B1, "size": "10g", "image_url": None, "image_source_url": None}]
        r1 = _call(cur, m, bcs)
        check("RPC 신규 master inserted", r1["master_status"] == "inserted", r1["master_status"])
        check("RPC 신규 barcode inserted", r1["barcodes"][0]["status"] == "inserted")
        # 멱등: 같은 걸 다시 → updated + barcode exists
        r2 = _call(cur, m, bcs)
        check("RPC 재실행 master updated", r2["master_status"] == "updated", r2["master_status"])
        check("RPC 재실행 barcode exists", r2["barcodes"][0]["status"] == "exists")
        check("RPC 멱등: id 동일", r1["master_id"] == r2["master_id"])
        cur.execute("select count(*) from product_barcodes where barcode=%s", (B1,))
        check("RPC 멱등: barcode 중복 없음", cur.fetchone()[0] == 1)
        conn.rollback()


def test_rpc_verified_held():
    with psycopg.connect(dsn()) as conn, conn.cursor() as cur:
        cur.execute("begin")
        # 같은 hash의 verified master를 먼저 둔다
        m = _master(brand="UPLOADTEST_VER")
        cur.execute("""insert into product_masters
            (brand,name,ingredients_raw,verdict,rule_version,computed_at,source,source_checked_at,verified_status)
            values (%s,'N',%s,'okay','v1',now(),'t',now(),'verified')""",
            (m["brand"], m["ingredients_raw"]))
        r = _call(cur, m, [{"barcode": B1, "size": "1", "image_url": None, "image_source_url": None}])
        check("RPC verified master held", r["master_status"] == "verified_held", r["master_status"])
        check("RPC verified: barcode 연결 안 함", r["barcodes"] == [])
        cur.execute("select exists(select 1 from product_barcodes where barcode=%s)", (B1,))
        check("RPC verified: barcode 미생성", cur.fetchone()[0] is False)
        conn.rollback()


def test_rpc_barcode_conflict():
    with psycopg.connect(dsn()) as conn, conn.cursor() as cur:
        cur.execute("begin")
        # master A + barcode B1
        a = _master(brand="UPLOADTEST_A", ing="i-a")
        _call(cur, a, [{"barcode": B1, "size": "1", "image_url": None, "image_source_url": None}])
        # master B가 같은 barcode B1을 요청 → conflict (재연결 안 함)
        b = _master(brand="UPLOADTEST_B", ing="i-b")
        r = _call(cur, b, [{"barcode": B1, "size": "1", "image_url": None, "image_source_url": None}])
        check("RPC barcode conflict 분류", r["barcodes"][0]["status"] == "conflict", r["barcodes"])
        cur.execute("select master_id from product_barcodes where barcode=%s", (B1,))
        owner = cur.fetchone()[0]
        check("RPC conflict: 원소속 유지", str(owner) != str(r["master_id"]))
        conn.rollback()


class _StubTarget:
    """dry-run 분류 단위 테스트용 — DB 없이 plan/owner를 흉내낸다."""
    def __init__(self, existing_id, verified, owners):
        self._e, self._v, self._owners = existing_id, verified, owners
    def plan_master(self, vals):
        return self._e, self._v
    def barcode_owner(self, barcode):
        return self._owners.get(barcode)


def test_dryrun_classify():
    vals = _master()
    bcs = [{"barcode": B1, "size": "1", "image_url": None, "image_source_url": None},
           {"barcode": B2, "size": "1", "image_url": None, "image_source_url": None}]
    # 신규 master + B1 미존재, B2는 다른 master 소속 → inserted / inserted+conflict
    r = classify_dryrun(_StubTarget(None, False, {B2: "other-master"}), vals, bcs)
    check("dry-run 신규 master=inserted", r["master_status"] == "inserted")
    bcmap = {b["barcode"]: b["status"] for b in r["barcodes"]}
    check("dry-run 신규 barcode=inserted", bcmap[B1] == "inserted")
    check("dry-run 타소속 barcode=conflict", bcmap[B2] == "conflict")
    # 기존 verified master → held, barcode held
    r2 = classify_dryrun(_StubTarget("mid", True, {B1: "mid"}), vals, bcs)
    check("dry-run verified=held", r2["master_status"] == "verified_held")
    check("dry-run verified barcode=held", all(b["status"] == "held" for b in r2["barcodes"]))
    # 기존 unverified master, B1이 그 master 소속 → updated, exists
    r3 = classify_dryrun(_StubTarget("mid", False, {B1: "mid"}), vals, bcs)
    check("dry-run 기존 unverified=updated", r3["master_status"] == "updated")
    bcmap3 = {b["barcode"]: b["status"] for b in r3["barcodes"]}
    check("dry-run 동일소속 barcode=exists", bcmap3[B1] == "exists")
    check("dry-run 미존재 barcode=inserted", bcmap3[B2] == "inserted")


def main():
    for t in [test_rpc_insert_and_idempotent, test_rpc_verified_held,
              test_rpc_barcode_conflict, test_dryrun_classify]:
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
