"""Phase 3 — 로컬 승격분을 운영 Supabase에 업로드.

로컬 collected_products는 운영에 올라가지 않는다. 승격된 product_masters/barcodes만
운영에 올린다. 쓰기는 **운영 RPC `upload_promoted_product`** 로만 한다 (0016 마이그레이션):
  - master upsert(verified 가드) + barcode 연결을 한 트랜잭션에서 (원자성)
  - verified 가드를 변경문에 박아 read-then-write 경쟁 제거
  - 따라서 클라이언트는 직접 INSERT/PATCH 하지 않는다 (HIGH 1·2 대응)

백엔드 2종 (둘 다 같은 RPC 호출):
  - REST (기본): SUPABASE_URL + SUPABASE_SERVICE_ROLE_KEY (DB 비번 불필요)
  - postgres: --target-dsn (운영 DB 연결문자열)

--dry-run: 쓰기 없이 운영을 읽어 각 master/barcode가 어떻게 처리될지 분류만 보여준다.

사용:
  .venv/bin/python upload_prod.py --dry-run
  .venv/bin/python upload_prod.py
  .venv/bin/python upload_prod.py --target-dsn <dsn>
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import urllib.error
import urllib.request
from collections import Counter
from datetime import datetime

import psycopg

from common import connect

MASTER_COLS = [
    "brand", "name", "category", "ingredients_raw", "ingredients_tokens",
    "bad_ingredients_detected", "good_ingredients_detected", "verdict_reason_codes",
    "verdict", "rule_version", "computed_at", "source", "source_url",
    "source_checked_at", "verified_status",
]


def ingredients_hash(brand, ingredients_raw):
    return hashlib.md5(f"{brand}|{ingredients_raw}".encode()).hexdigest()


def _jsonable(v):
    return v.isoformat() if isinstance(v, datetime) else v


def fetch_promoted(src):
    """승격된 master(중복 제거) + master별 barcode 목록."""
    with src.cursor() as cur:
        cur.execute(f"""
            select distinct m.id, {', '.join('m.' + c for c in MASTER_COLS)}
            from product_masters m
            join collected_products c on c.promoted_master_id = m.id
            where c.stage = 'promoted'
        """)
        masters = {r[0]: dict(zip(MASTER_COLS, (_jsonable(x) for x in r[1:]))) for r in cur.fetchall()}
        # collected row 식별자(id)를 함께 들고 온다 — writeback을 행 단위로 좁히기 위해.
        # barcode가 collected_products에서 유니크하지 않으므로 (b.master_id =
        # c.promoted_master_id)까지 묶어 그 행의 바코드만 매칭한다.
        cur.execute("""
            select c.promoted_master_id, c.id, c.barcode, b.size, b.image_url, b.image_source_url
            from collected_products c
            join product_barcodes b
              on b.barcode = c.barcode and b.master_id = c.promoted_master_id
            where c.stage = 'promoted'
        """)
        bc_by_master: dict = {}
        for mid, cid, barcode, size, iu, isu in cur.fetchall():
            bc_by_master.setdefault(mid, []).append(
                {"collected_id": cid, "barcode": barcode, "size": size,
                 "image_url": iu, "image_source_url": isu})
    return masters, bc_by_master


# ── REST 백엔드 ───────────────────────────────────────────────────────────────
class RestTarget:
    def __init__(self):
        url = os.environ.get("SUPABASE_URL", "").strip('"').rstrip("/")
        key = os.environ.get("SUPABASE_SERVICE_ROLE_KEY", "").strip('"')
        if not url or not key:
            raise SystemExit("error: SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY 필요")
        self.base, self.key = f"{url}/rest/v1", key

    def _req(self, method, path, body=None):
        req = urllib.request.Request(self.base + path, method=method)
        req.add_header("apikey", self.key)
        req.add_header("Authorization", f"Bearer {self.key}")
        req.add_header("Content-Type", "application/json")
        data = json.dumps(body).encode() if body is not None else None
        try:
            with urllib.request.urlopen(req, data=data) as resp:
                raw = resp.read().decode()
                return json.loads(raw) if raw else None
        except urllib.error.HTTPError as e:
            raise RuntimeError(f"{method} {path} → {e.code} {e.read().decode()[:200]}")

    def plan_master(self, vals):
        h = ingredients_hash(vals["brand"], vals["ingredients_raw"])
        rows = self._req("GET", f"/product_masters?ingredients_hash=eq.{h}&select=id,verified_status")
        if not rows:
            return None, False
        return rows[0]["id"], rows[0]["verified_status"] == "verified"

    def barcode_owner(self, barcode):
        rows = self._req("GET", f"/product_barcodes?barcode=eq.{barcode}&select=master_id")
        return rows[0]["master_id"] if rows else None

    def upload(self, master, barcodes):
        return self._req("POST", "/rpc/upload_promoted_product",
                         {"p_master": master, "p_barcodes": barcodes})


# ── postgres 백엔드 (같은 RPC) ────────────────────────────────────────────────
class PgTarget:
    def __init__(self, dsn):
        self.conn = psycopg.connect(dsn)

    def plan_master(self, vals):
        with self.conn.cursor() as cur:
            cur.execute("select id, verified_status::text from product_masters where ingredients_hash = md5(%s||'|'||%s)",
                        (vals["brand"], vals["ingredients_raw"]))
            r = cur.fetchone()
            return (None, False) if not r else (r[0], r[1] == "verified")

    def barcode_owner(self, barcode):
        with self.conn.cursor() as cur:
            cur.execute("select master_id from product_barcodes where barcode=%s", (barcode,))
            r = cur.fetchone()
            return r[0] if r else None

    def upload(self, master, barcodes):
        with self.conn.cursor() as cur:
            cur.execute("select public.upload_promoted_product(%s::jsonb, %s::jsonb)",
                        (json.dumps(master), json.dumps(barcodes)))
            res = cur.fetchone()[0]
        self.conn.commit()
        return res


def writeback_attachments(cur, attach_rows):
    """붙은 행(id)에만 prod_master_id 기록. barcode가 아니라 행 식별자(id) 기준이라,
    같은 barcode를 가진 다른 promoted 행(conflict/held)은 건드리지 않는다.
    attach_rows: [(prod_master_id, collected_id, local_master_id), ...]"""
    for prod_id, cid, local_id in attach_rows:
        cur.execute("""update collected_products set prod_master_id=%s
                       where id=%s and promoted_master_id=%s and stage='promoted'""",
                    (prod_id, cid, local_id))


def classify_dryrun(target, vals, barcodes):
    """쓰기 없이 master/barcode가 어떻게 처리될지 분류 (운영 읽기만). RPC와 동일 분류."""
    existing_id, verified = target.plan_master(vals)
    if verified:
        return {"master_id": existing_id, "master_status": "verified_held", "barcodes": []}
    m_status = "updated" if existing_id is not None else "inserted"
    bc_out, attached = [], 0
    for bc in barcodes:
        owner = target.barcode_owner(bc["barcode"])
        if owner is None:
            s = "inserted"; attached += 1
        elif existing_id is not None and str(owner) == str(existing_id):
            s = "exists"; attached += 1
        else:
            s = "conflict"
        bc_out.append({"barcode": bc["barcode"], "status": s})
    # 신규 master인데 붙을 barcode가 없으면 빈 master → 정리 대상(empty_held)
    if m_status == "inserted" and attached == 0:
        return {"master_id": None, "master_status": "empty_held", "barcodes": bc_out}
    return {"master_id": existing_id, "master_status": m_status, "barcodes": bc_out}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--target-dsn", default=None)
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    target = PgTarget(args.target_dsn) if args.target_dsn else RestTarget()
    stats = Counter()

    with connect() as src:
        masters, bc_by_master = fetch_promoted(src)
        if not masters:
            print("업로드할 승격분 없음 (stage='promoted' 0건)")
            return
        print(f"승격 master {len(masters)} / barcode {sum(len(v) for v in bc_by_master.values())}"
              + (" [DRY-RUN]" if args.dry_run else ""))

        # prod_master_id는 collected_products(행=바코드) 단위로, **실제로 운영에 붙은
        # 바코드(inserted/exists) 행에만** 기록한다. verified_held / conflict / empty_held
        # 행은 운영에 올라가지 않았으므로 기록하지 않는다(=미매핑, 수동 처리 대상).
        # → prod_master_id is null & stage='promoted' = "아직 운영 미반영"으로 조회 가능.
        attach_rows = []  # (prod_master_id, collected_id, local_master_id) — 붙은 행만
        for local_id, vals in masters.items():
            entries = bc_by_master.get(local_id, [])
            payload = [{k: e[k] for k in ("barcode", "size", "image_url", "image_source_url")}
                       for e in entries]
            bc_to_cids = {}
            for e in entries:
                bc_to_cids.setdefault(e["barcode"], []).append(e["collected_id"])
            res = classify_dryrun(target, vals, payload) if args.dry_run else target.upload(vals, payload)
            stats[f"master_{res['master_status']}"] += 1
            if res["master_status"] == "verified_held":
                print(f"  HOLD verified master ({vals['brand']} / {vals['name']}) — barcode 보류")
            elif res["master_status"] == "empty_held":
                print(f"  EMPTY-HELD ({vals['brand']} / {vals['name']}) — 바코드 전부 충돌, master 미생성")
            for b in res["barcodes"]:
                stats[f"barcode_{b['status']}"] += 1
                if b["status"] == "conflict":
                    print(f"  CONFLICT barcode {b['barcode']} — 운영에서 다른 master 소속, 보류")
                elif b["status"] in ("inserted", "exists") and res.get("master_id"):
                    for cid in bc_to_cids.get(b["barcode"], []):
                        attach_rows.append((res["master_id"], cid, local_id))

        # prod_master_id는 **붙은 그 행(id)** 에만 기록. barcode 기준이 아니라 행 식별자
        # 기준이라, 같은 barcode를 가진 다른 promoted 행(conflict/held)은 건드리지 않는다.
        if not args.dry_run and attach_rows:
            with src.cursor() as cur:
                writeback_attachments(cur, attach_rows)
            src.commit()

    print(dict(stats))


if __name__ == "__main__":
    main()
