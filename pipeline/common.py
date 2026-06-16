"""파이프라인 공용 헬퍼 — DB 연결, EAN 검증, collected_products upsert.

참고: docs/superpowers/specs/2026-06-11-local-db-data-ingestion-plan.md §4
"""
from __future__ import annotations

import json
import os
import re

import psycopg

COUPANG_OUTPUT = "/Users/innovator/Project/CoupangCrawler/output"
KAKAMUKA_ROOT = "/Users/innovator/Project/DataCollector/kakamuka"


def _load_dotenv() -> None:
    """pipeline/.env를 os.environ에 로드 (이미 설정된 값은 덮어쓰지 않음).

    의존성 없이 KEY=VALUE 라인만 파싱한다 — 주석(#)·빈 줄·따옴표 처리.
    """
    path = os.path.join(os.path.dirname(__file__), ".env")
    if not os.path.exists(path):
        return
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, val = line.split("=", 1)
            key, val = key.strip(), val.strip().strip("'\"")
            os.environ.setdefault(key, val)


_load_dotenv()


def dsn(db: str | None = None) -> str:
    """DSN 조합. db를 주면 그 DB로, 아니면 HAPPYCART_DSN(또는 기본 DB)으로."""
    if db is None:
        d = os.environ.get("HAPPYCART_DSN")
        if d:
            return d
        db = os.environ.get("HAPPYCART_PG_DB", "happycart")
    return (
        f"postgresql://{os.environ.get('HAPPYCART_PG_USER', 'postgres')}:"
        f"{os.environ.get('HAPPYCART_PG_PASSWORD', 'happycart')}@"
        f"{os.environ.get('HAPPYCART_PG_HOST', 'localhost')}:"
        f"{os.environ.get('HAPPYCART_PG_PORT', '54322')}/{db}"
    )


def connect(override_dsn: str | None = None) -> psycopg.Connection:
    return psycopg.connect(override_dsn or dsn())


def ean_valid(code: str) -> bool:
    """EAN-8 / EAN-13 형식 + 체크 디지트 검증. 바코드는 항상 text로 다룬다 (선행 0 보존)."""
    if not isinstance(code, str) or not re.fullmatch(r"\d{8}|\d{13}", code):
        return False
    digits = [int(c) for c in code]
    body, check = digits[:-1], digits[-1]
    if len(code) == 13:
        weights = [1, 3] * 6
    else:  # EAN-8
        weights = [3, 1] * 3 + [3]
    total = sum(d * w for d, w in zip(body, weights))
    return (10 - total % 10) % 10 == check


# 정제용 size 패턴: "54g", "1.5L", "500ml", "48g (24g×2번들)" 의 선두 토큰 등
SIZE_RE = re.compile(r"^\d+(\.\d+)?\s*(g|kg|ml|l|L|G|ML|KG)$")
COUNT_RE = re.compile(r"^\d+(개|입|봉|팩|병|캔|매|스틱)(입)?$")


UPSERT_SQL = """
insert into collected_products
  (source, source_ref, raw, brand, name, size, category, barcode,
   ingredients_raw, confidence, stage)
values
  (%(source)s, %(source_ref)s, %(raw)s, %(brand)s, %(name)s, %(size)s,
   %(category)s, %(barcode)s, %(ingredients_raw)s, %(confidence)s, 'parsed')
on conflict (source, source_ref) do update set
  raw = excluded.raw,
  brand = excluded.brand,
  name = excluded.name,
  size = excluded.size,
  category = excluded.category,
  barcode = excluded.barcode,
  ingredients_raw = excluded.ingredients_raw,
  confidence = excluded.confidence,
  stage = 'parsed'
where collected_products.stage in ('raw', 'parsed')
  -- 사람이 검수한 행은 재적재에서 보존 (Data Desk 편집 no-clobber)
  and collected_products.reviewed_at is null
"""


def upsert_parsed(conn: psycopg.Connection, rows: list[dict]) -> None:
    """정제 결과를 stage='parsed'로 upsert.

    이미 tokenized 이상으로 진행된 행은 건드리지 않는다 — 재추출이 하류 산출을
    조용히 무효화하지 않도록. 그런 행을 갱신하려면 stage를 먼저 되돌릴 것.
    """
    with conn.cursor() as cur:
        cur.executemany(UPSERT_SQL, [{**r, "raw": json.dumps(r["raw"], ensure_ascii=False)} for r in rows])
