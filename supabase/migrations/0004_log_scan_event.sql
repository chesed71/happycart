-- HappyCart MVP: log_scan_event RPC.
-- SECURITY DEFINER lets anon callers insert analytics rows without granting
-- table-level INSERT. RLS on public.scan_events remains default-deny.
-- 본문에서 enum/CHECK 와 동일한 화이트리스트 검증 — 잘못된 입력은 22023 으로 거절.
-- 스펙 §4.4.

create function public.log_scan_event(
  p_event_type text,
  p_barcode_format text,
  p_verdict text,
  p_scan_latency_ms int,
  p_app_version text,
  p_platform text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if p_event_type is null or p_event_type not in (
    'scan_success', 'not_found', 'insufficient', 'network_error'
  ) then
    raise exception 'invalid event_type: %', p_event_type
      using errcode = '22023';
  end if;

  if p_barcode_format is null or p_barcode_format not in ('EAN-13', 'EAN-8') then
    raise exception 'invalid barcode_format: %', p_barcode_format
      using errcode = '22023';
  end if;

  if p_verdict is not null and p_verdict not in (
    'okay', 'not_okay', 'insufficient'
  ) then
    raise exception 'invalid verdict: %', p_verdict
      using errcode = '22023';
  end if;

  if p_scan_latency_ms is null
    or p_scan_latency_ms < 0
    or p_scan_latency_ms > 60000 then
    raise exception 'invalid scan_latency_ms: %', p_scan_latency_ms
      using errcode = '22023';
  end if;

  if p_app_version is null
    or length(p_app_version) > 32
    or p_app_version !~ '^\d+\.\d+\.\d+(\+\d+)?$' then
    raise exception 'invalid app_version: %', p_app_version
      using errcode = '22023';
  end if;

  if p_platform is null or p_platform not in ('ios', 'android') then
    raise exception 'invalid platform: %', p_platform
      using errcode = '22023';
  end if;

  insert into public.scan_events (
    event_type,
    barcode_format,
    verdict,
    scan_latency_ms,
    app_version,
    platform
  ) values (
    p_event_type,
    p_barcode_format,
    p_verdict,
    p_scan_latency_ms,
    p_app_version,
    p_platform
  );
end;
$$;

revoke all on function public.log_scan_event(text, text, text, int, text, text) from public;
grant execute on function public.log_scan_event(text, text, text, int, text, text) to anon, authenticated;

-- 90-day retention (스펙 §4.4).
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule(
      'scan_events_retention',
      '0 3 * * *',
      $cmd$delete from public.scan_events where created_at < now() - interval '90 days'$cmd$
    );
  end if;
end;
$$;
