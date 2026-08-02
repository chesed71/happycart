-- 0017: lookup_product 에 ingredients_raw(라벨 원문 성분) 노출 추가
--
-- 앱 "전체 성분표 보기" 기능을 위해 product_masters.ingredients_raw 를 RPC
-- 응답에 포함한다. 0015 정의를 그대로 두고 반환 컬럼 끝에 ingredients_raw
-- 한 개만 추가한다 — 반환 컬럼 시그니처가 바뀌므로 drop 후 재생성한다.
-- (앱은 컬럼명 기준 매핑이라 위치는 무관하며, 구 클라이언트는 무시한다.)

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
  image_url text,
  ingredients_raw text
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
    b.image_url,
    m.ingredients_raw
  from public.product_barcodes b
  join public.product_masters m on m.id = b.master_id
  where b.barcode = p_barcode
    and m.verified_status = 'verified';
$$;

revoke all on function public.lookup_product(text) from public;
grant execute on function public.lookup_product(text) to anon, authenticated;
