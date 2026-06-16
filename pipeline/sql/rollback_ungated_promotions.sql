-- pre-gate(확인완료 게이트 도입 전)에 자동 승격된 행을 judged로 되돌린다.
-- §8-1 확정으로 승격은 review_decision='verified'만 허용 → 검수 없이 올라간 분은 롤백.
-- 시드 8건(운영 베이스라인)은 건드리지 않는다 — collected_products에서 온 승격분만 대상.
-- 로컬 전용·운영 미반영 상태라 안전. idempotent.
--
-- 참고: docs/superpowers/specs/2026-06-16-datadesk-collected-products-plan.md §8-1
--
-- 주의: bootstrap_local.sh로 전체 재구성하면 fresh extract→promote(게이트 적용)가
-- 같은 결과(미검수 0 승격)를 내므로 이 스크립트는 "재구성 없이 기존 상태를 고칠 때"용.

begin;

-- 안전장치: 게이트 도입 후의 정상(verified) 승격분은 절대 건드리지 않는다.
-- 이 스크립트는 pre-gate(미검수) 자동 승격분 정리 전용이다.
do $$
declare v_verified bigint;
begin
  select count(*) into v_verified from public.collected_products
  where stage = 'promoted' and review_decision = 'verified';
  if v_verified > 0 then
    raise notice 'preserving % verified promotion(s) — rollback only touches non-verified', v_verified;
  end if;
end $$;

-- promoted_master_id가 승격으로 생긴 master를 정확히 가리킨다 (시드 master는 여기에 없음).
-- review_decision='verified' 인 정상 승격분은 제외한다.
create temporary table _rollback_masters on commit drop as
  select distinct promoted_master_id as id
  from public.collected_products
  where stage = 'promoted' and promoted_master_id is not null
    and review_decision is distinct from 'verified';

-- 1) 대상 collected_products 행을 judged로 복원 (FK 참조부터 끊는다)
update public.collected_products
set stage = 'judged', promoted_master_id = null, promoted_at = null
where stage = 'promoted' and review_decision is distinct from 'verified';

-- 2) 그 master에 딸린 barcode 제거
delete from public.product_barcodes b
where b.master_id in (select id from _rollback_masters);

-- 3) master 제거
delete from public.product_masters m
where m.id in (select id from _rollback_masters);

commit;
