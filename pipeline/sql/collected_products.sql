-- 수집용 테이블 — 로컬 전용. 운영 Supabase에 배포하지 않는다 (supabase/migrations 금지).
-- 크롤링 데이터의 적재·정제·판정·승격 추적을 한 테이블에서 stage 기반으로 관리한다.
-- 참고: docs/superpowers/specs/2026-06-11-local-db-data-ingestion-plan.md §3.5
--
-- 적용 순서: 0014 이후 (promoted_master_id FK가 product_masters를 참조).
-- pipeline/bootstrap_local.sh가 순서를 보장한다.

create table if not exists public.collected_products (
  -- 식별
  id uuid primary key default gen_random_uuid(),
  source text not null check (source in ('coupang', 'kakamuka')),
  source_ref text not null,

  -- 원본: 적재 시점의 소스 레코드 병합 스냅샷 (디버깅·재파싱용 — 조회 1차 소스 아님)
  raw jsonb not null,

  -- 정제
  brand text,
  name text,
  size text,
  category text,
  barcode text check (barcode is null or barcode ~ '^[0-9]{8}$' or barcode ~ '^[0-9]{13}$'),
  ingredients_raw text,
  confidence text check (confidence is null or confidence in ('low', 'medium', 'high')),

  -- 산출 (룰 엔진)
  ingredients_tokens text[],
  verdict public.verdict_enum,
  bad_ingredients_detected text[],
  good_ingredients_detected text[],
  verdict_reason_codes text[],
  rule_version text,
  computed_at timestamptz,

  -- 보강 (매칭)
  matched_ref text,          -- 쿠팡↔kakamuka 매칭 상대 ('source:ref' 형식)
  image_path text,           -- 로컬 정리본 경로 (work/images/products/<barcode>.jpg)

  -- 상태
  stage text not null default 'raw'
    check (stage in ('raw', 'parsed', 'tokenized', 'judged', 'promoted', 'conflict', 'rejected')),
  conflict_reason text,

  -- 승격
  promoted_master_id uuid references public.product_masters (id),
  promoted_at timestamptz,
  prod_master_id uuid,       -- 운영 업로드 후 반환된 운영 master id (로컬↔운영 영속 매핑)

  -- 검수 (Data Desk 원재료 검수 — 2026-06-16-datadesk-collected-products-plan.md)
  review_decision text check (review_decision in ('verified', 'needs_fix', 'skip')),
  review_note text,
  reviewed_at timestamptz,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  unique (source, source_ref)  -- 재실행 멱등 upsert 키
);

create index if not exists collected_products_stage_idx on public.collected_products (stage);
create index if not exists collected_products_barcode_idx on public.collected_products (barcode);

drop trigger if exists collected_products_updated_at on public.collected_products;
create trigger collected_products_updated_at
  before update on public.collected_products
  for each row
  execute function public.tg_set_updated_at();
