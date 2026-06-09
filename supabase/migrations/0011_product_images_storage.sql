-- Store product hero images in Supabase Storage instead of linking to vendor CDN.

insert into storage.buckets (
  id, name, public, file_size_limit, allowed_mime_types
) values (
  'product-images',
  'product-images',
  true,
  524288,
  array['image/jpeg']::text[]
) on conflict (id) do update set
  public = excluded.public,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "Public product images are readable" on storage.objects;
create policy "Public product images are readable"
on storage.objects
for select
to public
using (bucket_id = 'product-images');

update public.products
set image_url = $hc$https://ftgsnvvskbadegswvjnp.supabase.co/storage/v1/object/public/product-images/products/8809990172030.jpg$hc$
where barcode = $hc$8809990172030$hc$;
