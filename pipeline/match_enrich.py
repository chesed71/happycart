"""매칭·보강·충돌 표시 — collected_products 안에서 수행.

매칭 축 3개 (§4.3):
  A. 쿠팡 ↔ kakamuka 바코드 일치 → 양쪽 matched_ref 기록
  B. 쿠팡(무바코드) ↔ kakamuka(바코드 보유) 이름 매칭 → 쿠팡에 바코드 보강
     - 보수적: 정규화한 brand+name+size 완전 일치 + 양쪽 모두 유일할 때만
  C. 수집 ↔ 서비스(기존 운영 데이터): product_barcodes에 이미 있는 바코드 → conflict
  D. 쿠팡 내부 중복 바코드:
     - 정규화 이름까지 동일한 그룹 = 중복 리스팅 → 대표 1행만 남기고 rejected (자동)
     - 이름이 다른 그룹 = Koreannet 오매칭 의심 → conflict (수동)
     kakamuka 내부 중복은 번들 리스팅 변형이라 충돌로 보지 않는다 — 원재료가
     없어 승격 대상이 아니고, 보강(B)은 유일 매칭만 쓰므로 무해.

자동 병합하지 않는다 — conflict는 수동 결정 후 stage 원복/rejected로 재진행.
재실행 멱등: 자동 표시한 dup conflict는 재평가 전에 원복한다 (수동 rejected는 유지).

사용: .venv/bin/python match_enrich.py [--dsn DSN]
"""
from __future__ import annotations

import argparse
import re
from collections import Counter

from common import connect


