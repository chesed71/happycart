-- HappyCart: verdict 에서 'insufficient' 상태 완전 제거.
--
-- 배경: 원재료 정보가 없는 제품은 판정 대상이 아니므로 products 에 적재하지 않는다.
-- 앱/룰 엔진은 okay / not_okay 두 상태만 사용한다. 빈 원재료 토큰은 룰 패키지
-- (computeVerdict) 에서 ArgumentError 로 거절된다.
-- 현재 DB 에 insufficient 행이 0건이라 데이터 이전은 불필요.

-- 1. insufficient 전제 CHECK 제거.
--    타입 교체보다 먼저 — 이 제약식이 'insufficient' 리터럴에 의존하므로,
--    enum 에서 라벨이 사라지기 전에 떼어내야 한다.
alter table public.products
  drop constraint if exists products_insufficient_requires_empty_tokens;

-- 2. 모든 제품은 판정 가능해야 한다 — 원재료 토큰이 비어있으면 적재 불가.
alter table public.products
  add constraint products_requires_ingredient_tokens
    check (coalesce(array_length(ingredients_tokens, 1), 0) >= 1);

-- 3. verdict 를 enum 리터럴과 비교하는 CHECK 들을 타입 교체 전에 떼어낸다.
--    (이 제약식의 'okay'/'not_okay' 리터럴이 구 enum 타입에 바인딩돼 있어,
--     컬럼 타입을 바꾸면 신/구 enum 간 비교 연산자가 없어 실패한다.)
alter table public.products
  drop constraint if exists products_not_okay_requires_bad_match,
  drop constraint if exists products_okay_requires_no_bad_match;

-- 4. verdict_enum 에서 'insufficient' 라벨 제거.
--    Postgres 는 enum 값 DROP 을 지원하지 않으므로 rename → 재생성 → 컬럼 교체.
--    products.verdict 만 이 타입을 참조한다 (lookup_product 는 text 로 반환).
alter type public.verdict_enum rename to verdict_enum_old;
create type public.verdict_enum as enum ('okay', 'not_okay');
alter table public.products
  alter column verdict type public.verdict_enum
  using verdict::text::public.verdict_enum;
drop type public.verdict_enum_old;

-- 5. 떼어냈던 CHECK 들을 신 enum 기준으로 다시 붙인다 (0001 과 동일 정의).
alter table public.products
  add constraint products_not_okay_requires_bad_match
    check (verdict <> 'not_okay' or array_length(bad_ingredients_detected, 1) >= 1),
  add constraint products_okay_requires_no_bad_match
    check (verdict <> 'okay' or coalesce(array_length(bad_ingredients_detected, 1), 0) = 0);

-- 6. scan_events: insufficient 을 event_type / verdict 화이트리스트에서 제거.
alter table public.scan_events
  drop constraint if exists scan_events_event_type_check,
  drop constraint if exists scan_events_verdict_check;
alter table public.scan_events
  add constraint scan_events_event_type_check
    check (event_type in ('scan_success', 'not_found', 'network_error')),
  add constraint scan_events_verdict_check
    check (verdict is null or verdict in ('okay', 'not_okay'));

-- 7. log_scan_event RPC — 본문 화이트리스트에서 insufficient 제거 (0004 재정의).
create or replace function public.log_scan_event(
  p_event_type text,
  p_barcode_format text,
  p_verdict text,
  p_scan_latency_ms int,
  p_app_version text,
  p_platform text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if p_event_type is null or p_event_type not in (
    'scan_success', 'not_found', 'network_error'
  ) then
    raise exception 'invalid event_type: %', p_event_type
      using errcode = '22023';
  end if;

  if p_barcode_format is null or p_barcode_format not in ('EAN-13', 'EAN-8') then
    raise exception 'invalid barcode_format: %', p_barcode_format
      using errcode = '22023';
  end if;

  if p_verdict is not null and p_verdict not in ('okay', 'not_okay') then
    raise exception 'invalid verdict: %', p_verdict
      using errcode = '22023';
  end if;

  if p_scan_latency_ms is null
    or p_scan_latency_ms < 0
    or p_scan_latency_ms > 60000 then
    raise exception 'invalid scan_latency_ms: %', p_scan_latency_ms
      using errcode = '22023';
  end if;

  if p_app_version is null
    or length(p_app_version) > 32
    or p_app_version !~ '^\d+\.\d+\.\d+(\+\d+)?$' then
    raise exception 'invalid app_version: %', p_app_version
      using errcode = '22023';
  end if;

  if p_platform is null or p_platform not in ('ios', 'android') then
    raise exception 'invalid platform: %', p_platform
      using errcode = '22023';
  end if;

  insert into public.scan_events (
    event_type,
    barcode_format,
    verdict,
    scan_latency_ms,
    app_version,
    platform
  ) values (
    p_event_type,
    p_barcode_format,
    p_verdict,
    p_scan_latency_ms,
    p_app_version,
    p_platform
  );
end;
$$;

revoke all on function public.log_scan_event(text, text, text, int, text, text) from public;
grant execute on function public.log_scan_event(text, text, text, int, text, text) to anon, authenticated;
