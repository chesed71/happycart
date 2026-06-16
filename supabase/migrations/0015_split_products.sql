-- HappyCart: products 단일 테이블을 product_masters / product_barcodes 로 분리.
--
-- 배경: 원재료·판정이 동일한 변형 상품(바코드·중량·번들만 다름)을 중복 없이
-- 관리한다. 스펙: docs/superpowers/specs/2026-06-11-products-table-split-plan.md,
-- docs/superpowers/specs/2026-06-11-local-db-data-ingestion-plan.md §3.4
--
-- 이 마이그레이션이 하는 일:
--   1. product_masters / product_barcodes 생성 (제약·인덱스·트리거·RLS)
--   2. 기존 products 행 이전 — brand + ingredients_raw 완전 일치 그룹은 하나의 master 로
--   3. lookup_product 를 조인 버전으로 재작성 (반환 형태는 기존과 동일)
--   4. log_pending_product 존재 확인을 product_barcodes 로 변경
--   5. 구 products 쓰기 동결 (0016 에서 drop 전까지 읽기 전용)
--   6. 이전 검증 assert
--
-- products 테이블 자체는 0016 에서 drop 한다 (롤백 유예).

-- ── 1. product_masters ───────────────────────────────────────────────────────

create table public.product_masters (
  id uuid primary key default gen_random_uuid(),
  brand text not null,
  name text not null,
  category text,

  -- 원재료 원본 (라벨 그대로) — RPC 응답에는 노출하지 않음.
  ingredients_raw text not null,
  ingredients_tokens text[] not null default '{}',

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

  -- 신규 master 의 초기 dedupe·upsert conflict target. 영속 식별자는 id (uuid).
  -- 내용 파생값이므로 brand/원문 교정 시 바뀐다 — 교정은 id 기준 update 로.
  ingredients_hash text generated always as (md5(brand || '|' || ingredients_raw)) stored,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint masters_not_okay_requires_bad_match
    check (verdict <> 'not_okay' or array_length(bad_ingredients_detected, 1) >= 1),
  constraint masters_okay_requires_no_bad_match
    check (verdict <> 'okay' or coalesce(array_length(bad_ingredients_detected, 1), 0) = 0)
);
-- 주: verdict 가 okay/not_okay 두 값뿐이므로 (0014 에서 insufficient 제거),
-- 빈 토큰을 막는 별도 제약은 두지 않는다 — 룰 엔진(computeVerdict 가 빈 토큰에
-- ArgumentError)과 업로드 파이프라인(원재료 필수)이 상류에서 이미 보장한다.

create unique index product_masters_ingredients_hash_idx
  on public.product_masters (ingredients_hash);
create index product_masters_verdict_idx on public.product_masters (verdict);
create index product_masters_verified_status_idx on public.product_masters (verified_status);

create trigger product_masters_updated_at
  before update on public.product_masters
  for each row
  execute function public.tg_set_updated_at();

alter table public.product_masters enable row level security;
-- 정책 0개 = default-deny. anon/authenticated 는 RPC 경유만, service_role 만 직접 접근.

-- ── 2. product_barcodes ──────────────────────────────────────────────────────

create table public.product_barcodes (
  barcode text primary key,
  master_id uuid not null references public.product_masters (id) on delete restrict,
  size text not null,
  -- 변형마다 패키지 사진이 다를 수 있어 이미지는 바코드 쪽에 둔다.
  image_url text,
  image_source_url text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint product_barcodes_format
    check (barcode ~ '^[0-9]{8}$' or barcode ~ '^[0-9]{13}$')
);

create index product_barcodes_master_id_idx on public.product_barcodes (master_id);

create trigger product_barcodes_updated_at
  before update on public.product_barcodes
  for each row
  execute function public.tg_set_updated_at();

alter table public.product_barcodes enable row level security;

-- ── 3. 데이터 이전 ────────────────────────────────────────────────────────────
-- 그룹핑: brand + ingredients_raw 완전 일치 = 같은 master.
-- 대표 행: 그룹 내 created_at 이 가장 이른 행 (name/category/판정 등 공급).
--
-- verified_status 가 그룹 내에서 섞여 있으면 (한 변형은 verified, 다른 변형은
-- unverified 등) master 단위 상태로 합칠 수 없다 — 어느 쪽을 택해도 조용한
-- 노출 또는 조용한 숨김이 생긴다. 이 경우 마이그레이션을 실패시켜 수동 해소를
-- 강제한다 (로컬 dump 검증에서 먼저 걸러진다).

do $$
declare
  v_mixed bigint;