def norm(s: str | None) -> str:
    """이름 비교용 정규화 — 공백·구두점 제거, 소문자화."""
    if not s:
        return ""
    return re.sub(r"[\s\-_·,()\[\]{}!?'\"]+", "", s).lower()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dsn", default=None)
    args = ap.parse_args()
    stats = Counter()

    with connect(args.dsn) as conn, conn.cursor() as cur:
        # ── A. 쿠팡 ↔ kakamuka 바코드 일치 ──────────────────────────────────
        cur.execute("""
            update collected_products c set matched_ref = k.source || ':' || k.source_ref
            from collected_products k
            where c.source = 'coupang' and k.source = 'kakamuka'
              and c.barcode is not null and c.barcode = k.barcode
              and c.matched_ref is null
        """)
        stats["A_coupang_matched"] = cur.rowcount
        cur.execute("""
            update collected_products k set matched_ref = c.source || ':' || c.source_ref
            from collected_products c
            where k.source = 'kakamuka' and c.source = 'coupang'
              and k.barcode is not null and k.barcode = c.barcode
              and k.matched_ref is null
        """)
        stats["A_kakamuka_matched"] = cur.rowcount

        # ── B. 이름 매칭으로 바코드 보강 (보수적) ────────────────────────────
        cur.execute("""
            select id, brand, name, size from collected_products
            where source = 'coupang' and barcode is null
              and brand is not null and name is not null and size is not null
              and stage in ('parsed', 'tokenized', 'judged')
        """)
        coupang_rows = cur.fetchall()
        cur.execute("""
            select id, source_ref, barcode, brand, name, size from collected_products
            where source = 'kakamuka' and barcode is not null
              and brand is not null and name is not null and size is not null
        """)
        kaka_rows = cur.fetchall()

        def key(brand, name, size):
            return (norm(brand), norm(name), norm(size))

        kaka_by_key = {}
        for kid, kref, kbarcode, kb, kn, ks in kaka_rows:
            kaka_by_key.setdefault(key(kb, kn, ks), []).append((kid, kref, kbarcode))

        coupang_by_key = Counter(key(b, n, s) for _, b, n, s in coupang_rows)

        # 이미 수집 테이블에 존재하는 바코드는 보강에 쓰지 않는다 (중복 방지)
        cur.execute("select barcode from collected_products where barcode is not null")
        used_barcodes = {r[0] for r in cur.fetchall()}

        for cid, b, n, s in coupang_rows:
            k = key(b, n, s)
            candidates = kaka_by_key.get(k, [])
            # 양쪽 모두 유일할 때만 — 애매하면 매칭하지 않는다
            if len(candidates) != 1 or coupang_by_key[k] != 1:
                if candidates:
                    stats["B_ambiguous_skipped"] += 1
                continue
            kid, kref, kbarcode = candidates[0]
            if kbarcode in used_barcodes:
                stats["B_barcode_already_used"] += 1
                continue
            cur.execute("""
                update collected_products
                set barcode = %s, matched_ref = %s
                where id = %s and barcode is null
            """, (kbarcode, f"kakamuka:{kref}", cid))
            used_barcodes.add(kbarcode)
            stats["B_enriched"] += cur.rowcount

        # ── C. 서비스 테이블(기존 운영 데이터)과 바코드 충돌 ─────────────────
        cur.execute("""
            update collected_products c
            set stage = 'conflict',
                conflict_reason = 'barcode exists in product_barcodes (master '
                                  || b.master_id || ', verified_status=' || m.verified_status || ')'
            from product_barcodes b
            join product_masters m on m.id = b.master_id
            where c.barcode = b.barcode
              and c.stage in ('parsed', 'tokenized', 'judged')
        """)
        stats["C_service_conflict"] = cur.rowcount

        # ── D. 쿠팡 내부 중복 바코드 ────────────────────────────────────────
        # 재평가를 위해 이전 실행이 자동 표시한 dup conflict 원복 (수동 결정 유지).
        # parsed로 되돌릴 때 파생 컬럼도 비운다 (review RPC와 동일 — 재실행 시 judged였던
        # 행에 stale verdict가 남지 않도록).
        cur.execute("""
            update collected_products
            set stage = 'parsed', conflict_reason = null,
                ingredients_tokens = null, verdict = null,
                bad_ingredients_detected = null, good_ingredients_detected = null,
                verdict_reason_codes = null, rule_version = null, computed_at = null
            where stage = 'conflict' and conflict_reason like 'duplicate barcode within source%'
        """)
        stats["D_reset_for_reeval"] = cur.rowcount

        cur.execute("""
            select id, source_ref, barcode, brand, name, ingredients_raw is not null
            from collected_products
            where source = 'coupang' and barcode is not null
              and stage in ('parsed', 'tokenized', 'judged')
        """)
        by_barcode = {}
        for row in cur.fetchall():
            by_barcode.setdefault(row[2], []).append(row)

        for barcode, group in by_barcode.items():
            if len(group) < 2:
                continue
            names = {norm((g[3] or "") + (g[4] or "")) for g in group}
            if len(names) == 1:
                # 중복 리스팅 — 원재료 있는 행 우선, 다음 source_ref 순으로 대표 선정
                group.sort(key=lambda g: (not g[5], g[1]))
                keeper = group[0]
                for g in group[1:]:
                    cur.execute("""
                        update collected_products
                        set stage = 'rejected',
                            conflict_reason = 'duplicate listing of coupang:' || %s
                        where id = %s
                    """, (keeper[1], g[0]))
                    stats["D_dup_listing_rejected"] += 1
            else:
                for g in group:
                    cur.execute("""
                        update collected_products
                        set stage = 'conflict',
                            conflict_reason = 'duplicate barcode within source: ' || %s
                        where id = %s
                    """, (barcode, g[0]))
                    stats["D_internal_dup_conflict"] += 1

        conn.commit()

        cur.execute("select stage, count(*) from collected_products group by stage order by 1")
        print(dict(stats))
        print("stage:", dict(cur.fetchall()))
        cur.execute("""
            select count(*) filter (where barcode is not null and ingredients_raw is not null
                                    and stage in ('parsed','tokenized','judged'))
            from collected_products
        """)
        print(f"promote candidates after enrich: {cur.fetchone()[0]}")


if __name__ == "__main__":
    main()
