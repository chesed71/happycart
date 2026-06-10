-- HappyCart: pending_products — 앱에서 스캔됐지만 DB에 없는 미등록 상품 적재.
--
-- Flutter 앱이 lookup_product 결과가 0건일 때 log_pending_product RPC를 호출한다.
-- 같은 바코드가 여러 번 스캔되면 scan_count를 올리고 last_scanned_at을 갱신한다.
-- Data Desk SvelteKit 앱이 service_role 키로 이 테이블을 읽어 상품을 등록한다.

create type public.pending_status_enum as enum ('pending', 'registered', 'ignored');

create table public.pending_products (
  id               uuid primary key default gen_random_uuid(),
  barcode          text not null unique,
  scan_count       int  not null default 1,
  first_scanned_at timestamptz not null default now(),
  last_scanned_at  timestamptz not null default now(),
  status           public.pending_status_enum not null default 'pending',
  -- Data Desk에서 채워넣는 필드
  product_name     text,
  notes            text,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),

  constraint pending_products_barcode_format
    check (barcode ~ '^[0-9]{8}$' or barcode ~ '^[0-9]{13}$')
);

create index pending_products_status_idx on public.pending_products (status);
create index pending_products_last_scanned_idx on public.pending_products (last_scanned_at desc);

create trigger pending_products_updated_at
  before update on public.pending_products
  for each row
  execute function public.tg_set_updated_at();

alter table public.pending_products enable row level security;
-- service_role은 RLS 우회 — Data Desk는 service_role 키로 직접 접근.
-- anon/authenticated는 log_pending_product RPC 경유만 허용.

-- ── RPC: log_pending_product ──────────────────────────────────────────────────
-- Flutter 앱 호출용. 바코드가 이미 products 테이블에 있으면 아무것도 하지 않는다.
-- 없으면 pending_products에 upsert (중복 스캔 시 카운트 증가).

create function public.log_pending_product(p_barcode text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  -- 이미 등록된 상품이면 무시
  if exists (
    select 1 from public.products where barcode = p_barcode
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
