-- HappyCart MVP: products table — ingredient-based clean-eating verdict.
--
-- 스펙 §4.1 참조. EatSafe와 달리 영양 수치 컬럼은 두지 않고, 원재료 토큰과
-- 룰 패키지가 산출한 매칭 결과(canonical key, reason code)만 보관한다.
-- RLS default-deny — anon/authenticated 직접 접근 불가. lookup_product RPC 경유.

create extension if not exists pgcrypto;

create type public.verdict_enum as enum ('okay', 'not_okay', 'insufficient');
create type public.verified_status_enum as enum ('unverified', 'verified', 'needs_review');

create table public.products (
  id uuid primary key default gen_random_uuid(),
  barcode text not null unique,
  brand text not null,
  name text not null,
  size text not null,
  category text,

  -- 원재료 원본 (라벨 그대로) — RPC 응답에는 노출하지 않음.
  ingredients_raw text not null,
  -- 정규화된 원재료 토큰 — 룰 매칭 입력. 비어있으면 verdict=insufficient.
  ingredients_tokens text[] not null default '{}',

  -- 룰 산출 결과 (시드 파이프라인이 happycart_rules 패키지로 계산).
  bad_ingredients_detected text[] not null default '{}',
  good_ingredients_detected text[] not null default '{}',
  verdict_reason_codes text[] not null default '{}',
  verdict public.verdict_enum not null,
  rule_version text not null,
  computed_at timestamptz not null,

  source text not null,
  source_url text,
  source_checked_at timestamptz not null,
  label_version text,
  verified_status public.verified_status_enum not null default 'unverified',
  image_url text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  -- 바코드 형식 검증 (EAN-13 또는 EAN-8). 매니저 파이프라인도 동일 검증.
  constraint products_barcode_format
    check (barcode ~ '^[0-9]{8}$' or barcode ~ '^[0-9]{13}$'),
  -- verdict가 not_okay 이면 bad_ingredients_detected 가 비어있을 수 없다.
  constraint products_not_okay_requires_bad_match
    check (verdict <> 'not_okay' or array_length(bad_ingredients_detected, 1) >= 1),
  -- verdict가 okay 이면 bad_ingredients_detected 는 비어있어야 한다.
  constraint products_okay_requires_no_bad_match
    check (verdict <> 'okay' or coalesce(array_length(bad_ingredients_detected, 1), 0) = 0),
  -- verdict가 insufficient 이면 ingredients_tokens 가 비어있어야 한다 (룰 입력 부족 신호).
  constraint products_insufficient_requires_empty_tokens
    check (verdict <> 'insufficient' or coalesce(array_length(ingredients_tokens, 1), 0) = 0)
);

create index products_verdict_idx on public.products (verdict);

create or replace function public.tg_set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create trigger products_updated_at
  before update on public.products
  for each row
  execute function public.tg_set_updated_at();

alter table public.products enable row level security;
-- No policies defined: RLS enabled + zero policies = default-deny for anon &
-- authenticated. Only service_role bypasses RLS. lookup_product RPC (0002) is
-- the sole public read path.
