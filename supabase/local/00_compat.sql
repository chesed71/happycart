-- 단독 postgres(Docker)에서 Supabase 마이그레이션을 적용하기 위한 호환 셋업.
-- 운영 Supabase에는 절대 적용하지 않는다 (이미 존재하는 객체들).
-- 참고: docs/superpowers/specs/2026-06-11-local-db-data-ingestion-plan.md §3.2

do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then
    create role anon nologin;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    create role authenticated nologin;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then
    create role service_role nologin bypassrls;
  end if;
end
$$;

-- Supabase 기본과 동일하게 public 스키마 사용 권한 부여
grant usage on schema public to anon, authenticated, service_role;
