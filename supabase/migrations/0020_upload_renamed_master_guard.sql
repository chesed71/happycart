-- 0020: upload_promoted_product — 운영에서 이름이 바뀐 기존 master 의 바코드가 섞이면 그룹째 보류
--
-- 0019 로 master 유일키에 name 이 들어가면서, 운영에서 이름을 교정한 master 는 로컬 이름과
-- master_key 가 달라 RPC 가 "새 master" 로 본다. 입력 바코드가 전부 기존 바코드면 conflict →
-- empty_held 로 정리되지만, 기존 바코드 B1 + 신규 바코드 B2 가 섞이면 B2 가 새 master 에 붙어
-- 같은 상품의 master 가 둘이 된다(Codex 리뷰 HIGH).
--
-- 입력 바코드 중 하나라도 "같은 brand+원재료(ingredients_hash)인데 master_key 가 다른" 기존
-- master 소속이면, 이름만 바뀐 같은 상품으로 보고 master·바코드를 하나도 쓰지 않고
-- renamed_held 로 반환한다(수동 확인 대상). 원재료가 다른 master 소속이면 기존처럼 바코드별 conflict.

create or replace function public.upload_promoted_product(p_master jsonb, p_barcodes jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
  v_inserted boolean;
  v_status text;
  v_results jsonb := '[]'::jsonb;
  v_bc jsonb;
  v_owner uuid;
  v_ins uuid;
  v_bcstat text;
  v_attached int := 0;
  v_renamed uuid;
begin
  -- 이름만 바뀐 같은 상품(같은 brand+원재료, 다른 master_key)이 입력 바코드를 이미 소유하면 그룹째 보류.
  select m.id into v_renamed
  from public.product_barcodes b
  join public.product_masters m on m.id = b.master_id
  where b.barcode in (select e->>'barcode' from jsonb_array_elements(p_barcodes) e)
    and m.ingredients_hash = md5((p_master->>'brand') || '|' || (p_master->>'ingredients_raw'))
    and m.master_key <> md5((p_master->>'brand') || '|' || (p_master->>'name') || '|'
                            || (p_master->>'ingredients_raw'))
  limit 1;
  if v_renamed is not null then
    return jsonb_build_object('master_id', v_renamed, 'master_status', 'renamed_held',
                             'barcodes', '[]'::jsonb);
  end if;

  -- master 진짜 upsert (verified 가드를 변경문에 박는다). conflict 행이 verified 면
  -- WHERE 가 false → 0 rows → RETURNING 비어 v_id NULL → verified_held.
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
  on conflict (master_key) do update set
    category = excluded.category,
    ingredients_tokens = excluded.ingredients_tokens,
    bad_ingredients_detected = excluded.bad_ingredients_detected,
    good_ingredients_detected = excluded.good_ingredients_detected,
    verdict_reason_codes = excluded.verdict_reason_codes,
    verdict = excluded.verdict, rule_version = excluded.rule_version,
    computed_at = excluded.computed_at, source = excluded.source,
    source_url = excluded.source_url, source_checked_at = excluded.source_checked_at,
    updated_at = now()
  where public.product_masters.verified_status <> 'verified'
  returning id, (xmax = 0) into v_id, v_inserted;

  if v_id is null then
    -- 기존 verified master — 덮지 않고 barcode 연결도 보류
    select id into v_id from public.product_masters
    where master_key = md5((p_master->>'brand') || '|' || (p_master->>'name') || '|'
                           || (p_master->>'ingredients_raw'));
    return jsonb_build_object('master_id', v_id, 'master_status', 'verified_held',
                             'barcodes', '[]'::jsonb);
  end if;
  v_status := case when v_inserted then 'inserted' else 'updated' end;

  for v_bc in select jsonb_array_elements(p_barcodes) loop
    insert into public.product_barcodes (barcode, master_id, size, image_url, image_source_url)
    values (v_bc->>'barcode', v_id, v_bc->>'size', v_bc->>'image_url', v_bc->>'image_source_url')
    on conflict (barcode) do nothing
    returning master_id into v_ins;
    if v_ins is not null then
      v_bcstat := 'inserted'; v_attached := v_attached + 1;
    else
      select master_id into v_owner from public.product_barcodes where barcode = v_bc->>'barcode';
      if v_owner = v_id then
        v_bcstat := 'exists'; v_attached := v_attached + 1;
      else
        v_bcstat := 'conflict';  -- 운영에서 다른 master 소속 — 연결 안 함
      end if;
    end if;
    v_results := v_results || jsonb_build_object('barcode', v_bc->>'barcode', 'status', v_bcstat);
  end loop;

  -- 신규로 만든 master인데 붙은 barcode가 없으면(전부 conflict) 빈 master 정리.
  if v_inserted and v_attached = 0 then
    delete from public.product_masters where id = v_id;
    return jsonb_build_object('master_id', null, 'master_status', 'empty_held', 'barcodes', v_results);
  end if;

  return jsonb_build_object('master_id', v_id, 'master_status', v_status, 'barcodes', v_results);
end;
$$;

revoke all on function public.upload_promoted_product(jsonb, jsonb) from public;
grant execute on function public.upload_promoted_product(jsonb, jsonb) to service_role;
