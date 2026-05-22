-- HappyCart MVP: scan_events table for anonymous analytics.
-- 스펙 §4.4. 바코드 컬럼은 원문/해시 어느 형태로도 두지 않는다.
-- RLS default-deny — anon 직접 접근 차단. log_scan_event RPC (0004) 만 INSERT.

create table public.scan_events (
  id bigserial primary key,
  event_type text not null,
  barcode_format text not null,
  verdict text,
  scan_latency_ms integer not null,
  app_version text not null,
  platform text not null,
  created_at timestamptz not null default now(),
  constraint scan_events_event_type_check
    check (event_type in ('scan_success', 'not_found', 'insufficient', 'network_error')),
  constraint scan_events_barcode_format_check
    check (barcode_format in ('EAN-13', 'EAN-8')),
  constraint scan_events_verdict_check
    check (verdict is null or verdict in ('okay', 'not_okay', 'insufficient')),
  constraint scan_events_scan_latency_ms_range
    check (scan_latency_ms >= 0 and scan_latency_ms <= 60000),
  constraint scan_events_app_version_format
    check (length(app_version) <= 32 and app_version ~ '^\d+\.\d+\.\d+(\+\d+)?$'),
  constraint scan_events_platform_check
    check (platform in ('ios', 'android'))
);

create index scan_events_created_at_idx on public.scan_events (created_at);

alter table public.scan_events enable row level security;
-- No policies defined: default-deny for anon/authenticated. service_role
-- bypasses RLS, and log_scan_event (SECURITY DEFINER, owner=postgres) is the
-- sole insert path.
