-- pre-gate(확인완료 게이트 도입 전)에 자동 승격된 행을 judged로 되돌린다.
-- §8-1 확정으로 승격은 review_decision='verified'만 허용 → 검수 없이 올라간 분은 롤백.
-- 시드 8건(운영 베이스라인)은 건드리지 않는다 — collected_products에서 온 승격분만 대상.
-- 로컬 전용·운영 미반영 상태라 안전. idempotent.
--
-- 참고: docs/superpowers/specs/2026-06-16-datadesk-collected-products-plan.md §8-1
--
-- 주의: bootstrap_local.sh로 전체 재구성하면 fresh extract→promote(게이트 적용)가
-- 같은 결과(미검수 0 승격)를 내므로 이 스크립트는 "재구성 없이 기존 상태를 고칠 때"용.
--
-- 로직을 함수로 두어 test_invariants.py가 트랜잭션 안에서 실행·검증·rollback 할 수 있게 한다.

create or replace function public.rollback_ungated_promotions()
returns void
language plpgsql
as $fn$
declare
  v_verified bigint;
  v_broken bigint;
begin
  select count(*) into v_verified from public.collected_products
  where stage = 'promoted' and review_decision = 'verified';
  if v_verified > 0 then
    raise notice 'preserving % verified promotion(s) — rollback only touches non-verified', v_verified;
  end if;

  -- 롤백 대상 = non-verified promoted 행. 각 행이 만든 서비스 바코드는 collected.barcode 와
  -- 동일하다 (바코드는 product_barcodes PK라 1:1).
  drop table if exists _rb;
  create temp table _rb as
    select id, barcode, promoted_master_id
    from public.collected_products
    where stage = 'promoted' and review_decision is distinct from 'verified';

  -- 1) 대상 행을 judged로 복원 (FK 참조부터 끊는다)
  update public.collected_products
  set stage = 'judged', promoted_master_id = null, promoted_at = null
  where id in (select id from _rb);

  -- 2) 대상 행이 만든 바코드만 제거 (verified 행/공유 master의 바코드는 보존).
  delete from public.product_barcodes b
  where b.barcode in (select barcode from _rb where barcode is not null);

  -- 3) 바코드가 모두 사라져 빈 master만 제거. verified 와 공유된 master 는 verified
  --    바코드가 남아 비지 않으므로 보존된다.
  delete from public.product_masters m
  where m.id in (select promoted_master_id from _rb where promoted_master_id is not null)
    and not exists (select 1 from public.product_barcodes b where b.master_id = m.id);

  drop table _rb;

  -- 4) 안전 assert: 살아남은 verified promoted 행이 가리키는 master 가 삭제됐으면 중단.
  select count(*) into v_broken
  from public.collected_products c
  where c.stage = 'promoted' and c.review_decision = 'verified'
    and c.promoted_master_id is not null
    and not exists (select 1 from public.product_masters m where m.id = c.promoted_master_id);
  if v_broken > 0 then
    raise exception 'rollback would orphan % verified promotion(s) — aborting', v_broken;
  end if;
end
$fn$;

-- 실행
begin;
select public.rollback_ungated_promotions();
commit;
