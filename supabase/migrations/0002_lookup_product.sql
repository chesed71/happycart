-- HappyCart MVP: lookup_product RPC.
-- SECURITY DEFINER lets anon callers read verified products without granting
-- table-level access. RLS on public.products remains default-deny.
-- 스펙 §4.2 참조.

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
  source_checked_at timestamptz
)
language sql
stable
security definer
set search_path = ''
as $$
  select
    p.barcode,
    p.brand,
    p.name,
    p.size,
    p.category,
    p.verdict::text,
    p.bad_ingredients_detected,
    p.good_ingredients_detected,
    p.verdict_reason_codes,
    p.rule_version,
    p.computed_at,
    p.source_checked_at
  from public.products p
  where p.barcode = p_barcode
    and p.verified_status = 'verified';
$$;

revoke all on function public.lookup_product(text) from public;
grant execute on function public.lookup_product(text) to anon, authenticated;
