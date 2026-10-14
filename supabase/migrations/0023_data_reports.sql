-- HappyCart: data_reports — 앱 사용자가 보낸 데이터 오류 신고 적재.
--
-- 결과 화면 상단 '오류 신고' 알약 / 전체 성분표 시트 / 미등록 화면에서
-- Flutter 앱이 report_data_error RPC 를 호출한다.
-- 운영자가 Supabase 테이블 에디터로 읽고 status 를 직접 바꾼다.
--
-- 미등록 화면의 '이 제품 등록 요청하기' 도 여기에 register_request 로 쌓인다.
-- pending_products 는 스캔만 해도 자동으로 쌓이지만(scan_controller.dart:160),
-- 이쪽은 사용자가 직접 누른 것이라 의도의 세기가 다르다.
--
-- 전송되는 값은 전부 앱이 미리 정한 열거형이거나 해당 제품의 라벨 원문
-- 조각이다. 사용자가 입력한 글은 받지 않으므로 개인정보가 섞일 경로가 없다.
-- 중복·도배는 막지 않는다 (식별자를 보내지 않는다는 뜻이기도 하다).

create type public.data_report_reason_enum as enum (
  'ingredients_mismatch',  -- 성분표가 제품과 달라요
  'not_risky',             -- 이 성분은 위험하지 않아요
  'missing_risky',         -- 빠진 주의 성분이 있어요 (괜찮아요 경로)
  'wrong_product',         -- 다른 제품 정보예요
  'other',                 -- 그 밖에 달라요
  'register_request'       -- 미등록 제품 등록 요청 (미등록 화면 전용)
);

create type public.data_report_status_enum as enum ('new', 'resolved', 'rejected');

create table public.data_reports (
  id         uuid primary key default gen_random_uuid(),
  barcode    text not null,
  reason     public.data_report_reason_enum not null,
  -- 사용자가 지목한 성분 목록. 중립 성분은 canonical key 가 없으므로
  -- (ingredient_table.dart 의 IngredientTableEntry.canonicalKey 가 null)
  -- 라벨 원문 조각과 key 를 함께 보관한다.
  -- 예: [{"text": "아스파탐", "key": "aspartame"}, {"text": "정제수"}]
  ingredients jsonb not null default '[]'::jsonb,
  status     public.data_report_status_enum not null default 'new',
  notes      text,  -- 운영자가 채워넣는 처리 메모
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint data_reports_barcode_format
    check (barcode ~ '^[0-9]{8}$' or barcode ~ '^[0-9]{13}$'),
  -- anon 이 직접 실행하는 RPC 로 들어오는 값이라 크기를 묶어둔다.
  constraint data_reports_ingredients_is_array
    check (jsonb_typeof(ingredients) = 'array'),
  constraint data_reports_ingredients_len
    check (jsonb_array_length(ingredients) <= 50),
  -- 크기 상한은 '한 행이 무한정 커지지 않게' 하는 백스톱일 뿐이다. 실제로
  -- 구속하는 규칙은 아래 RPC 의 원소 수(50)·텍스트 길이(200)이고, 앱도 같은
  -- 값으로 자른다(product_repository.dart). 이 상한이 그보다 빡빡하면
  -- 앱이 보낸 정상 payload 가 거절되면서 사용자는 재시도만 반복하게 된다.
  constraint data_reports_ingredients_size
    check (octet_length(ingredients::text) <= 65536)
);

create index data_reports_status_idx on public.data_reports (status);
create index data_reports_created_idx on public.data_reports (created_at desc);
create index data_reports_barcode_idx on public.data_reports (barcode);

create trigger data_reports_updated_at
  before update on public.data_reports
  for each row
  execute function public.tg_set_updated_at();

alter table public.data_reports enable row level security;
-- 정책을 두지 않는다 — service_role 만 RLS 를 우회해 읽고,
-- anon/authenticated 는 아래 RPC 경유로만 쓸 수 있다.

-- ── RPC: report_data_error ────────────────────────────────────────────────────
-- Flutter 앱 호출용. 신고를 1행 적재한다.
-- p_reason 은 data_report_reason_enum 의 값이어야 하며, 아니면 예외가 난다
-- (앱이 보내는 값은 고정이므로 실제로는 버그일 때만 발생한다).
--
-- anon 이 직접 실행하는 함수라 세 가지를 거른다 — 사유 열거형, 성분 원소 모양,
-- 그리고 register_request 가 아닌 사유의 바코드 존재. 중복·도배는 의도적으로
-- 막지 않으므로, 여기서 거르는 것은 '운영자가 처리할 수 없는 행'뿐이다.

create function public.report_data_error(
  p_barcode text,
  p_reason text,
  p_ingredients jsonb default '[]'::jsonb
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_reason public.data_report_reason_enum := p_reason::public.data_report_reason_enum;
begin
  if p_ingredients is null or jsonb_typeof(p_ingredients) <> 'array' then
    raise exception 'p_ingredients must be a JSON array';
  end if;

  -- 원소 모양 검증 — 운영자와 장래의 조회 코드가 elem->>'text' 를 믿을 수 있게
  -- 한다. CHECK 제약에는 서브쿼리를 쓸 수 없어서 여기서 본다 (anon 의 쓰기
  -- 경로는 이 함수뿐이므로 게이트는 여기 하나로 충분하다).
  --
  -- coalesce 가 핵심이다 — 키가 없으면 `e.value -> 'text'` 는 SQL NULL 이고
  -- jsonb_typeof(NULL) 도 NULL 이라, 맨손으로 비교하면 TRUE 가 아니라 NULL 이
  -- 나와 WHERE 에 걸리지 않는다. 즉 {"foo":1} 같은 원소가 통과해버린다.
  if exists (
    select 1
    from jsonb_array_elements(p_ingredients) as e(value)
    where jsonb_typeof(e.value) <> 'object'
       or coalesce(jsonb_typeof(e.value -> 'text'), 'missing') <> 'string'
       or length(e.value ->> 'text') not between 1 and 200
       -- key 는 생략 가능 — 없으면 'string' 으로 채워 통과시킨다.
       or coalesce(jsonb_typeof(e.value -> 'key'), 'string') <> 'string'
  ) then
    raise exception
      'p_ingredients elements must be {text: string(1..200), key?: string}';
  end if;

  -- register_request 를 뺀 사유는 결과 화면에서만 보낼 수 있고, 그 화면은
  -- lookup_product 가 제품을 돌려줬을 때만 그려진다. 즉 바코드가 우리 데이터에
  -- 있어야 한다. 없는 바코드로 들어온 신고는 운영자가 열어볼 행이 없어 처리할
  -- 수 없으므로 받지 않는다.
  --
  -- 존재 확인 대상은 log_pending_product(0015) 와 같은 product_barcodes 다.
  -- verified_status 는 보지 않는다 — 조회 시점엔 verified 였다가 그 뒤 바뀌었을
  -- 수 있고, 그런 제품의 신고도 유효하기 때문이다.
  if v_reason <> 'register_request' and not exists (
    select 1 from public.product_barcodes where barcode = p_barcode
  ) then
    raise exception 'unknown barcode for reason %', v_reason;
  end if;

  insert into public.data_reports (barcode, reason, ingredients)
  values (p_barcode, v_reason, p_ingredients);
end;
$$;

revoke all on function public.report_data_error(text, text, jsonb) from public;
grant execute on function public.report_data_error(text, text, jsonb) to anon, authenticated;
