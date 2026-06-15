-- Data Desk 원재료 검수 — collected_products 검수 쓰기 경로 (로컬 전용).
-- 앱은 테이블을 직접 쓰지 않고 이 SECURITY DEFINER 함수로만 쓴다 (운영 RPC 패턴과 동일).
-- 참고: docs/superpowers/specs/2026-06-16-datadesk-collected-products-plan.md §보안, §5
--
-- idempotent — 기존 DB와 새 bootstrap 양쪽에 안전하게 재적용 가능.

-- ── 1. review 컬럼 (기존 테이블용 idempotent ALTER) ──────────────────────────
alter table public.collected_products add column if not exists review_decision text;
alter table public.collected_products add column if not exists review_note text;
alter table public.collected_products add column if not exists reviewed_at timestamptz;

do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'collected_products_review_decision_chk'
  ) then
    alter table public.collected_products
      add constraint collected_products_review_decision_chk
      check (review_decision in ('verified', 'needs_fix', 'skip'));
  end if;
end
$$;

create index if not exists collected_products_review_decision_idx
  on public.collected_products (review_decision);

-- ── 2. EAN-8/13 체크 디지트 검증 헬퍼 ─────────────────────────────────────────
create or replace function public.is_valid_ean(p_code text)
returns boolean
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_len int;
  v_sum int := 0;
  v_digit int;
  v_weight int;
  i int;
  v_check int;
begin
  if p_code is null then
    return true;  -- 무바코드 허용 (NULL)
  end if;
  if p_code !~ '^[0-9]{8}$' and p_code !~ '^[0-9]{13}$' then
    return false;
  end if;
  v_len := length(p_code);
  -- 마지막 자리 전까지 가중합. EAN-13: 우→좌 3,1,3,1...; EAN-8 동일 규칙.
  for i in 1 .. v_len - 1 loop
    v_digit := (substr(p_code, i, 1))::int;
    -- 오른쪽(체크 직전)부터 3,1 교대 → 위치 패리티로 계산
    if ((v_len - 1 - i) % 2) = 0 then
      v_weight := 3;
    else
      v_weight := 1;
    end if;
    v_sum := v_sum + v_digit * v_weight;
  end loop;
  v_check := (10 - (v_sum % 10)) % 10;
  return v_check = (substr(p_code, v_len, 1))::int;
end
$$;

-- ── 3. 검수 쓰기 RPC ──────────────────────────────────────────────────────────
-- §5 트랜잭션 불변식을 DB가 강제: promoted 잠금, stage='parsed' 복원, 파생 비움,
-- 화이트리스트, ''→NULL, unreadable(원재료 없음)↔confidence NULL 정합, reviewed_at.
create or replace function public.review_collected_product(
  p_id uuid,
  p_barcode text,
  p_ingredients_raw text,
  p_confidence text,
  p_decision text,
  p_note text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_stage text;
  v_cur_confidence text;
  v_barcode text;
  v_ingredients text;
  v_confidence text;
  v_decision text;
begin
  select stage, confidence into v_stage, v_cur_confidence
  from public.collected_products where id = p_id;
  if v_stage is null then
    raise exception 'collected_product % not found', p_id using errcode = 'no_data_found';
  end if;
  -- 이미 서비스로 넘어간 데이터는 잠금 (앱은 이를 409로 매핑)
  if v_stage = 'promoted' then
    raise exception 'collected_product % is promoted (locked)', p_id using errcode = 'object_not_in_prerequisite_state';
  end if;

  -- 정규화·검증
  v_barcode := nullif(trim(p_barcode), '');
  if not public.is_valid_ean(v_barcode) then
    raise exception 'invalid barcode %', p_barcode using errcode = 'check_violation';
  end if;

  v_ingredients := nullif(trim(p_ingredients_raw), '');

  -- confidence: 명시되면 검증 후 사용, 미지정('')이면 기존값 보존.
  -- 이 검수 UI는 confidence를 직접 편집하지 않으므로 보존이 기본.
  v_confidence := nullif(trim(p_confidence), '');
  if v_confidence is null then
    v_confidence := v_cur_confidence;  -- 보존
  elsif v_confidence not in ('low', 'medium', 'high') then
    raise exception 'invalid confidence %', p_confidence using errcode = 'check_violation';
  end if;
  -- 원재료가 없으면(unreadable) confidence도 없다 (정합)
  if v_ingredients is null then
    v_confidence := null;
  end if;

  v_decision := nullif(trim(p_decision), '');
  if v_decision is not null and v_decision not in ('verified', 'needs_fix', 'skip') then
    raise exception 'invalid decision %', p_decision using errcode = 'check_violation';
  end if;

  update public.collected_products set
    barcode = v_barcode,
    ingredients_raw = v_ingredients,
    confidence = v_confidence,
    review_decision = v_decision,
    review_note = nullif(trim(p_note), ''),
    reviewed_at = now(),
    -- 하류 산출은 다음 tokenize/judge가 다시 계산하도록 비우고 stage 복원
    stage = 'parsed',
    ingredients_tokens = null,
    verdict = null,
    bad_ingredients_detected = null,
    good_ingredients_detected = null,
    verdict_reason_codes = null,
    rule_version = null,
    computed_at = null
  where id = p_id;
end
$$;

-- ── 4. datadesk_review 롤 — SELECT + 함수 EXECUTE만 ──────────────────────────
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'datadesk_review') then
    create role datadesk_review login password 'datadesk_review';
  end if;
end
$$;

grant usage on schema public to datadesk_review;
grant select on public.collected_products to datadesk_review;
revoke all on function public.review_collected_product(uuid, text, text, text, text, text) from public;
grant execute on function public.review_collected_product(uuid, text, text, text, text, text) to datadesk_review;
grant execute on function public.is_valid_ean(text) to datadesk_review;
