#!/usr/bin/env bash
# 로컬 DB를 처음부터 재구성한다. 적용 순서 의존성을 한 곳에 캡슐화:
#   compat → 마이그레이션(시드 포함, 0011 storage·0015 split 제외) → [선택 dump] → 0015 split → collected_products
#
# 운영 products 베이스라인은 시드 마이그레이션(0005~0009)이 그대로 재현한다 —
# Data Desk가 직접 등록한 상품이 없음을 확인했으므로 dump 불필요 (2026-06-16).
# 런타임 데이터(pending_products, scan_events)만 마이그레이션에 없으나 로컬 작업엔 무관.
#
# 사용:
#   pipeline/bootstrap_local.sh                  # 시드 = 운영 베이스라인 (기본)
#   pipeline/bootstrap_local.sh extra.sql        # 시드 외 추가 데이터가 생기면 선택 복원
#
# 안전장치: 대상 DB를 drop 하기 전에 BOOTSTRAP_CONFIRM_DB가 대상 DB 이름과 정확히 같아야 한다.
#   BOOTSTRAP_CONFIRM_DB=happycart pipeline/bootstrap_local.sh                 # 운영 LOCAL 재구성
#   HAPPYCART_PG_DB=happycart_test BOOTSTRAP_CONFIRM_DB=happycart_test pipeline/bootstrap_local.sh
# 호출자 환경의 HAPPYCART_PG_DB는 pipeline/.env 값보다 우선한다.
#
# 참고: docs/superpowers/specs/2026-06-11-local-db-data-ingestion-plan.md §3
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# .env가 호출자 환경의 대상 DB를 덮어쓰지 못하게 로딩 전에 저장했다가 복원한다.
CALLER_PG_DB="${HAPPYCART_PG_DB-}"
# shellcheck disable=SC1091
[[ -f "$SCRIPT_DIR/.env" ]] && set -a && . "$SCRIPT_DIR/.env" && set +a
[[ -n "$CALLER_PG_DB" ]] && HAPPYCART_PG_DB="$CALLER_PG_DB"
CONTAINER="${HAPPYCART_PG_CONTAINER:-happycart-pg}"
DB="${HAPPYCART_PG_DB:-happycart}"
PG_USER="${HAPPYCART_PG_USER:-postgres}"
DUMP_FILE="${1:-}"

psql_db() { docker exec -i "$CONTAINER" psql -v ON_ERROR_STOP=1 -U "$PG_USER" -d "$DB" -q; }

if [[ "${BOOTSTRAP_CONFIRM_DB-}" != "$DB" ]]; then
  echo "대상 DB($DB)와 BOOTSTRAP_CONFIRM_DB(${BOOTSTRAP_CONFIRM_DB-})가 다릅니다. 아무것도 지우지 않고 종료합니다." >&2
  exit 1
fi

echo "==> recreate database $DB"
docker exec "$CONTAINER" psql -U "$PG_USER" -q \
  -c "drop database if exists $DB;" -c "create database $DB;"

