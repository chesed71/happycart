-- Expose product images through lookup_product and attach the Coupang seed image.

update public.products
set
  image_url = $hc$https://thumbnail.coupangcdn.com/thumbnails/remote/492x492ex/image/vendor_inventory/141a/7da8f732c8b00d3d7cbae38172d58d26ba57acac816765093871d3439a30.jpg$hc$,
  verified_status = $hc$verified$hc$::public.verified_status_enum
where barcode = $hc$8809990172030$hc$;

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
    p.source_checked_at,
    p.image_url
  from public.products p
  where p.barcode = p_barcode
    and p.verified_status = 'verified';
$$;

revoke all on function public.lookup_product(text) from public;
grant execute on function public.lookup_product(text) to anon, authenticated;
