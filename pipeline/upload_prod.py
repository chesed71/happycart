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
        cur.execute("""
            select c.promoted_master_id, c.barcode, b.size, b.image_url, b.image_source_url
            from collected_products c
            join product_barcodes b on b.barcode = c.barcode
            where c.stage = 'promoted'
        """)
        bc_by_master: dict = {}
        for mid, barcode, size, iu, isu in cur.fetchall():
            bc_by_master.setdefault(mid, []).append(
                {"barcode": barcode, "size": size, "image_url": iu, "image_source_url": isu})
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


def classify_dryrun(target, vals, barcodes):
    """쓰기 없이 master/barcode가 어떻게 처리될지 분류 (운영 읽기만)."""
    existing_id, verified = target.plan_master(vals)
    if verified:
        m_status = "verified_held"
    elif existing_id is not None:
        m_status = "updated"
    else:
        m_status = "inserted"
    bc_out = []
    for bc in barcodes:
        owner = target.barcode_owner(bc["barcode"])
        if m_status == "verified_held":
            s = "held"
        elif owner is None:
            s = "inserted"
        elif existing_id is not None and str(owner) == str(existing_id):
            s = "exists"
        else:
            s = "conflict"
        bc_out.append({"barcode": bc["barcode"], "status": s})
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

        local_to_prod = {}
        for local_id, vals in masters.items():
            barcodes = bc_by_master.get(local_id, [])
            if args.dry_run:
                res = classify_dryrun(target, vals, barcodes)
            else:
                res = target.upload(vals, barcodes)
            stats[f"master_{res['master_status']}"] += 1
            for b in res["barcodes"]:
                stats[f"barcode_{b['status']}"] += 1
                if b["status"] == "conflict":
                    print(f"  CONFLICT barcode {b['barcode']} — 운영에서 다른 master 소속, 보류")
            if res["master_status"] == "verified_held":
                print(f"  HOLD verified master ({vals['brand']} / {vals['name']}) — barcode 보류")
                continue  # MEDIUM-1: 보류분은 prod_master_id 기록하지 않는다
            if not args.dry_run and res.get("master_id"):
                local_to_prod[local_id] = res["master_id"]

        # 실제 업로드분만 운영 id 기록
        if not args.dry_run and local_to_prod:
            with src.cursor() as cur:
                for local_id, prod_id in local_to_prod.items():
                    cur.execute("update collected_products set prod_master_id=%s where promoted_master_id=%s",
                                (prod_id, local_id))
            src.commit()

    print(dict(stats))


if __name__ == "__main__":
    main()
