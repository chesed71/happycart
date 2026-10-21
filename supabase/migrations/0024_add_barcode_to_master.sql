-- 0024: add_barcode_to_master — 이미 운영에 있는 master 에 바코드만 연결(master 내용 불변)
--
-- 같은 상품의 다른 바코드(용량·포장만 다른 형제 바코드)를 LOCAL 에서 이미 올라간 master 에 붙였을 때, 그
-- 바코드를 운영의 같은 master 에 연결한다. upload_promoted_product(0021)는 master_key 로 master 를 찾지만,
-- 여기서는 업로더가 LOCAL 에 기록해 둔 운영 master id 를 직접 받는다.
--   - 입력: p_master_id(운영 master id), p_expected({master_key, ingredients_hash} — LOCAL master 로 계산한
--     값, upload_prod.py master_key·ingredients_hash 와 같은 식), p_barcodes([{barcode, size, image_url,
--     image_source_url}]).
--   - 잠금: 대상 master 와 입력 바코드를 이미 가진 master 를 한 번에 id 순서로 for update 잠근다. 대상을 먼저
--     따로 잠그지 않는다 — 0021 과 같은 순서라 두 함수가 엇갈려 교착하지 않는다.
--   - 대상 master 없음: not_found, 아무것도 쓰지 않는다.
--   - needs_review: 보류(review_held).
--   - master_key 또는 ingredients_hash 가 기대값과 다름(운영에서 이름·원재료가 바뀜): 보류(identity_mismatch).
--   - 보류 두 경우는 0021 처럼 입력 바코드 중 이미 그 master 소속인 것만 exists 로 담고 새 연결은 하지 않는다.
--     "운영 커밋 → LOCAL 기록 전 멈춤 → 그사이 운영 상태 변경" 뒤 재실행해도 이미 된 연결이 LOCAL 에
--     기록되게 하기 위해서다.
--   - unverified·verified: 바코드마다 inserted·exists·conflict(다른 master 소속, 연결 안 함), master_status 는
--     existing. 새로 inserted 된 바코드가 있으면 updated_at 만 현재 시각으로 갱신한다(노출 승인 토큰(0022)이
--     바코드가 늘었음을 감지하도록). master 내용 컬럼은 어떤 경우에도 바꾸지 않는다.
--   - 바코드 삽입은 바코드 순서(오름차순)로 한다. 결과 배열은 입력 순서를 유지한다. 서로 다른 master 에 같은
--     신규 바코드 둘을 0024 는 [X,Y], 0021 은 [Y,X] 순서로 넣으면 UNIQUE 인덱스 대기가 엇갈려 교착할 수 있다.
--     그래서 업로더는 0021 호출에도 바코드를 정렬해 보낸다(과제 3). 0021 은 바꾸지 않는다.
--
-- add_barcode_to_master_version(): 읽기 전용, 24 를 돌려준다. upload_prod.py 가 이미지 업로드·RPC 호출 전에
-- 불러 이 함수가 있는지 확인한다(없으면 아무것도 쓰지 않고 멈춘다).
--
-- create or replace 라 다시 적용해도 결과가 같다.

