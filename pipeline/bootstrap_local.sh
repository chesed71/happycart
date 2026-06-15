#!/usr/bin/env bash
# 로컬 DB를 처음부터 재구성한다. 적용 순서 의존성을 한 곳에 캡슐화:
#   compat → 마이그레이션(시드 포함, 0011 storage만 제외) → [선택 dump] → 0014 → collected_products
#
# 운영 products 베이스라인은 시드 마이그레이션(0005~0009)이 그대로 재현한다 —
# Data Desk가 직접 등록한 상품이 없음을 확인했으므로 dump 불필요 (2026-06-16).
# 런타임 데이터(pending_products, scan_events)만 마이그레이션에 없으나 로컬 작업엔 무관.
#
# 사용:
#   pipeline/bootstrap_local.sh                  # 시드 = 운영 베이스라인 (기본)
#   pipeline/bootstrap_local.sh extra.sql        # 시드 외 추가 데이터가 생기면 선택 복원
#
# 참고: docs/superpowers/specs/2026-06-11-local-db-data-ingestion-plan.md §3
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
[[ -f "$SCRIPT_DIR/.env" ]] && set -a && . "$SCRIPT_DIR/.env" && set +a
CONTAINER="${HAPPYCART_PG_CONTAINER:-happycart-pg}"
DB="${HAPPYCART_PG_DB:-happycart}"
PG_USER="${HAPPYCART_PG_USER:-postgres}"
DUMP_FILE="${1:-}"

psql_db() { docker exec -i "$CONTAINER" psql -v ON_ERROR_STOP=1 -U "$PG_USER" -d "$DB" -q; }

echo "==> recreate database $DB"
docker exec "$CONTAINER" psql -U "$PG_USER" -q \
  -c "drop database if exists $DB;" -c "create database $DB;"

echo "==> compat + migrations (seeds included, skip 0011 storage + 0014 split)"
psql_db < "$REPO_ROOT/supabase/local/00_compat.sql"
for f in "$REPO_ROOT"/supabase/migrations/*.sql; do
  base="$(basename "$f")"
  # 0011: storage 스키마 없음 (단독 postgres). 0014: 아래에서 별도 적용.
  if [[ "$base" =~ ^(0011|0014)_ ]]; then
    continue
  fi
  echo "    $base"
  psql_db < "$f"
done

if [[ -n "$DUMP_FILE" ]]; then
  echo "==> restore extra data: $DUMP_FILE"
  psql_db < "$DUMP_FILE"
fi

echo "==> 0014 split"
psql_db < "$REPO_ROOT"/supabase/migrations/0014_*.sql

echo "==> collected_products (local-only)"
psql_db < "$REPO_ROOT/pipeline/sql/collected_products.sql"

echo "==> review RPC + datadesk_review role (local-only)"
psql_db < "$REPO_ROOT/pipeline/sql/review_rpc.sql"

echo "==> summary"
docker exec "$CONTAINER" psql -U "$PG_USER" -d "$DB" -c \
  "select 'products(frozen)' t, count(*) from products
   union all select 'product_masters', count(*) from product_masters
   union all select 'product_barcodes', count(*) from product_barcodes
   union all select 'pending_products', count(*) from pending_products
   union all select 'collected_products', count(*) from collected_products;"
echo "done."
