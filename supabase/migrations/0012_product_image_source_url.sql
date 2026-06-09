-- Keep the original vendor image URL used to create each stored product image.
-- This is internal provenance; lookup_product continues to expose only image_url.

alter table public.products
  add column if not exists image_source_url text;

comment on column public.products.image_source_url is
  'Original vendor/CDN image URL used to create image_url. Internal; not exposed by lookup_product.';

update public.products
set image_source_url = $hc$https://thumbnail.coupangcdn.com/thumbnails/remote/492x492ex/image/vendor_inventory/141a/7da8f732c8b00d3d7cbae38172d58d26ba57acac816765093871d3439a30.jpg$hc$
where barcode = $hc$8809990172030$hc$;
