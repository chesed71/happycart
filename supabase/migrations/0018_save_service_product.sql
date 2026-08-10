-- 0018: save_service_product — Data Desk 서비스 테이블 편집 RPC를 레포로 승격
--
-- 이 함수는 그동안 Data Desk 레포(review-sveltekit/db/2026-06-26_save_service_product.sql)
-- 에서만 관리되어 운영 DB(prod)에는 배포조차 되어 있지 않았다. Data Desk 를 prod 로
-- 전환하면서 정의를 이 레포로 옮겨 dev/prod 가 같은 소스에서 관리되도록 한다.
--
-- 동작: master 를 통째로 갱신(rule_version 을 'manual' 로 마킹)하고, 바코드는
-- original 이 있으면 (master_id, original) 로 수정, 없으면 신규 추가한다. 수정 대상이
-- 0행이면 예외로 전체 롤백한다.
--
-- 권한: SECURITY DEFINER 인데다 호출자 검증이 없으므로 anon/authenticated 에 절대
-- 열지 않는다(anon key 는 APK 에 번들되는 공개값 — 열어두면 누구나 상품 데이터를
-- 조작할 수 있다). Data Desk 는 service_role 키로 호출하므로 service_role 만 부여한다.

create or replace function public.save_service_product(
  p_id uuid,
  p_brand text,
  p_name text,
  p_category text,
  p_ingredients_raw text,
  p_verdict text,
  p_bad text[],
  p_good text[],
  p_barcodes jsonb
)
returns void
language plpgsql
security definer
set search_path to ''
as $function$
declare
  b jsonb;
  v_original text;
  v_barcode text;
  v_size text;
  v_count int;
begin
  update public.product_masters set
    brand = p_brand,
    name = p_name,
    category = p_category,
    ingredients_raw = p_ingredients_raw,
    verdict = p_verdict::public.verdict_enum,
    bad_ingredients_detected = p_bad,
    good_ingredients_detected = p_good,
    rule_version = 'manual'
  where id = p_id;
  if not found then
    raise exception 'master % not found', p_id using errcode = 'no_data_found';
  end if;

  -- 바코드: original 이 있으면 (master_id, original) 로 수정, 없으면 신규 추가.
  -- 수정 대상이 없으면(0행) 예외 → 전체 롤백. 전역 고유 위반(23505)도 롤백.
  for b in select * from jsonb_array_elements(coalesce(p_barcodes, '[]'::jsonb))
  loop
    v_original := nullif(b->>'original', '');
    v_barcode  := b->>'barcode';
    v_size     := coalesce(b->>'size', '');
    if v_original is not null then
      update public.product_barcodes set barcode = v_barcode, size = v_size
      where master_id = p_id and barcode = v_original;
      get diagnostics v_count = row_count;
      if v_count = 0 then
        raise exception 'barcode % not found for master %', v_original, p_id
          using errcode = 'no_data_found';
      end if;
    else
      insert into public.product_barcodes (master_id, barcode, size)
      values (p_id, v_barcode, v_size);
    end if;
  end loop;
end
$function$;

revoke all on function public.save_service_product(uuid, text, text, text, text, text, text[], text[], jsonb) from public;
revoke all on function public.save_service_product(uuid, text, text, text, text, text, text[], text[], jsonb) from anon;
revoke all on function public.save_service_product(uuid, text, text, text, text, text, text[], text[], jsonb) from authenticated;
grant execute on function public.save_service_product(uuid, text, text, text, text, text, text[], text[], jsonb) to service_role;
