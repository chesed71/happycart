"""Phase 3 — 로컬 승격분을 운영 Supabase에 업로드 (service_role 직접 postgres).

로컬 collected_products는 운영에 올라가지 않는다. **승격된 product_masters/barcodes만**
운영에 upsert한다. 핵심 규칙(적재 계획 §6.3):
  - 로컬 master uuid를 운영에 쓰지 않는다 — ingredients_hash(생성 UNIQUE)를 conflict
    target으로 운영 master를 upsert하고, 반환된 **운영 id**로 barcode를 연결한다.
  - verified 보호: `on conflict do update ... where verified_status <> 'verified'`.
    기존 verified master는 덮어쓰지 않는다. 거기 새 barcode 연결은 즉시 노출이라 수동 검토.
  - 멱등: 재실행해도 중복 생성 없음. 업로드한 운영 id를 로컬 prod_master_id에 기록.

연결:
  source = HAPPYCART_DSN (로컬 happycart)
  target = --target-dsn 또는 env SUPABASE_DB_URL (운영 postgres, service_role)

사용:
  .venv/bin/python upload_prod.py --target-dsn <dsn> [--dry-run]
"""
from __future__ import annotations

import argparse
import os
from collections import Counter

import psycopg

from common import connect, dsn

MASTER_COLS = [
    "brand", "name", "category", "ingredients_raw", "ingredients_tokens",
    "bad_ingredients_detected", "good_ingredients_detected", "verdict_reason_codes",
    "verdict", "rule_version", "computed_at", "source", "source_url",
    "source_checked_at", "verified_status",
]


def fetch_promoted(src) -> tuple[dict, list]:
    """승격된 master(중복 제거)와 barcode 목록을 로컬에서 읽는다."""
    with src.cursor() as cur:
        cur.execute(f"""
            select distinct m.id, {', '.join('m.' + c for c in MASTER_COLS)}
            from product_masters m
            join collected_products c on c.promoted_master_id = m.id
            where c.stage = 'promoted'
        """)
        masters = {r[0]: r[1:] for r in cur.fetchall()}
        cur.execute("""
            select c.barcode, c.promoted_master_id, b.size, b.image_url, b.image_source_url
            from collected_products c
            join product_barcodes b on b.barcode = c.barcode
            where c.stage = 'promoted'
        """)
        barcodes = cur.fetchall()
    return masters, barcodes


def upsert_master(tgt, vals) -> tuple[str | None, str]:
    """운영에 master upsert (verified 보호). (운영 id, 상태) 반환.
    상태: inserted / updated / verified_skip."""
    cols = ", ".join(MASTER_COLS)
    ph = ", ".join(["%s"] * len(MASTER_COLS))
    updates = ", ".join(f"{c} = excluded.{c}" for c in MASTER_COLS if c != "verified_status")
    with tgt.cursor() as cur:
        # verdict는 enum 캐스트
        cur.execute(f"""
            insert into product_masters ({cols})
            values ({ph})
            on conflict (ingredients_hash) do update set {updates}, updated_at = now()
            where product_masters.verified_status <> 'verified'
            returning id, (xmax = 0) as inserted
        """, vals)
        row = cur.fetchone()
        if row:
            return row[0], ("inserted" if row[1] else "updated")
        # do update가 verified 가드로 막힘 → 기존 verified master
        brand, ingredients_raw = vals[0], vals[3]
        cur.execute(
            "select id from product_masters where ingredients_hash = md5(%s || '|' || %s)",
            (brand, ingredients_raw))
        existing = cur.fetchone()
        return (existing[0] if existing else None), "verified_skip"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--target-dsn", default=os.environ.get("SUPABASE_DB_URL"))
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()
    if not args.target_dsn:
        raise SystemExit("error: --target-dsn 또는 SUPABASE_DB_URL 필요 (운영 postgres)")

    stats = Counter()
    with connect() as src, psycopg.connect(args.target_dsn) as tgt:
        masters, barcodes = fetch_promoted(src)
        if not masters:
            print("업로드할 승격분 없음 (collected_products에 stage='promoted' 0건)")
            return

        local_to_prod: dict[str, str] = {}
        verified_skipped: set[str] = set()
        for local_id, vals in masters.items():
            prod_id, state = upsert_master(tgt, list(vals))
            stats[f"master_{state}"] += 1
            if prod_id:
                local_to_prod[local_id] = prod_id
            if state == "verified_skip":
                verified_skipped.add(local_id)
                print(f"  HOLD verified master 재사용 (local {local_id}) — 새 barcode 수동 연결 필요")

        for barcode, local_master_id, size, image_url, image_source_url in barcodes:
            prod_master = local_to_prod.get(local_master_id)
            if local_master_id in verified_skipped:
                stats["barcode_verified_hold"] += 1
                continue  # verified master에 새 barcode 자동 연결 금지 (즉시 노출)
            if not prod_master:
                stats["barcode_no_master"] += 1
                continue
            with tgt.cursor() as cur:
                cur.execute("""
                    insert into product_barcodes (barcode, master_id, size, image_url, image_source_url)
                    values (%s, %s, %s, %s, %s)
                    on conflict (barcode) do nothing
                    returning master_id
                """, (barcode, prod_master, size, image_url, image_source_url))
                ins = cur.fetchone()
                if ins:
                    stats["barcode_inserted"] += 1
                else:
                    cur.execute("select master_id from product_barcodes where barcode=%s", (barcode,))
                    owner = cur.fetchone()[0]
                    if str(owner) != str(prod_master):
                        stats["barcode_conflict"] += 1
                        print(f"  CONFLICT barcode {barcode} 운영에서 다른 master 소속 — 보류")
                    else:
                        stats["barcode_exists_ok"] += 1

        if args.dry_run:
            tgt.rollback()
            print("(dry-run — 운영 롤백)")
        else:
            tgt.commit()
            # 운영 master id를 로컬 prod_master_id에 기록 (멱등 매핑)
            with src.cursor() as cur:
                for local_id, prod_id in local_to_prod.items():
                    cur.execute(
                        "update collected_products set prod_master_id=%s where promoted_master_id=%s",
                        (prod_id, local_id))
            src.commit()

        print(dict(stats))
        # 검증: 운영 barcodes FK 고아 0
        with tgt.cursor() as cur:
            cur.execute("""
                select count(*) from product_barcodes b
                left join product_masters m on m.id=b.master_id where m.id is null
            """)
            print(f"운영 FK 고아: {cur.fetchone()[0]}")


if __name__ == "__main__":
    main()
