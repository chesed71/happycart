"""파이프라인 상태·검토 리포트 — 사람이 결정해야 하는 항목을 모아 보여준다.

사용:
  .venv/bin/python report.py            # 콘솔 요약
  .venv/bin/python report.py --md FILE  # 마크다운 리포트 파일로 저장

참고: docs/superpowers/specs/2026-06-11-local-db-data-ingestion-plan.md §4.3, §7
"""
from __future__ import annotations

import argparse

from common import connect

STAGE_SQL = "select stage, count(*) from collected_products group by stage order by 2 desc"

CONFLICT_KIND_SQL = """
select
  case
    when conflict_reason like '%product_barcodes%' then 'A. 시드/서비스 바코드 충돌'
    when conflict_reason like 'duplicate barcode within source%' then 'B. 같은 바코드 다른 상품(오매칭 의심)'
    else 'C. 기타'
  end as kind,
  count(*) rows, count(distinct barcode) barcodes
from collected_products where stage='conflict' group by 1 order by 1
"""

# B 유형: 같은 바코드를 가진 행들을 묶어서 (사람이 어느 게 맞는지 판단)
CONFLICT_B_SQL = """
select barcode, array_agg(source || ':' || source_ref order by source_ref) refs,
       array_agg(coalesce(name,'(이름없음)') order by source_ref) names
from collected_products
where stage='conflict' and conflict_reason like 'duplicate barcode within source%'
group by barcode order by barcode
"""

CONFLICT_A_SQL = """
select c.source||':'||c.source_ref ref, c.name, c.barcode, c.conflict_reason
from collected_products c
where c.stage='conflict' and c.conflict_reason like '%product_barcodes%'
order by c.barcode
"""

# 승격 보류 (judged인데 조건 미달) — 사유별
HELD_SQL = """
select
  case
    when barcode is null then '바코드 없음'
    when brand is null or name is null or size is null then 'title 파싱 미완'
    when confidence = 'low' then 'low 신뢰도'
    else '기타'
  end reason,
  count(*) rows,
  count(*) filter (where ingredients_raw is not null) with_ingredients
from collected_products where stage='judged'
group by 1 order by 2 desc
"""

PARSE_FIX_SQL = """
select count(*) from collected_products
where stage in ('parsed','tokenized','judged')
  and ingredients_raw is not null and barcode is not null
  and (brand is null or name is null or size is null)
"""


def section(title): return f"\n## {title}\n"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--md", default=None, help="마크다운 리포트 저장 경로")
    args = ap.parse_args()
    out = []

    with connect() as conn, conn.cursor() as cur:
        out.append("# 파이프라인 검토 리포트\n")

        cur.execute(STAGE_SQL)
        out.append(section("stage 분포"))
        for stage, n in cur.fetchall():
            out.append(f"- {stage}: {n}")

        cur.execute(CONFLICT_KIND_SQL)
        out.append(section("conflict 분류 (수동 결정 대상)"))
        for kind, rows, bc in cur.fetchall():
            out.append(f"- {kind}: {rows}행 / {bc}바코드")

        cur.execute(CONFLICT_A_SQL)
        rows_a = cur.fetchall()
        if rows_a:
            out.append(section("A. 시드/서비스 충돌 — 기존 verified 우선, 크롤링은 보통 rejected"))
            for ref, name, barcode, reason in rows_a:
                out.append(f"- `{barcode}` {name} ({ref}) — {reason}")

        cur.execute(CONFLICT_B_SQL)
        rows_b = cur.fetchall()
        out.append(section(f"B. 같은 바코드 다른 상품 — {len(rows_b)}개 바코드 (어느 게 맞는지 판단)"))
        for barcode, refs, names in rows_b:
            uniq = sorted(set(names))
            out.append(f"- `{barcode}` ({len(refs)}행): {' / '.join(uniq[:5])}"
                       + (" …" if len(uniq) > 5 else ""))

        cur.execute(HELD_SQL)
        out.append(section("승격 보류 (judged, 조건 미달)"))
        for reason, rows, with_ing in cur.fetchall():
            out.append(f"- {reason}: {rows}행 (원재료 보유 {with_ing})")

        cur.execute(PARSE_FIX_SQL)
        n_fix = cur.fetchone()[0]
        out.append(section("승격을 막는 title 파싱 미완 (바코드·원재료는 있음)"))
        out.append(f"- {n_fix}행 — brand/name/size 보정하면 즉시 승격 후보")

    text = "\n".join(out) + "\n"
    if args.md:
        with open(args.md, "w", encoding="utf-8") as f:
            f.write(text)
        print(f"saved: {args.md}")
    else:
        print(text)


if __name__ == "__main__":
    main()
