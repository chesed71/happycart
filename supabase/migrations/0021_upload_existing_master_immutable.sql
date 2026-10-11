-- 0021: upload_promoted_product — 기존 unverified master 내용 불변·needs_review 보류·보류 시 기존 연결 반환
--
-- 0020 까지는 같은 master_key 의 운영 master 가 verified 가 아니면(unverified·needs_review) 분류·토큰·
-- 판정·룰 버전·출처 필드를 로컬 값으로 덮어써, 운영 데스크에서 사람이 고친 값이 사라졌다. 0021 부터:
--   - 운영 master 없음: 지금처럼 새로 만들고 바코드를 연결한다(inserted). 붙은 바코드가 없으면 empty_held.
--   - unverified: master 내용 컬럼은 하나도 바꾸지 않고 바코드만 연결한다(existing). 이 호출에서 새 바코드가
--     하나라도 inserted 되면 그 master 의 updated_at 만 현재 시각으로 갱신한다(노출 승인 토큰이 "본 뒤
--     바코드가 늘었음"을 감지하도록).
--   - needs_review: master·바코드 모두 쓰지 않고 보류(review_held).
--   - verified: 보류(verified_held).
--   - 이름만 바뀐 같은 상품: 보류(renamed_held), 판단은 0020 과 같다.
--   - 보류 세 경우(verified_held·review_held·renamed_held)는 master_id 에 보류된 그 master(renamed 면 이름이
--     바뀐 master)의 id 를, barcodes 에 입력 바코드 중 이미 그 master 소속인 것만 exists 로 담는다. 새 연결은
--     하지 않는다. "운영 커밋 → LOCAL 기록 전 멈춤 → 그사이 운영 상태 변경" 뒤 재실행해도 이미 된 연결이
--     LOCAL 에 기록되게 하기 위해서다.
--   - 결과값 updated 는 더 이상 나오지 않는다.
-- advisory lock·잠금 순서·바코드별 conflict·빈 master 정리는 0020 과 같다.
--
-- 배포 메모: 0021 적용 뒤 옛 upload_prod.py 가 돌아도 운영 master 내용을 덮지 않는다. 옛 코드는 master
-- 결과를 집계만 하고 prod_master_id 는 바코드 결과(inserted/exists)와 master id 로 기록하는데, 0021 은
-- existing 과 모든 보류 결과에서 이미 그 master 에 연결된 바코드를 exists 와 master id 로 돌려주므로 옛
-- 코드도 그 연결을 그대로 기록한다. 다만 옛 코드는 전부 다시 보내고 고정 이미지 경로를 덮어쓰며 영수증을
-- 남기지 않으므로, 배포 사이에는 업로드를 돌리지 않는다.
--
-- create or replace 라 다시 적용해도 결과가 같다.

create or replace function public.upload_promoted_product(p_master jsonb, p_barcodes jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_key text := md5((p_master->>'brand') || '|' || (p_master->>'name') || '|'
                    || (p_master->>'ingredients_raw'));
  v_id uuid;
  v_vstatus public.verified_status_enum;
  v_inserted boolean := false;
  v_status text;
  v_results jsonb := '[]'::jsonb;
  v_bc jsonb;
  v_owner uuid;
  v_ins uuid;
  v_bcstat text;
  v_attached int := 0;
  v_new_links int := 0;
  v_renamed uuid;
begin
  -- 같은 brand+원재료 업로드 직렬화(트랜잭션 종료 시 자동 해제). master_key 는 brand+원재료를 포함하므로
  -- 같은 master_key 의 insert 경쟁도 이 잠금으로 막힌다.
  perform pg_advisory_xact_lock(
    hashtextextended('upload_promoted_product|' || (p_master->>'brand') || '|'
                     || (p_master->>'ingredients_raw'), 0));

  -- 이 호출이 건드릴 기존 master(입력 바코드 소유 master + 같은 master_key 의 master)를 한 번에
  -- id 순서로 잠근다 — 판정 동안 이름·상태 변경과 직렬화하고, 원재료가 다른 업로드끼리 서로의
  -- master 를 엇갈려 잠가 생기는 데드락을 막는다(잠금 순서 고정).
  perform 1 from public.product_masters m
  where m.id in (
          select b.master_id from public.product_barcodes b
          where b.barcode in (select e->>'barcode' from jsonb_array_elements(p_barcodes) e))
     or m.master_key = v_key
  order by m.id
  for update;

  -- 이름만 바뀐 같은 상품(같은 brand+원재료, 다른 master_key)이 입력 바코드를 이미 소유하면 그룹째 보류.
  select m.id into v_renamed
  from public.product_barcodes b
  join public.product_masters m on m.id = b.master_id
  where b.barcode in (select e->>'barcode' from jsonb_array_elements(p_barcodes) e)
    and m.ingredients_hash = md5((p_master->>'brand') || '|' || (p_master->>'ingredients_raw'))
    and m.master_key <> v_key
  limit 1;

  if v_renamed is not null then
    v_id := v_renamed;
    v_status := 'renamed_held';
  else
    -- 같은 master_key 의 기존 master(위에서 이미 잠금).
    select id, verified_status into v_id, v_vstatus
    from public.product_masters where master_key = v_key;

    if v_id is null then
      -- 없을 때만 새로 만든다. advisory lock 밖의 경로(데스크 등)가 그사이 같은 master_key 를 커밋했으면
      -- do nothing → 다시 읽어 기존 master 로 분기한다.
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
      on conflict (master_key) do nothing
      returning id into v_id;

      if v_id is not null then
        v_inserted := true;
      else
        -- do nothing 뒤 이 재조회 사이에 그 행이 지워지면 v_id 가 NULL 로 남고, 아래 바코드 insert 가
        -- master_id NOT NULL 위반으로 실패해 호출 전체가 롤백된다(안전한 실패).
        select id, verified_status into v_id, v_vstatus
        from public.product_masters where master_key = v_key
        for update;
      end if;
    end if;

    v_status := case
      when v_inserted then 'inserted'
      when v_vstatus = 'verified' then 'verified_held'
      when v_vstatus = 'needs_review' then 'review_held'
      else 'existing'
    end;
  end if;

  -- 보류: master·바코드를 쓰지 않고, 입력 바코드 중 이미 그 master 소속인 것만 exists 로 돌려준다.
  if v_status in ('verified_held', 'review_held', 'renamed_held') then
    select coalesce(jsonb_agg(jsonb_build_object('barcode', e->>'barcode', 'status', 'exists') order by o),
                    '[]'::jsonb)
      into v_results
    from jsonb_array_elements(p_barcodes) with ordinality as t(e, o)
    where exists (select 1 from public.product_barcodes b
                  where b.barcode = e->>'barcode' and b.master_id = v_id);
    return jsonb_build_object('master_id', v_id, 'master_status', v_status, 'barcodes', v_results);
  end if;

  for v_bc in select jsonb_array_elements(p_barcodes) loop
    insert into public.product_barcodes (barcode, master_id, size, image_url, image_source_url)
    values (v_bc->>'barcode', v_id, v_bc->>'size', v_bc->>'image_url', v_bc->>'image_source_url')
    on conflict (barcode) do nothing
    returning master_id into v_ins;
    if v_ins is not null then
      v_bcstat := 'inserted'; v_attached := v_attached + 1; v_new_links := v_new_links + 1;
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

  -- 기존 unverified master 에 새 바코드가 붙었으면 updated_at 만 갱신(내용 컬럼은 그대로).
  -- 0015 트리거도 now() 를 넣지만, 트리거에 기대지 않고 명시적으로 쓴다.
  if not v_inserted and v_new_links > 0 then
    update public.product_masters set updated_at = now() where id = v_id;
  end if;

  return jsonb_build_object('master_id', v_id, 'master_status', v_status, 'barcodes', v_results);
end;
$$;

revoke all on function public.upload_promoted_product(jsonb, jsonb) from public;
revoke all on function public.upload_promoted_product(jsonb, jsonb) from anon;
revoke all on function public.upload_promoted_product(jsonb, jsonb) from authenticated;
grant execute on function public.upload_promoted_product(jsonb, jsonb) to service_role;
