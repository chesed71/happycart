-- 승격분 업로드용 RPC — master upsert(verified 가드) + barcode 연결을 한 트랜잭션에서.
--
-- 업로드 도구(pipeline/upload_prod.py)가 REST(service_role)로 호출한다. 직접 PATCH
-- 대신 이 함수로만 쓰게 해서:
--   - verified 가드를 변경문에 박는다 (read-then-write 경쟁 제거)
--   - master + barcode 를 한 함수=한 트랜잭션으로 (부분 적용 방지)
-- 운영 스키마 패턴(lookup_product/log_pending_product)과 동일하게 SECURITY DEFINER.
--
-- 입력:
--   p_master  jsonb : product_masters 컬럼 (brand,name,category,ingredients_raw,
--                     ingredients_tokens,bad/good/reason 배열,verdict,rule_version,
--                     computed_at,source,source_url,source_checked_at,verified_status)
--   p_barcodes jsonb : [{barcode,size,image_url,image_source_url}, ...]
-- 반환 jsonb:
--   {master_id, master_status: inserted|updated|verified_held,
--    barcodes: [{barcode, status: inserted|exists|conflict|held}]}

create or replace function public.upload_promoted_product(p_master jsonb, p_barcodes jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_hash text;
  v_id uuid;
  v_verified boolean;
  v_status text;
  v_results jsonb := '[]'::jsonb;
  v_bc jsonb;
  v_owner uuid;
  v_bcstat text;
  v_held boolean := false;
begin
  v_hash := md5((p_master->>'brand') || '|' || (p_master->>'ingredients_raw'));

  -- 행 잠금으로 GET↔변경 경쟁 차단
  select id, (verified_status = 'verified') into v_id, v_verified
  from public.product_masters where ingredients_hash = v_hash for update;

  if v_id is null then
    insert into public.product_masters (
      brand, name, category, ingredients_raw, ingredients_tokens,
      bad_ingredients_detected, good_ingredients_detected, verdict_reason_codes,
      verdict, rule_version, computed_at, source, source_url, source_checked_at, verified_status)
    values (
      p_master->>'brand', p_master->>'name', p_master->>'category', p_master->>'ingredients_raw',
      coalesce(array(select jsonb_array_elements_text(p_master->'ingredients_tokens')), '{}'),
      coalesce(array(select jsonb_array_elements_text(p_master->'bad_ingredients_detected')), '{}'),
      coalesce(array(select jsonb_array_elements_text(p_master->'good_ingredients_detected')), '{}'),
      coalesce(array(select jsonb_array_elements_text(p_master->'verdict_reason_codes')), '{}'),
      (p_master->>'verdict')::public.verdict_enum, p_master->>'rule_version',
      (p_master->>'computed_at')::timestamptz, p_master->>'source', p_master->>'source_url',
      (p_master->>'source_checked_at')::timestamptz,
      coalesce((p_master->>'verified_status')::public.verified_status_enum, 'unverified'))
    returning id into v_id;
    v_status := 'inserted';
  elsif v_verified then
    -- verified master 는 덮지 않고 barcode 연결도 보류 (즉시 노출 방지)
    return jsonb_build_object('master_id', v_id, 'master_status', 'verified_held',
                             'barcodes', '[]'::jsonb);
  else
    update public.product_masters set
      brand = p_master->>'brand', name = p_master->>'name', category = p_master->>'category',
      ingredients_raw = p_master->>'ingredients_raw',
      ingredients_tokens = coalesce(array(select jsonb_array_elements_text(p_master->'ingredients_tokens')), '{}'),
      bad_ingredients_detected = coalesce(array(select jsonb_array_elements_text(p_master->'bad_ingredients_detected')), '{}'),
      good_ingredients_detected = coalesce(array(select jsonb_array_elements_text(p_master->'good_ingredients_detected')), '{}'),
      verdict_reason_codes = coalesce(array(select jsonb_array_elements_text(p_master->'verdict_reason_codes')), '{}'),
      verdict = (p_master->>'verdict')::public.verdict_enum, rule_version = p_master->>'rule_version',
      computed_at = (p_master->>'computed_at')::timestamptz, source = p_master->>'source',
      source_url = p_master->>'source_url', source_checked_at = (p_master->>'source_checked_at')::timestamptz,
      updated_at = now()
    where id = v_id;
    v_status := 'updated';
  end if;

  for v_bc in select jsonb_array_elements(p_barcodes) loop
    select master_id into v_owner from public.product_barcodes
    where barcode = v_bc->>'barcode' for update;
    if v_owner is null then
      insert into public.product_barcodes (barcode, master_id, size, image_url, image_source_url)
      values (v_bc->>'barcode', v_id, v_bc->>'size', v_bc->>'image_url', v_bc->>'image_source_url');
      v_bcstat := 'inserted';
    elsif v_owner = v_id then
      v_bcstat := 'exists';
    else
      v_bcstat := 'conflict';  -- 운영에서 다른 master 소속 — 연결하지 않음
    end if;
    v_results := v_results || jsonb_build_object('barcode', v_bc->>'barcode', 'status', v_bcstat);
  end loop;

  return jsonb_build_object('master_id', v_id, 'master_status', v_status, 'barcodes', v_results);
end;
$$;

revoke all on function public.upload_promoted_product(jsonb, jsonb) from public;
grant execute on function public.upload_promoted_product(jsonb, jsonb) to service_role;
