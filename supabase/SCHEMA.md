# HappyCart Supabase DB 스키마

프로젝트: `ftgsnvvskbadegswvjnp` (https://ftgsnvvskbadegswvjnp.supabase.co)
최종 마이그레이션: `0014_remove_insufficient_verdict.sql`

> 이 문서는 `supabase/migrations/` 의 누적 결과를 요약한 것이다.
> 스키마 변경 시 마이그레이션과 함께 이 문서도 갱신할 것.

---

## 전체 구조

```
┌─────────────────┐     lookup_product (RPC)      ┌──────────────┐
│  Flutter 앱      │ ────────────────────────────▶ │   products   │
│  (anon key)     │                                └──────────────┘
│                 │     log_pending_product (RPC)  ┌──────────────────┐
│                 │ ────────────────────────────▶ │ pending_products │
│                 │                                └──────────────────┘
│                 │     log_scan_event (RPC)       ┌──────────────┐
│                 │ ────────────────────────────▶ │ scan_events  │
└─────────────────┘                                └──────────────┘

┌─────────────────┐     service_role (RLS 우회)
│ Data Desk /     │ ────────────────────────────▶  모든 테이블 직접 접근
│ 업로드 파이프라인 │
└─────────────────┘

Storage: product-images 버킷 (public read, image/jpeg only)
```

**보안 모델**: 모든 테이블이 RLS enabled + 정책 0개 = **default-deny**.
anon/authenticated 는 테이블 직접 접근 불가, SECURITY DEFINER RPC 경유만 허용.
service_role 만 RLS 를 우회한다 (Data Desk, 업로드 스크립트).

---

## Enum 타입

| 타입 | 값 | 용도 |
|------|-----|------|
| `verdict_enum` | `okay`, `not_okay` | 룰 엔진 판정 결과 (0014 에서 `insufficient` 제거) |
| `verified_status_enum` | `unverified`, `verified`, `needs_review` | 데이터 검증 상태. `verified` 만 앱에 노출 |
| `pending_status_enum` | `pending`, `registered`, `ignored` | 미등록 상품 처리 상태 |

---

## 테이블

### `products` — 상품 + 판정 결과 (0001, 0012)

| 컬럼 | 타입 | 제약 | 설명 |
|------|------|------|------|
| `id` | uuid | PK, default gen_random_uuid() | |
| `barcode` | text | NOT NULL, UNIQUE | EAN-8(8자리) 또는 EAN-13(13자리) |
| `brand` | text | NOT NULL | |
| `name` | text | NOT NULL | |
| `size` | text | NOT NULL | 예: `66g`, `48g (24g×2번들)` |
| `category` | text | | 예: `과자_초콜릿_시리얼` |
| `ingredients_raw` | text | NOT NULL | 라벨 원문. RPC 비노출 |
| `ingredients_tokens` | text[] | NOT NULL, default '{}' | 정규화 토큰 — 룰 매칭 입력 |
| `bad_ingredients_detected` | text[] | NOT NULL, default '{}' | canonical key (예: `canola_oil`) |
| `good_ingredients_detected` | text[] | NOT NULL, default '{}' | canonical key (예: `whole_grain`) |
| `verdict_reason_codes` | text[] | NOT NULL, default '{}' | reason code (예: `seed_oil`) |
| `verdict` | verdict_enum | NOT NULL | |
| `rule_version` | text | NOT NULL | 예: `v1.1.0` |
| `computed_at` | timestamptz | NOT NULL | verdict 계산 시각 |
| `source` | text | NOT NULL | 예: `쿠팡 크롤링 + 직접 판독` |
| `source_url` | text | | |
| `source_checked_at` | timestamptz | NOT NULL | |
| `label_version` | text | | |
| `verified_status` | verified_status_enum | NOT NULL, default 'unverified' | `verified` 만 lookup_product 에 노출 |
| `image_url` | text | | Storage public URL |
| `image_source_url` | text | | 원본 벤더 CDN URL (출처 기록용, RPC 비노출) |
| `created_at` | timestamptz | NOT NULL, default now() | |
| `updated_at` | timestamptz | NOT NULL, default now() | `tg_set_updated_at` 트리거로 자동 갱신 |

**CHECK 제약**:

| 제약 | 내용 |
|------|------|
| `products_barcode_format` | barcode 는 8자리 또는 13자리 숫자 |
| `products_not_okay_requires_bad_match` | `not_okay` 이면 `bad_ingredients_detected` 1개 이상 |
| `products_okay_requires_no_bad_match` | `okay` 이면 `bad_ingredients_detected` 비어야 함 |
| `products_requires_ingredient_tokens` | `ingredients_tokens` 가 1개 이상 (모든 제품은 판정 가능해야 함, 0014) |

**인덱스**: `products_verdict_idx` (verdict)

---

### `scan_events` — 익명 분석 이벤트 (0003)

바코드 원문/해시를 저장하지 않는다 (프라이버시).

| 컬럼 | 타입 | 제약 | 설명 |
|------|------|------|------|
| `id` | bigserial | PK | |
| `event_type` | text | NOT NULL, CHECK | `scan_success` / `not_found` / `network_error` |
| `barcode_format` | text | NOT NULL, CHECK | `EAN-13` / `EAN-8` |
| `verdict` | text | CHECK (null 허용) | `okay` / `not_okay` |
| `scan_latency_ms` | integer | NOT NULL, 0~60000 | |
| `app_version` | text | NOT NULL, `^\d+\.\d+\.\d+(\+\d+)?$` | |
| `platform` | text | NOT NULL, CHECK | `ios` / `android` |
| `created_at` | timestamptz | NOT NULL, default now() | |

**인덱스**: `scan_events_created_at_idx` (created_at)
**보존 기간**: pg_cron 있으면 매일 03:00 에 90일 초과분 삭제 (0004)

---

### `pending_products` — 미등록 상품 적재 (0013)

앱에서 스캔됐지만 products 에 없는 바코드를 기록. Data Desk 에서 검토·등록.

| 컬럼 | 타입 | 제약 | 설명 |
|------|------|------|------|
| `id` | uuid | PK, default gen_random_uuid() | |
| `barcode` | text | NOT NULL, UNIQUE, 8 또는 13자리 | |
| `scan_count` | int | NOT NULL, default 1 | status='pending' 일 때만 증가 |
| `first_scanned_at` | timestamptz | NOT NULL, default now() | |
| `last_scanned_at` | timestamptz | NOT NULL, default now() | |
| `status` | pending_status_enum | NOT NULL, default 'pending' | |
| `product_name` | text | | Data Desk 입력 |
| `notes` | text | | Data Desk 입력 |
| `created_at` | timestamptz | NOT NULL, default now() | |
| `updated_at` | timestamptz | NOT NULL, default now() | 트리거 자동 갱신 |

**인덱스**: `pending_products_status_idx` (status), `pending_products_last_scanned_idx` (last_scanned_at desc)

---

## RPC 함수 (anon/authenticated 호출 가능)

모두 `SECURITY DEFINER` + `set search_path = ''` — RLS default-deny 를 우회하는 유일한 공개 경로.

### `lookup_product(p_barcode text)` (0002, 0010 에서 image_url 추가)

- `verified_status = 'verified'` 인 행만 반환 (0행이면 미등록)
- 반환 컬럼: barcode, brand, name, size, category, verdict, bad/good_ingredients_detected,
  verdict_reason_codes, rule_version, computed_at, source_checked_at, **image_url**
- `ingredients_raw`, `image_source_url` 은 노출하지 않음

### `log_scan_event(p_event_type, p_barcode_format, p_verdict, p_scan_latency_ms, p_app_version, p_platform)` (0004)

- scan_events 에 INSERT. 본문에서 CHECK 와 동일한 화이트리스트 검증 (위반 시 errcode 22023)

### `log_pending_product(p_barcode text)` (0013)

- 바코드가 products 에 이미 있으면 아무것도 안 함
- 없으면 pending_products 에 upsert — 중복 스캔 시 `status='pending'` 인 행만
  scan_count +1, last_scanned_at 갱신 (registered/ignored 는 변경 없음)

---

## Storage

### `product-images` 버킷 (0011)

| 설정 | 값 |
|------|-----|
| public | true (read 정책: 모든 사용자) |
| file_size_limit | 524288 (512KB) |
| allowed_mime_types | `image/jpeg` 만 |
| 경로 규칙 | `products/<barcode>.jpg` |

업로드는 service_role 만 가능 (별도 write 정책 없음).
PNG 원본은 업로드 전 JPEG 변환 필요 — `upload_to_supabase.py` (happycart_crawler 레포) 참고.

---

## 트리거 / 함수

| 이름 | 대상 | 동작 |
|------|------|------|
| `tg_set_updated_at()` | products, pending_products (before update) | `updated_at = now()` |

---

## 마이그레이션 이력

| # | 파일 | 내용 |
|---|------|------|
| 0001 | products.sql | products 테이블 + enum + RLS |
| 0002 | lookup_product.sql | lookup_product RPC |
| 0003 | scan_events.sql | scan_events 테이블 |
| 0004 | log_scan_event.sql | log_scan_event RPC + 90일 보존 cron |
| 0005~0007 | seed_products*.sql | 초기 시드 데이터 |
| 0008 | rule_v1_1_0_resync.sql | rule v1.1.0 재계산 |
| 0009 | coupang_food_seed_saidabol.sql | 사이다볼 시드 |
| 0010 | lookup_product_image_url.sql | lookup_product 에 image_url 추가 |
| 0011 | product_images_storage.sql | product-images 버킷 |
| 0012 | product_image_source_url.sql | products.image_source_url 컬럼 |
| 0013 | pending_products.sql | pending_products 테이블 + log_pending_product RPC |
| 0014 | remove_insufficient_verdict.sql | verdict_enum 에서 `insufficient` 제거, 토큰 필수 제약 추가, scan_events/log_scan_event 정리 |
