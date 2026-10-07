-- 0019: product_masters 유일키에 상품명 포함 — 원재료 표기가 같은 별개 상품 분리
--
-- 0015 는 master 를 brand + ingredients_raw (ingredients_hash) 로 유일하게 했다. 그래서
-- 원재료 표기가 같은 맛/종류 다른 상품(카누 캡슐 "볶은커피 100%", 티즐제로 오디/오미자 등)은
-- master 를 하나밖에 가질 수 없어, 승격이 "그룹 내 name 불일치" 로 영구 보류됐다.
--
-- 유일키를 brand + name + ingredients_raw (master_key) 로 바꾼다.
--   - 같은 상품명(용량은 clean_product_name 이 떼어냄)의 포장/용량 변형 → master 1개 + 바코드 N개 (기존과 동일)
--   - 상품명이 다른 상품 → 원재료 표기가 같아도 master 분리
-- ingredients_hash 는 운영 갱신·조회 호환을 위해 컬럼은 그대로 두고 유일 인덱스만 일반 인덱스로 내린다.
-- 기존 행은 ingredients_hash 가 유일했으므로 master_key 도 자동으로 유일 — 데이터 변경 없음.

alter table public.product_masters
  add column master_key text
  generated always as (md5(brand || '|' || name || '|' || ingredients_raw)) stored;

create unique index product_masters_master_key_idx
  on public.product_masters (master_key);

drop index public.product_masters_ingredients_hash_idx;
create index product_masters_ingredients_hash_idx
  on public.product_masters (ingredients_hash);

-- 업로드 RPC 를 새 유일키로. 본문은 0016 과 같고 conflict target·verified 조회 키만 바뀐다.
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
begin
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
