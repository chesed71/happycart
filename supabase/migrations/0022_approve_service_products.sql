-- 0022: approve_service_products — Data Desk 일괄 노출 승인을 원자적으로 처리하는 RPC
--
-- 그동안 Data Desk 는 service_role 로 product_masters 를 id in (...) 한 번의 PATCH 로 verified 로 바꿨다.
-- 현재 상태·updated_at 을 확인하지 않아, 화면을 연 뒤 내용이 바뀌었거나(업로드로 바코드가 늘어남 포함)
-- needs_review 가 된 상품까지 앱에 노출될 수 있었다. 이 함수는 화면이 본 값을 낙관적 동시성 토큰으로
-- 받아, 전부 그대로일 때만 한꺼번에 승인한다.
--
-- 입력: 배열. 항목마다 id(uuid 문자열)·updated_at(timestamptz 문자열, 화면이 받은 값 그대로)·
-- expected_status(unverified 또는 needs_review).
-- 거부(SQLSTATE 22023): 배열이 아니거나 비어 있음, 항목이 객체가 아님, id·updated_at 형식 오류·누락,
-- expected_status 가 두 값이 아님, 같은 id 두 번.
--
-- 동작: 대상 master 를 id 순서로 전부 for update 로 잠근 뒤(id 순서 고정 — 0021과 같은 순서라 보통은
-- 데드락이 없다. 다만 0021이 첫 잠금 뒤 새로 나타난 같은 키 master를 따로 잠그는 드문 경우엔
-- 40P01로 한쪽이 실패할 수 있다 — 아무것도 바뀌지 않으며 다시 시도하면 된다),
-- 항목마다 어긋남 사유를 정한다 — 행 없음 missing, verified_status 가 기대와 다름 status_changed,
-- updated_at 이 받은 값과 다름 content_changed(상태가 다르면 상태 사유 우선).
--   - 어긋남이 하나라도 있으면 아무것도 바꾸지 않고 ok=false, count=0, mismatches=[{id, reason}...]
--     (어긋난 항목 전부, 입력 순서).
--   - 전부 맞으면 전부 verified 로 바꾸고 ok=true, count=바꾼 수, mismatches=[].
-- 0021 이 기존 unverified master 에 새 바코드를 붙이면 updated_at 을 갱신하므로, 화면을 연 뒤 바코드가
-- 늘면 content_changed 로 거절되고, 승인 뒤의 업로드는 verified_held 로 보류된다.
--
-- 권한: SECURITY DEFINER 인데다 호출자 검증이 없으므로 anon/authenticated 에 절대
-- 열지 않는다(anon key 는 APK 에 번들되는 공개값 — 열어두면 누구나 상품을 앱에 노출시킬 수 있다).
-- Data Desk 는 service_role 키로 호출하므로 service_role 만 부여한다.
--
-- create or replace 라 다시 적용해도 결과가 같다.

create or replace function public.approve_service_products(p_items jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_item jsonb;
  v_ord bigint;
  v_id uuid;
  v_at timestamptz;
  v_exp text;
  v_ids uuid[] := '{}';
  v_ats timestamptz[] := '{}';
  v_exps text[] := '{}';
  v_mismatches jsonb;
  v_count int;
begin
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'p_items must be a non-empty array' using errcode = 'invalid_parameter_value';
  end if;

  for v_item, v_ord in select e, o from jsonb_array_elements(p_items) with ordinality as t(e, o) loop
    if jsonb_typeof(v_item) <> 'object' then
      raise exception 'item %: not an object', v_ord using errcode = 'invalid_parameter_value';
    end if;
    v_exp := v_item->>'expected_status';
    if v_exp is null or v_exp not in ('unverified', 'needs_review') then
      raise exception 'item %: expected_status must be unverified or needs_review', v_ord
        using errcode = 'invalid_parameter_value';
    end if;
    if jsonb_typeof(v_item->'id') is distinct from 'string'
       or jsonb_typeof(v_item->'updated_at') is distinct from 'string' then
      raise exception 'item %: id and updated_at must be strings', v_ord using errcode = 'invalid_parameter_value';
    end if;
    -- 캐스트 오류(22P02·22007·22008 등)를 그대로 내보내지 않고 22023 으로 바꾼다.
    begin
      v_id := (v_item->>'id')::uuid;
      v_at := (v_item->>'updated_at')::timestamptz;
    exception when data_exception then
      raise exception 'item %: invalid id or updated_at', v_ord using errcode = 'invalid_parameter_value';
    end;
    if v_id = any(v_ids) then
      raise exception 'item %: duplicate id %', v_ord, v_id using errcode = 'invalid_parameter_value';
    end if;
    v_ids := v_ids || v_id;
    v_ats := v_ats || v_at;
    v_exps := v_exps || v_exp;
  end loop;

  -- 대상 master 를 id 순서로 전부 잠근다. 아래 비교는 이 잠금 뒤의 새 스냅샷에서 읽으므로(READ COMMITTED)
  -- 잠금 대기 중 커밋된 변경(업로드의 updated_at 갱신 등)을 본다.
  perform 1 from public.product_masters where id = any(v_ids) order by id for update;

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', i.id::text,
           'reason', case
             when m.id is null then 'missing'
             when m.verified_status::text <> i.exp then 'status_changed'
             else 'content_changed'
           end) order by i.o), '[]'::jsonb)
    into v_mismatches
  from unnest(v_ids, v_ats, v_exps) with ordinality as i(id, at, exp, o)
  left join public.product_masters m on m.id = i.id
  where m.id is null or m.verified_status::text <> i.exp or m.updated_at <> i.at;

  if jsonb_array_length(v_mismatches) > 0 then
    return jsonb_build_object('ok', false, 'count', 0, 'mismatches', v_mismatches);
  end if;

  update public.product_masters set verified_status = 'verified' where id = any(v_ids);
  get diagnostics v_count = row_count;

  return jsonb_build_object('ok', true, 'count', v_count, 'mismatches', '[]'::jsonb);
end;
$$;

revoke all on function public.approve_service_products(jsonb) from public;
revoke all on function public.approve_service_products(jsonb) from anon;
revoke all on function public.approve_service_products(jsonb) from authenticated;
grant execute on function public.approve_service_products(jsonb) to service_role;