begin
  select count(*) into v_mixed from (
    select 1 from public.products
    group by brand, ingredients_raw
    having count(distinct verified_status) > 1
  ) g;
  if v_mixed > 0 then
    raise exception
      '0015 precheck failed: % group(s) mix verified_status — resolve manually before migrating (select brand, ingredients_raw from products group by 1,2 having count(distinct verified_status) > 1)',
      v_mixed;
  end if;
end;
$$;

insert into public.product_masters (
  brand, name, category,
  ingredients_raw, ingredients_tokens,
  bad_ingredients_detected, good_ingredients_detected, verdict_reason_codes,
  verdict, rule_version, computed_at,
  source, source_url, source_checked_at, label_version, verified_status,
  created_at
)
select
  rep.brand, rep.name, rep.category,
  rep.ingredients_raw, rep.ingredients_tokens,
  rep.bad_ingredients_detected, rep.good_ingredients_detected, rep.verdict_reason_codes,
  rep.verdict, rep.rule_version, rep.computed_at,
  rep.source, rep.source_url, rep.source_checked_at, rep.label_version,
  rep.verified_status,
  rep.created_at
from (
  select distinct on (brand, ingredients_raw) *
  from public.products
  order by brand, ingredients_raw, created_at, id
) rep;

insert into public.product_barcodes (
  barcode, master_id, size, image_url, image_source_url, created_at
)
select
  p.barcode, m.id, p.size, p.image_url, p.image_source_url, p.created_at
from public.products p
join public.product_masters m
  on m.ingredients_hash = md5(p.brand || '|' || p.ingredients_raw);

-- ── 4. lookup_product 재작성 (반환 컬럼·타입 기존과 동일) ─────────────────────

drop function if exists public.lookup_product(text);

create function public.lookup_product(p_barcode text)
returns table (
  barcode text,
  brand text,
  name text,
  size text,
  category text,
  verdict text,
  bad_ingredients_detected text[],
  good_ingredients_detected text[],
  verdict_reason_codes text[],
  rule_version text,
  computed_at timestamptz,
  source_checked_at timestamptz,
  image_url text
)
language sql
stable
security definer
set search_path = ''
as $$
  select
    b.barcode,
    m.brand,
    m.name,
    b.size,
    m.category,
    m.verdict::text,
    m.bad_ingredients_detected,
    m.good_ingredients_detected,
    m.verdict_reason_codes,
    m.rule_version,
    m.computed_at,
    m.source_checked_at,
    b.image_url
  from public.product_barcodes b
  join public.product_masters m on m.id = b.master_id
  where b.barcode = p_barcode
    and m.verified_status = 'verified';
$$;

revoke all on function public.lookup_product(text) from public;
grant execute on function public.lookup_product(text) to anon, authenticated;

-- ── 5. log_pending_product 존재 확인 대상 변경 ────────────────────────────────

create or replace function public.log_pending_product(p_barcode text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  -- 이미 등록된 상품(바코드 변형 포함)이면 무시
  if exists (
    select 1 from public.product_barcodes where barcode = p_barcode
  ) then
    return;
  end if;

  insert into public.pending_products (barcode, scan_count, first_scanned_at, last_scanned_at)
  values (p_barcode, 1, now(), now())
  on conflict (barcode) do update
    set scan_count      = public.pending_products.scan_count + 1,
        last_scanned_at = now(),
        updated_at      = now()
  where public.pending_products.status = 'pending';
end;
$$;

revoke all on function public.log_pending_product(text) from public;
grant execute on function public.log_pending_product(text) to anon, authenticated;

-- ── 6. 구 products 쓰기 동결 ──────────────────────────────────────────────────
-- service_role 은 RLS 를 우회하므로, 구 경로 도구의 실수 기록은 트리거로만 막을
-- 수 있다. 읽기는 허용 (롤백 대조용). 0016 에서 테이블과 함께 제거.

create function public.tg_products_frozen()
returns trigger
language plpgsql
as $$
begin
  raise exception 'products is frozen since 0015 — write to product_masters / product_barcodes instead';
end;
$$;

create trigger products_frozen
  before insert or update or delete on public.products
  for each row
  execute function public.tg_products_frozen();

-- ── 7. 이전 검증 ─────────────────────────────────────────────────────────────

do $$
declare
  v_products bigint;
  v_barcodes bigint;
  v_masters bigint;
  v_groups bigint;
begin
  select count(*) into v_products from public.products;
  select count(*) into v_barcodes from public.product_barcodes;
  select count(*) into v_masters from public.product_masters;
  select count(distinct (brand, ingredients_raw)) into v_groups from public.products;

  if v_barcodes <> v_products then
    raise exception '0015 verify failed: barcodes(%) <> products(%)', v_barcodes, v_products;
  end if;
  if v_masters <> v_groups then
    raise exception '0015 verify failed: masters(%) <> distinct groups(%)', v_masters, v_groups;
  end if;
end;
$$;