echo "==> compat + migrations (seeds included, skip 0011 storage + 0015 split)"
psql_db < "$REPO_ROOT/supabase/local/00_compat.sql"
for f in "$REPO_ROOT"/supabase/migrations/*.sql; do
  base="$(basename "$f")"
  # 0011: storage 스키마 없음 (단독 postgres). 0015 split·0016 upload RPC·0017 lookup·0018 save RPC·0019 master_key·
  # 0020 RPC 가드·0021 RPC 기존 master 불변·0022·0024: 아래에서 별도 적용 (0016·0019·0020이 0015의 product_masters에 의존).
  # 0021·0022는 0020 뒤에 적용해야 한다 — 순회에서 먼저 적용되면 뒤의 0020이 RPC를 구버전으로 덮는다.
  # 0014(insufficient 제거)는 products 스키마 변경이라 이 루프에서 정상 적용된다.
  if [[ "$base" =~ ^(0011|0015|0016|0017|0018|0019|0020|0021|0022|0024)_ ]]; then
    continue
  fi
  echo "    $base"
  psql_db < "$f"
done

if [[ -n "$DUMP_FILE" ]]; then
  echo "==> restore extra data: $DUMP_FILE"
  psql_db < "$DUMP_FILE"
fi

echo "==> 0015 split"
psql_db < "$REPO_ROOT"/supabase/migrations/0015_*.sql

echo "==> 0016 upload_promoted_product RPC"
psql_db < "$REPO_ROOT"/supabase/migrations/0016_*.sql

echo "==> 0017 lookup_product ingredients_raw (0015 뒤)"
psql_db < "$REPO_ROOT"/supabase/migrations/0017_*.sql

echo "==> 0018 save_service_product (product_barcodes 의존이라 0015 뒤)"
psql_db < "$REPO_ROOT"/supabase/migrations/0018_*.sql

echo "==> 0019 master_key (brand+name+ingredients 유일키)"
psql_db < "$REPO_ROOT"/supabase/migrations/0019_*.sql

echo "==> 0020 upload RPC renamed_held 가드"
psql_db < "$REPO_ROOT"/supabase/migrations/0020_*.sql

echo "==> 0021 upload RPC 기존 master 불변 (0020 뒤)"
psql_db < "$REPO_ROOT"/supabase/migrations/0021_*.sql

echo "==> 0022 approve_service_products (0015 product_masters 의존이라 0021 뒤)"
psql_db < "$REPO_ROOT"/supabase/migrations/0022_*.sql

echo "==> 0024 add_barcode_to_master (0015 product_masters 의존이라 0022 뒤)"
psql_db < "$REPO_ROOT"/supabase/migrations/0024_*.sql

echo "==> collected_products (local-only)"
psql_db < "$REPO_ROOT/pipeline/sql/collected_products.sql"

echo "==> review RPC + datadesk_review role (local-only)"
psql_db < "$REPO_ROOT/pipeline/sql/review_rpc.sql"

echo "==> upload_receipts (local-only)"
psql_db < "$REPO_ROOT/pipeline/sql/upload_receipts.sql"

echo "==> rollback function (local-only, no-op on fresh DB)"
psql_db < "$REPO_ROOT/pipeline/sql/rollback_ungated_promotions.sql"

echo "==> check upload_promoted_product 버전 (0021 이상) + approve_service_products (0022)"
if [[ "$(docker exec "$CONTAINER" psql -U "$PG_USER" -d "$DB" -tA -c \
      "select prosrc like '%review_held%' from pg_proc where oid = 'public.upload_promoted_product(jsonb, jsonb)'::regprocedure")" != "t" ]]; then
  echo "upload_promoted_product가 0021 버전이 아닙니다(review_held 없음)." >&2
  exit 1
fi
if [[ "$(docker exec "$CONTAINER" psql -U "$PG_USER" -d "$DB" -tA -c \
      "select public.upload_promoted_product_version()")" != "21" ]]; then
  echo "upload_promoted_product_version()이 없거나 21이 아닙니다." >&2
  exit 1
fi
if [[ "$(docker exec "$CONTAINER" psql -U "$PG_USER" -d "$DB" -tA -c \
      "select to_regprocedure('public.approve_service_products(jsonb)') is not null")" != "t" ]]; then
  echo "approve_service_products(jsonb)가 없습니다(0022 미적용)." >&2
  exit 1
fi

echo "==> summary"
docker exec "$CONTAINER" psql -U "$PG_USER" -d "$DB" -c \
  "select 'products(frozen)' t, count(*) from products
   union all select 'product_masters', count(*) from product_masters
   union all select 'product_barcodes', count(*) from product_barcodes
   union all select 'pending_products', count(*) from pending_products
   union all select 'collected_products', count(*) from collected_products;"
echo "done."
