-- 운영 업로드 영수증 (LOCAL 전용). upload_prod 실행이 행마다 남기는 결과 기록.
-- 적용 순서: collected_products.sql, review_rpc.sql(datadesk_review 롤 생성) 이후.
--
-- 행의 현재 업로드 상태 = 같은 collected_id 이고 promoted_at 이 그 행의 현재 promoted_at 과
-- 같은 영수증 중 순번(id)이 가장 큰 것. 재승격하면 promoted_at 이 바뀌어 옛 영수증은 자동으로 낡은 것이 된다.

create table if not exists public.upload_receipts (
  id bigserial primary key,
  run_id text not null,                          -- 업로드 실행마다 하나
  collected_id uuid not null,                    -- collected_products.id
  local_master_id uuid not null,
  barcode text not null,
  promoted_at timestamptz not null,              -- 업로드 때 읽은 승격 시각
  result text not null check (result in (
    'inserted', 'existing', 'exists', 'conflict',
    'verified_held', 'review_held', 'renamed_held', 'empty_held', 'error'
  )),
  prod_master_id uuid,
  error text,
  created_at timestamptz not null default now()
);

create index if not exists upload_receipts_collected_id_idx on public.upload_receipts (collected_id);
create index if not exists upload_receipts_promoted_at_idx on public.upload_receipts (promoted_at);
create index if not exists upload_receipts_id_desc_idx on public.upload_receipts (id desc);

-- 데이터데스크(④ 화면)가 읽는다.
grant select on public.upload_receipts to datadesk_review;
