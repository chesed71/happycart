"""Phase 3 — 로컬 승격분을 운영 Supabase에 업로드.

로컬 collected_products는 운영에 올라가지 않는다. **승격된 product_masters/barcodes만**
운영에 upsert한다. 핵심 규칙(적재 계획 §6.3):
  - 로컬 master uuid를 운영에 쓰지 않는다 — ingredients_hash(생성 UNIQUE)로 운영 master를
    찾아 upsert하고, 운영 id로 barcode를 연결한다.
  - verified 보호: 기존 verified master는 덮지 않는다. 거기 새 barcode 자동 연결도 보류
    (즉시 노출 방지).
  - barcode가 운영에서 다른 master 소속이면 보류. 멱등(재실행 중복 없음).
  - 업로드한 운영 master id를 로컬 prod_master_id에 기록.

백엔드 2종:
  - REST (기본): SUPABASE_URL + SUPABASE_SERVICE_ROLE_KEY (DB 비번 불필요)
  - postgres: --target-dsn (운영 DB 연결문자열, 비번 필요)

사용:
  .venv/bin/python upload_prod.py --dry-run          # REST, 쓰기 없이 미리보기
  .venv/bin/python upload_prod.py                    # REST, 실제 업로드
  .venv/bin/python upload_prod.py --target-dsn <dsn> # postgres 직접
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


def ingredients_hash(brand: str, ingredients_raw: str) -> str:
    return hashlib.md5(f"{brand}|{ingredients_raw}".encode()).hexdigest()


def fetch_promoted(src):
    """승격된 master(중복 제거)와 barcode 목록을 로컬에서 읽는다."""
    with src.cursor() as cur:
        cur.execute(f"""
            select distinct m.id, {', '.join('m.' + c for c in MASTER_COLS)}
            from product_masters m
            join collected_products c on c.promoted_master_id = m.id
            where c.stage = 'promoted'
        """)
        masters = {r[0]: dict(zip(MASTER_COLS, r[1:])) for r in cur.fetchall()}
        cur.execute("""
            select c.barcode, c.promoted_master_id, b.size, b.image_url, b.image_source_url
            from collected_products c
            join product_barcodes b on b.barcode = c.barcode
            where c.stage = 'promoted'
        """)
        barcodes = cur.fetchall()
    return masters, barcodes


def _jsonable(v):
    if isinstance(v, datetime):
        return v.isoformat()
    return v


# ── 백엔드: REST (PostgREST) ──────────────────────────────────────────────────
class RestTarget:
    def __init__(self, dry_run: bool):
        url = os.environ.get("SUPABASE_URL", "").rstrip("/").strip('"')
        key = os.environ.get("SUPABASE_SERVICE_ROLE_KEY", "").strip('"')
        if not url or not key:
            raise SystemExit("error: SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY 필요")
        self.base = f"{url}/rest/v1"
        self.key = key
        self.dry_run = dry_run

    def _req(self, method, path, body=None, prefer=None):
        req = urllib.request.Request(self.base + path, method=method)
        req.add_header("apikey", self.key)
        req.add_header("Authorization", f"Bearer {self.key}")
        req.add_header("Content-Type", "application/json")
        if prefer:
            req.add_header("Prefer", prefer)
        data = json.dumps(body).encode() if body is not None else None
        try:
            with urllib.request.urlopen(req, data=data) as resp:
                raw = resp.read().decode()
                return json.loads(raw) if raw else []
        except urllib.error.HTTPError as e:
            raise RuntimeError(f"{method} {path} → {e.code} {e.read().decode()[:200]}")

    def find_master(self, brand, ingredients_raw):
        h = ingredients_hash(brand, ingredients_raw)
        rows = self._req("GET", f"/product_masters?ingredients_hash=eq.{h}&select=id,verified_status")
        return rows[0] if rows else None

    def upsert_master(self, vals: dict):
        existing = self.find_master(vals["brand"], vals["ingredients_raw"])
        body = {k: _jsonable(vals[k]) for k in MASTER_COLS}
        if existing is None:
            if self.dry_run:
                return "DRYRUN", "inserted"
            row = self._req("POST", "/product_masters", [body], prefer="return=representation")
            return row[0]["id"], "inserted"
        if existing["verified_status"] == "verified":
            return existing["id"], "verified_skip"
        if not self.dry_run:
            upd = {k: v for k, v in body.items() if k != "verified_status"}
            self._req("PATCH", f"/product_masters?id=eq.{existing['id']}", upd,
                      prefer="return=minimal")
        return existing["id"], "updated"

    def barcode_owner(self, barcode):
        rows = self._req("GET", f"/product_barcodes?barcode=eq.{barcode}&select=master_id")
        return rows[0]["master_id"] if rows else None

    def insert_barcode(self, barcode, master_id, size, image_url, image_source_url):
        if self.dry_run:
            return
        self._req("POST", "/product_barcodes", [{
            "barcode": barcode, "master_id": master_id, "size": size,
            "image_url": image_url, "image_source_url": image_source_url,
        }], prefer="return=minimal")

    def commit(self):
        pass


# ── 백엔드: postgres 직접 ─────────────────────────────────────────────────────
class PgTarget:
    def __init__(self, dsn: str, dry_run: bool):
        self.conn = psycopg.connect(dsn)
        self.dry_run = dry_run

    def upsert_master(self, vals: dict):
        cols = ", ".join(MASTER_COLS)
        ph = ", ".join(["%s"] * len(MASTER_COLS))
        updates = ", ".join(f"{c} = excluded.{c}" for c in MASTER_COLS if c != "verified_status")
        with self.conn.cursor() as cur:
            cur.execute(f"""
                insert into product_masters ({cols}) values ({ph})
                on conflict (ingredients_hash) do update set {updates}, updated_at = now()
                where product_masters.verified_status <> 'verified'
                returning id, (xmax = 0) as inserted
            """, [vals[c] for c in MASTER_COLS])
            row = cur.fetchone()
            if row:
                return row[0], ("inserted" if row[1] else "updated")
            cur.execute("select id from product_masters where ingredients_hash = md5(%s||'|'||%s)",
                        (vals["brand"], vals["ingredients_raw"]))
            ex = cur.fetchone()
            return (ex[0] if ex else None), "verified_skip"

    def barcode_owner(self, barcode):
        with self.conn.cursor() as cur:
            cur.execute("select master_id from product_barcodes where barcode=%s", (barcode,))
            r = cur.fetchone()
            return r[0] if r else None

    def insert_barcode(self, barcode, master_id, size, image_url, image_source_url):
        with self.conn.cursor() as cur:
            cur.execute("""insert into product_barcodes (barcode, master_id, size, image_url, image_source_url)
                values (%s,%s,%s,%s,%s) on conflict (barcode) do nothing""",
                (barcode, master_id, size, image_url, image_source_url))

    def commit(self):
        if self.dry_run:
            self.conn.rollback()
        else:
            self.conn.commit()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--target-dsn", default=None, help="운영 postgres DSN (없으면 REST)")
    ap.add_argument("--dry-run", action="store_true", help="쓰기 없이 미리보기")
    args = ap.parse_args()

    target = PgTarget(args.target_dsn, args.dry_run) if args.target_dsn else RestTarget(args.dry_run)
    stats = Counter()

    with connect() as src:
        masters, barcodes = fetch_promoted(src)
        if not masters:
            print("업로드할 승격분 없음 (collected_products에 stage='promoted' 0건)")
            return
        print(f"승격 master {len(masters)} / barcode {len(barcodes)}"
              + (" [DRY-RUN]" if args.dry_run else ""))

        local_to_prod, verified_skipped = {}, set()
        for local_id, vals in masters.items():
            prod_id, state = target.upsert_master(vals)
            stats[f"master_{state}"] += 1
            if prod_id:
                local_to_prod[local_id] = prod_id
            if state == "verified_skip":
                verified_skipped.add(local_id)
                print(f"  HOLD verified master 재사용 ({vals['brand']} / {vals['name']}) — 수동 연결")

        for barcode, local_master_id, size, image_url, image_source_url in barcodes:
            if local_master_id in verified_skipped:
                stats["barcode_verified_hold"] += 1
                continue
            prod_master = local_to_prod.get(local_master_id)
            if not prod_master or prod_master == "DRYRUN":
                stats["barcode_pending" if prod_master == "DRYRUN" else "barcode_no_master"] += 1
                continue
            owner = target.barcode_owner(barcode)
            if owner is None:
                target.insert_barcode(barcode, prod_master, size, image_url, image_source_url)
                stats["barcode_inserted"] += 1
            elif str(owner) == str(prod_master):
                stats["barcode_exists_ok"] += 1
            else:
                stats["barcode_conflict"] += 1
                print(f"  CONFLICT barcode {barcode} 운영에서 다른 master 소속 — 보류")

        target.commit()
        # 운영 id를 로컬 prod_master_id에 기록 (실제 업로드 시에만)
        if not args.dry_run:
            with src.cursor() as cur:
                for local_id, prod_id in local_to_prod.items():
                    if prod_id and prod_id != "DRYRUN":
                        cur.execute("update collected_products set prod_master_id=%s where promoted_master_id=%s",
                                    (prod_id, local_id))
            src.commit()

    print(dict(stats))


if __name__ == "__main__":
    main()