create or replace function public.add_barcode_to_master(p_master_id uuid, p_expected jsonb, p_barcodes jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
  v_vstatus public.verified_status_enum;
  v_key text;
  v_hash text;
  v_status text;
  v_results jsonb := '[]'::jsonb;
  v_bc jsonb;
  v_owner uuid;
  v_ins uuid;
  v_bcstat text;
  v_new_links int := 0;
  v_stat jsonb := '{}'::jsonb;
begin
  -- 대상 master + 입력 바코드 소유 master 를 한 번에 id 순서로 잠근다(0021 과 같은 순서 규칙).
  perform 1 from public.product_masters m
  where m.id = p_master_id
     or m.id in (
          select b.master_id from public.product_barcodes b
          where b.barcode in (select e->>'barcode' from jsonb_array_elements(p_barcodes) e))
  order by m.id
  for update;

  select id, verified_status, master_key, ingredients_hash into v_id, v_vstatus, v_key, v_hash
  from public.product_masters where id = p_master_id;

  if v_id is null then
    return jsonb_build_object('master_id', p_master_id, 'master_status', 'not_found', 'barcodes', '[]'::jsonb);
  end if;

  v_status := case
    when v_vstatus = 'needs_review' then 'review_held'
    when v_key is distinct from p_expected->>'master_key'
      or v_hash is distinct from p_expected->>'ingredients_hash' then 'identity_mismatch'
    else 'existing'
  end;

  -- 보류: 바코드를 쓰지 않고, 입력 바코드 중 이미 그 master 소속인 것만 exists 로 돌려준다.
  if v_status in ('review_held', 'identity_mismatch') then
    select coalesce(jsonb_agg(jsonb_build_object('barcode', e->>'barcode', 'status', 'exists') order by o),
                    '[]'::jsonb)
      into v_results
    from jsonb_array_elements(p_barcodes) with ordinality as t(e, o)
    where exists (select 1 from public.product_barcodes b
                  where b.barcode = e->>'barcode' and b.master_id = v_id);
    return jsonb_build_object('master_id', v_id, 'master_status', v_status, 'barcodes', v_results);
  end if;

  -- 바코드 순서로 삽입(위 교착 메모). 결과는 아래에서 입력 순서로 다시 모은다.
  for v_bc in select e from jsonb_array_elements(p_barcodes) e order by e->>'barcode' loop
    insert into public.product_barcodes (barcode, master_id, size, image_url, image_source_url)
    values (v_bc->>'barcode', v_id, v_bc->>'size', v_bc->>'image_url', v_bc->>'image_source_url')
    on conflict (barcode) do nothing
    returning master_id into v_ins;
    if v_ins is not null then
      v_bcstat := 'inserted'; v_new_links := v_new_links + 1;
    else
      select master_id into v_owner from public.product_barcodes where barcode = v_bc->>'barcode';
      if v_owner = v_id then
        v_bcstat := 'exists';
      else
        v_bcstat := 'conflict';  -- 운영에서 다른 master 소속 — 연결 안 함
      end if;
    end if;
    -- 같은 바코드가 입력에 두 번 오면 처음 결과를 유지한다(두 번째 exists 가 inserted 를 덮지 않게).
    if not v_stat ? (v_bc->>'barcode') then
      v_stat := v_stat || jsonb_build_object(v_bc->>'barcode', v_bcstat);
    end if;
  end loop;

  select coalesce(jsonb_agg(jsonb_build_object('barcode', e->>'barcode', 'status', v_stat->>(e->>'barcode'))
                            order by o), '[]'::jsonb)
    into v_results
  from jsonb_array_elements(p_barcodes) with ordinality as t(e, o);

  -- 새 바코드가 붙었으면 updated_at 만 갱신(내용 컬럼은 그대로). 0015 트리거에 기대지 않고 명시적으로 쓴다.
  if v_new_links > 0 then
    update public.product_masters set updated_at = now() where id = v_id;
  end if;

  return jsonb_build_object('master_id', v_id, 'master_status', v_status, 'barcodes', v_results);
end;
$$;

revoke all on function public.add_barcode_to_master(uuid, jsonb, jsonb) from public;
revoke all on function public.add_barcode_to_master(uuid, jsonb, jsonb) from anon;
revoke all on function public.add_barcode_to_master(uuid, jsonb, jsonb) from authenticated;
grant execute on function public.add_barcode_to_master(uuid, jsonb, jsonb) to service_role;

create or replace function public.add_barcode_to_master_version()
returns integer
language sql
immutable
set search_path = ''
as $$ select 24 $$;

revoke all on function public.add_barcode_to_master_version() from public;
revoke all on function public.add_barcode_to_master_version() from anon;
revoke all on function public.add_barcode_to_master_version() from authenticated;
grant execute on function public.add_barcode_to_master_version() to service_role;
