# 로컬 PostgreSQL 구축 + 크롤링 데이터 적재 계획

> **목적**: products 테이블 분리(0014)를 로컬 PostgreSQL에서 안전하게 진행하고, CoupangCrawler / DataCollector 크롤링 데이터를 **수집용 테이블(collected_products)** 에 적재·정제한 뒤 완성 건만 **서비스 테이블(product_masters/product_barcodes)** 로 승격하고, 검증된 결과를 운영 Supabase에 반영한다.

- 작성일: 2026-06-11 (2026-06-12 수집/서비스 이원화 반영)
- 관련 스펙: `docs/superpowers/specs/2026-06-11-products-table-split-plan.md` (테이블 분리), `supabase/SCHEMA.md` (현행 스키마)
- 상태: 계획 (착수 전)

---

## 0. 한 줄 요약

Docker postgres에 시드 마이그레이션으로 운영 베이스라인(8건)을 재현하고 0014 분리를 먼저 완성한 뒤, 쿠팡 4,524건·kakamuka 1,722건을 **로컬 전용 수집 테이블** 에 적재해 토큰화·판정·매칭을 단계별로 진행하고, **바코드+원재료+판정이 완성된 건(실측 113건)만** 서비스 테이블로 승격해 운영 Supabase에 반영한다.

### 전체 흐름

```
═══ Phase 1 — 로컬 DB 구축 ═══════════════════════════════════════════

  Docker postgres ─ 00_compat.sql ─ 마이그레이션(시드 포함, 0011 제외)
       ─ 0014 분리(masters/barcodes, 시드 8건 이전) ─ collected_products DDL
       └ 시드 = 운영 베이스라인 (dump 불필요)

═══ Phase 2 — 수집·정제·승격 (전부 로컬) ═══════════════════════════════

┌─ CoupangCrawler/output ──────┐      ┌─ DataCollector/kakamuka ─────┐
│ 고유 4,501행                  │      │ 고유 1,722행                 │
│ 원재료 552건 (실판독만)        │      │ (유효 바코드 1,642 · 원재료 X)│
│ 유효 바코드 717건 · 상세 이미지│      │ 이미지 1,886장               │
└──────────────┬───────────────┘      └──────────────┬───────────────┘
       extract_coupang.py                  extract_kakamuka.py
               ▼                                     ▼
┌─────────────────────────────────────────────────────────────────────┐
│                  collected_products (로컬 전용, raw jsonb 보존)       │
│                                                                     │
│   raw → parsed ──→ tokenized ──→ judged ──→ promoted                │
│           │    tokenize.py    judge.py             ▲                │
│           │   (규칙 토크나이저) (Dart 룰 엔진)        │                │
│           │                                        │                │
│           ├── match_enrich.py: 쿠팡↔kakamuka 매칭,  │                │
│           │   바코드·이미지 보강, 기존 운영 데이터 대조 │                │
│           │                                        │                │
│           └──→ conflict ──(수동 결정)──→ 원복 또는 rejected           │
│                                                                     │
│   승격 미달(무바코드·원재료 없음 ~6,000건)은 여기서 보강 대기            │
└───────────────────────────────┬─────────────────────────────────────┘
                                │ promote.py
                                │ 조건: 바코드+원재료+판정 완료 (≈201건+)
                                ▼
        ┌──────────────────┐ 1    N ┌───────────────────┐
        │ product_masters  │◀───────│ product_barcodes  │
        │ (원재료·판정)      │   FK   │ (바코드·size·이미지) │
        └──────────────────┘        └───────────────────┘
          verified_status='unverified' (앱 비노출)
                                │
          prepare_images.py ────┤  승격 바코드만 products/<barcode>.jpg
                                │  (JPEG ≤512KB) 변환·정리
═══ Phase 3 — 운영 반영 ════════│══════════════════════════════════════
                                │ ① supabase db push (0014)
                                │ ② upload_prod.py (service_role upsert)
                                ▼
┌─────────────────────────────────────────────────────────────────────┐
│ 운영 Supabase                                                        │
│   product_masters / product_barcodes ← 승격분만 (수집 테이블은 없음)   │
│   Storage product-images            ← ③ 이미지 업로드 + image_url 갱신│
│   pending_products                  ← ④ 등록된 바코드 registered 소급 │
└─────────────────────────────────────────────────────────────────────┘
                                │
          Data Desk 검증 → verified 전환 → lookup_product 로 앱 노출
```

---

## 1. 인터뷰 결정 사항 요약

| 항목 | 결정 |
|------|------|
| 로컬 DB | Docker 단독 postgres (Supabase CLI 스택 아님) |
| **수집/서비스 이원화** | **크롤링 데이터는 수집용 테이블에, 서비스 테이블에는 승격된 완성 건만** (2026-06-12 변경) |
| 수집 테이블 구조 | 통합 테이블 한 장(`collected_products`) + 원본 레코드 `raw` jsonb 컬럼 보존. 크롤링 파일은 아카이브로 유지 |
| 수집 테이블 위치 | **로컬 전용** — 운영 Supabase에는 서비스 테이블만 존재 |
| 승격 기준 | 바코드 보유 + 원재료 보유 + 판정 완료 건만 product_masters/barcodes로 |
| 승격 시 verified_status | `unverified` — 앱 노출(verified 전환)은 기존대로 Data Desk 검증 후. 단 기존 verified master에 붙는 신규 barcode는 즉시 노출되므로 자동 연결하지 않고 검토 후 수동 연결 (§6.3) |
| verdict 계산 | 기존 룰 엔진(`packages/happycart_rules`)으로 일괄 계산 (수집 테이블 단계에서 수행) |
| kakamuka 활용 | 쿠팡 상품의 바코드·이미지 보강 + 단독 상품도 수집 테이블에 적재 (원재료 없어 승격 대기) |
| 바코드 없는 쿠팡 상품 | 수집 테이블에서 대기 — 추후 바코드 확보 시 승격 |
| 토큰화 | 규칙 기반 토크나이저 작성. 기존 수작업 시드 토큰을 golden test로 사용 |
| 기존 운영 데이터 | 운영 dump를 로컬에 복원 (시드 마이그레이션 재실행이 아니라 실데이터 기준) |
| 파이프라인 코드 | HappyCart 레포 `pipeline/` 신설. Python ETL + Dart 판정 서브프로세스 |
| 이미지 | 로컬에서 `products/<barcode>.jpg` 규칙으로 미리 변환·정리, 업로드는 운영 반영 단계 |
| 바코드 충돌 | 자동 병합하지 않고 `stage='conflict'`로 표시 → 수동 결정 → 재진행 |
| 운영 반영 | `supabase db push`(0014/0015) + 승격분만 service_role upsert 업로드 스크립트 |

---

## 2. 데이터 인벤토리 (2026-06-12 extract 실측 — collected_products 기준)

> **2026-06-12 교정**: 최초 측정(2026-06-11)은 manual_ingredients의 **미판독 placeholder**(ingredients가 None/빈 문자열인 항목 1,671건)를 원재료 보유로 잘못 셌다. 또한 바코드는 EAN 체크섬 검증 전 수치였고, 카테고리 폴더 간 중복(514건)이 이중 집계됐다. 아래는 extract 파이프라인 실행 후 DB 실측치.

### CoupangCrawler (`/Users/innovator/Project/CoupangCrawler/output`)

카테고리 폴더 8개. `products*.json`(productId·title·barcode·image·rank), `manual_ingredients_direct_page*.json`(육안 판독 원재료 — **대부분 미판독 placeholder**), `extracted_data/`(원재료 원문 dict), `detail/<productId>/` 상세 이미지, `images_page*`(Koreannet 이미지).

| 카테고리 (대표 폴더 기준) | 행 수 | 유효 바코드 | 원재료 |
|----------|------|------------|--------|
| 과자_초콜릿_시리얼 | 928 | 409 | 516 |
| 가루_조미료_오일 | 665 | 0 | 0 |
| 장_소스_드레싱_식초 | 636 | 0 | 3 |
| 냉장_냉동_간편요리 | 584 | 0 | 0 |
| 반찬_간편식_대용식 | 548 | 308 | 10 |
| 수입식품관 | 547 | 0 | 20 |
| 면_통조림_가공식품 | 308 | 0 | 3 |
| 유제품_아이스크림 | 285 | 0 | 0 |
| **합계** | **4,501** | **717** | **552** |

- 고유 productId 기준 4,501행 = 목록 4,271 + 목록 밖 원재료 보유(orphan) 230. 폴더 간 중복 514건은 첫 폴더로 병합
- 유효 바코드 717 = EAN 체크섬 통과분. 형식(8/13자리)은 맞지만 체크섬 불합격 16건은 검역 (barcode NULL, raw 보존)
- 원재료 552 = manual 실판독 102 + extracted 523의 합집합(중복 제외). manual items 1,844건 중 실제 값이 있는 건 173건(고유 102)뿐 — **라벨 판독 작업이 대부분 미완료 상태**
- 바코드 0인 6개 카테고리는 Koreannet 바코드 작업 미진행 (`handover_barcode_update.md` 참고)
- title 파싱 부분 실패(brand/name/size 일부 NULL) 581건 — 수동 보정 대상
- **바코드 ∩ 원재료 = 201행** ← 즉시 승격 후보

### DataCollector (`/Users/innovator/Project/DataCollector/kakamuka`)

- `detail/<id>/info.json` 기준 고유 1,722행, 그중 **유효 바코드 1,642** (체크섬 불합격 57건 검역) — 바코드·상품명·박스입수량·소비자가·판매가·소비기한·재고
- `detail/<id>/*.jpg` 이미지 1,886장
- title 파싱 부분 실패 72건
- **원재료 정보 없음** → 단독 상품은 수집 테이블에서 승격 대기 (쿠팡 매칭 건은 바코드·이미지 보강 소스)

---

## 3. Phase 1 — 로컬 DB 구축

### 3.1 Docker postgres 기동

```bash
docker run -d --name happycart-pg \
  -e POSTGRES_PASSWORD=happycart -e POSTGRES_DB=happycart \
  -p 54322:5432 \
  -v happycart-pg-data:/var/lib/postgresql/data \
  postgres:<운영과 동일 메이저>
```

- 버전은 운영 Supabase의 `select version();` 결과와 **동일 메이저**로 고정한다.
- 포트 54322 사용 (로컬 다른 postgres와 충돌 방지, supabase CLI 관례와 동일).

### 3.2 Supabase 호환 셋업 (마이그레이션 적용 전 1회)

단독 postgres에는 Supabase 전용 객체가 없으므로 `supabase/local/00_compat.sql`을 만들어 먼저 적용한다:

- `anon`, `authenticated`, `service_role` 롤 생성 (NOLOGIN)
- `pgcrypto` 확장 (gen_random_uuid)
- **0011(product-images 버킷)은 스킵** — `storage` 스키마가 없다. 적용 스크립트에서 제외 목록으로 관리
- 0004의 pg_cron 블록은 "있으면 등록" 조건부라 그대로 통과하는지 확인, 아니면 스킵 목록에 추가

### 3.3 마이그레이션 적용 (시드 = 운영 베이스라인)

> **2026-06-16 결정 변경**: 운영 `products`에 Data Desk가 직접 등록한 상품이 없음을 확인했다 (시드 8건이 전부). 운영 products 베이스라인은 **시드 마이그레이션(0005~0009)이 그대로 재현**하므로 dump가 불필요하다. 마이그레이션에 없는 것은 런타임 누적분(`pending_products`, `scan_events`)뿐이고, 이는 로컬 작업에 무관하다 (pending 소급은 §6.5 운영 반영 시점에만 필요).

1. `pipeline/bootstrap_local.sh`가 DB 재생성 → compat → 마이그레이션(**시드 포함**, 0011/0014만 제외) → 0014 → collected_products를 한 번에 수행한다. 시드가 8건을 products에 넣고 0014가 masters/barcodes로 이전한다
2. 자격증명은 `pipeline/.env`로 관리 (gitignore 처리). bootstrap은 `.env`를 source 한다
3. (선택) 추후 시드 외 운영 데이터가 생기면 `bootstrap_local.sh extra.sql`로 추가 복원 — 그때만 `pg_dump --data-only --table=public.products --table=public.pending_products`로 테이블을 명시해 dump (제한 없는 dump는 storage/auth를 포함해 단독 postgres 복원에서 실패)
4. 검증: 0014 후 product_masters/barcodes 각 8건, lookup_product 8건 정상

### 3.4 0014 분리 마이그레이션 (분리 계획 문서의 범위)

`2026-06-11-products-table-split-plan.md` §4의 0014를 로컬에서 작성·적용·검증한다.

- 검증: 기존 바코드 전수에 대해 `lookup_product` 응답이 분리 전과 diff 없는지 확인 (분리 계획 §5-1)
- **이 단계까지 끝난 뒤에** 크롤링 데이터 작업을 시작한다

#### `product_masters` — 원재료 + 판정 (서비스 테이블)

기존 products에서 바코드·SKU 종속 필드를 뺀 나머지 전부. 자세한 설계 근거는 분리 계획 §2.

| 컬럼 | 타입 | 제약 | 설명 |
|------|------|------|------|
| `id` | uuid | PK, default gen_random_uuid() | |
| `brand` | text | NOT NULL | |
| `name` | text | NOT NULL | |
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
| `verified_status` | verified_status_enum | NOT NULL, default 'unverified' | `verified`만 lookup_product에 노출 |
| `ingredients_hash` | text | generated stored, UNIQUE | brand와 ingredients_raw 결합의 md5. 신규 master의 **초기 dedupe·upsert conflict target** — 영속 식별자가 아님. 운영 업로드 후의 영속 매핑은 uuid + collected_products.prod_master_id (§6.3) |
| `created_at` | timestamptz | NOT NULL, default now() | |
| `updated_at` | timestamptz | NOT NULL, default now() | `tg_set_updated_at` 트리거 |

> `ingredients_hash` UNIQUE는 **삽입 시점의 중복 생성 방지**용이다 — "brand+원문 완전 일치 = 같은 master"라는 그룹핑 전제를 신규 행에 한해 DB가 강제한다. §4.6 검토에서 별개 상품으로 판명되는 그룹은 원문/브랜드 데이터를 실제 라벨 차이대로 교정해야 들어갈 수 있다 — 라벨까지 정말 동일하다면 같은 master가 맞다는 게 설계 입장. 단 hash는 내용 파생값이라 교정 시 바뀌므로 **영속 식별에는 쓰지 않는다**: 이미 업로드된 master의 후속 수정은 prod_master_id 기준 UPDATE로 한다 (§6.3).

**CHECK 제약** (기존 products에서 이동):

| 제약 | 내용 |
|------|------|
| `masters_not_okay_requires_bad_match` | `not_okay`이면 `bad_ingredients_detected` 1개 이상 |
| `masters_okay_requires_no_bad_match` | `okay`이면 `bad_ingredients_detected` 비어야 함 |
| `masters_insufficient_requires_empty_tokens` | `insufficient`이면 `ingredients_tokens` 비어야 함 |

**인덱스**: UNIQUE(ingredients_hash), (verdict), (verified_status)

#### `product_barcodes` — 바코드 변형 (서비스 테이블)

| 컬럼 | 타입 | 제약 | 설명 |
|------|------|------|------|
| `barcode` | text | PK, 8 또는 13자리 숫자 CHECK | EAN-8 / EAN-13 |
| `master_id` | uuid | FK → product_masters, NOT NULL, on delete restrict | |
| `size` | text | NOT NULL | 예: `24g`, `48g (24g×2번들)` |
| `image_url` | text | | Storage public URL. 변형마다 패키지 사진이 다를 수 있어 바코드 쪽 |
| `image_source_url` | text | | 원본 벤더 CDN URL (출처 기록용, RPC 비노출) |
| `created_at` | timestamptz | NOT NULL, default now() | |
| `updated_at` | timestamptz | NOT NULL, default now() | `tg_set_updated_at` 트리거 |

**인덱스**: (master_id)

**RLS**: 두 테이블 모두 `enable row level security` + 정책 0개 = **default-deny** (기존 products와 동일 보안 모델 — anon/authenticated는 RPC 경유만, service_role만 직접 접근). 0014에 포함하고, 적용 후 anon으로 직접 select가 거부되는지 검증한다.

재작성하는 RPC(lookup_product, log_pending_product)도 기존 하드닝을 그대로 유지하고 0014 검증 항목에 포함한다: `SECURITY DEFINER` + `set search_path = ''`, 본문 내 스키마 한정 참조, anon/authenticated execute grant 재부여, verified-only 필터 유지, `ingredients_raw`·`image_source_url` 비노출.

### 3.5 수집 테이블 생성 (로컬 전용)

`collected_products`는 **supabase/migrations에 넣지 않는다** — 운영에 배포되면 안 되는 로컬 전용 객체다. `pipeline/sql/collected_products.sql`로 별도 관리한다.

#### `collected_products` — 수집·정제·승격 추적 (로컬 전용)

| 컬럼 | 타입 | 제약 | 설명 |
|------|------|------|------|
| **식별** | | | |
| `id` | uuid | PK, default gen_random_uuid() | |
| `source` | text | NOT NULL, CHECK (`coupang` / `kakamuka`) | 데이터 소스 |
| `source_ref` | text | NOT NULL | 소스 내 productId. UNIQUE(source, source_ref) — 재실행 멱등 upsert 키 |
| **원본** | | | |
| `raw` | jsonb | NOT NULL | 적재 시점의 소스 레코드 병합 스냅샷 (products_page + manual_ingredients + extracted + koreannet 캐시 등). 디버깅·재파싱용 — 조회 1차 소스 아님 |
| **정제** | | | |
| `brand` | text | | title 파싱 결과. 실패 시 NULL (수동 보정 대상) |
| `name` | text | | |
| `size` | text | | |
| `category` | text | | 쿠팡 카테고리 폴더명 / kakamuka categories |
| `barcode` | text | CHECK: NULL 또는 8·13자리 숫자 | 형식 위반 원값은 raw에만 보존 |
| `ingredients_raw` | text | | 원재료 원문. 없으면 NULL (승격 불가 사유) |
| `confidence` | text | CHECK (`low` / `medium` / `high`, NULL 허용) | manual 육안 판독 신뢰도 |
| **산출 (룰 엔진)** | | | |
| `ingredients_tokens` | text[] | | 토크나이저 출력 |
| `verdict` | verdict_enum | | judge 단계에서 기록 |
| `bad_ingredients_detected` | text[] | | |
| `good_ingredients_detected` | text[] | | |
| `verdict_reason_codes` | text[] | | |
| `rule_version` | text | | |
| `computed_at` | timestamptz | | |
| **보강 (매칭)** | | | |
| `matched_ref` | text | | 쿠팡↔kakamuka 매칭 상대 (`source:ref` 형식) |
| `image_path` | text | | 로컬 정리본 경로 (`work/images/products/<barcode>.jpg`) |
| **상태** | | | |
| `stage` | text | NOT NULL, default 'raw', CHECK (`raw` / `parsed` / `tokenized` / `judged` / `promoted` / `conflict` / `rejected`) | 파이프라인 진행 단계 |
| `conflict_reason` | text | | stage='conflict'일 때 사유 (바코드 충돌 상대 등) |
| **승격** | | | |
| `promoted_master_id` | uuid | FK → product_masters | 승격된 로컬 master 추적 |
| `promoted_at` | timestamptz | | |
| `prod_master_id` | uuid | | 운영 업로드 후 반환된 **운영** master id — 로컬↔운영 영속 매핑 (§6.3) |
| **공통** | | | |
| `created_at` | timestamptz | NOT NULL, default now() | |
| `updated_at` | timestamptz | NOT NULL, default now() | `tg_set_updated_at` 트리거 |

**인덱스**: UNIQUE(source, source_ref), (stage), (barcode)

원칙:

- **정제 컬럼이 항상 1차 소스** — raw는 디버깅·재파싱용 스냅샷이지 조회 대상이 아니다
- 파이프라인 각 단계는 자기 컬럼을 채우고 stage를 올린다 — "토큰화 실패 목록" 같은 중간 산출물은 전부 SQL 쿼리로 대체 (별도 work/*.json 불필요)
- 인덱스: (stage), (barcode), UNIQUE(source, source_ref)

---

## 4. Phase 2 — 적재 파이프라인 (`pipeline/`)

HappyCart 레포에 `pipeline/` 디렉토리 신설. Python(ETL) + Dart(판정) 구성. 모든 단계는 collected_products의 stage 기반으로 동작하며 재실행 멱등이다.

```
pipeline/
  .env / .env.example      # 자격증명 (실값은 gitignore)
  .venv/                   # Python 가상환경 (psycopg)
  common.py                # DB 연결(.env 로드)·EAN 검증·upsert 헬퍼
  bootstrap_local.sh       # §3.3 DB 재생성 + 마이그레이션 + 0014 + collected_products
  run_pipeline.sh          # 아래 5단계 일괄 실행 (멱등)
  sql/collected_products.sql  # §3.5 수집 테이블 DDL (로컬 전용)
  extract_coupang.py       # 1단계 → stage='parsed'
  extract_kakamuka.py      # 2단계 → stage='parsed'
  match_enrich.py          # 3단계 (매칭·바코드 보강·충돌 표시)
  tokenizer.py             # 규칙 토크나이저 (순수 함수)
  tokenize_ingredients.py  # 4단계 → stage='tokenized' (+ --golden 테스트)
  judge.py                 # 5단계 (Dart 서브프로세스) → stage='judged'
  promote.py               # 6단계 → 서비스 테이블 승격, stage='promoted'
  prepare_images.py        # 7단계 (이미지 변환·정리) — 예정
  upload_prod.py           # Phase 3 (운영 반영) — 예정
```

### 4.1 extract_coupang.py

- 카테고리 8개 폴더의 `products*.json`을 productId 기준 dedup 병합
- title 파싱: `"롯데웰푸드 칸쵸 초코, 54g, 4개"` → brand / name / size 분해. 쿠팡 title 규칙(쉼표 구분 + 마지막 수량)을 휴리스틱으로 처리. 파싱 실패는 brand/name을 NULL로 두고 stage='parsed'에 머물게 해 SQL로 조회·수동 보정
- 원재료 결합: manual_ingredients(우선, confidence 보존) > extracted_data. 동일 productId 중복(242건)은 manual 채택
- 입력 조각 전체를 raw jsonb로 병합 보존, `(source='coupang', source_ref=productId)` upsert

### 4.2 extract_kakamuka.py

- `detail/*/info.json` 1,846건 → 바코드(1,822), 상품명(brand/name/size 파싱), 이미지 경로
- 바코드 검증: text로 유지(선행 0 보존, 숫자 캐스팅 금지), 8/13자리 형식 + **EAN-8/13 체크 디지트**까지 — 위반은 barcode NULL + raw에 원값 보존(검역) + 리포트. 쿠팡 쪽(§4.1) 바코드도 동일 검증을 통과해야 한다. 유효/무효 fixture 테스트 포함
- `(source='kakamuka', source_ref=productId)` upsert

### 4.3 match_enrich.py — 매칭·보강·충돌

매칭 축 3개 (모두 collected_products 안에서 SQL + Python):

1. **쿠팡 ↔ kakamuka**: 바코드 일치 우선, 없으면 정규화한 상품명 유사도. 매칭되면 쿠팡 행에 kakamuka 바코드·이미지를 보강하고 양쪽 `matched_ref` 기록
2. **수집 ↔ 서비스(기존 운영 데이터)**: product_barcodes와 바코드 대조 — 이미 있는 바코드는 `stage='conflict'` (운영 verified 행과의 충돌은 기본 "기존 유지")
3. **수집 내부 중복**: 동일 바코드가 다른 상품을 가리키면 양쪽 다 `stage='conflict'`

자동 병합하지 않는다. `stage='conflict'` + `conflict_reason`으로 표시하고, 수동 결정(스킵이면 `rejected`, 채택이면 stage 원복) 후 재실행하면 이어서 진행되는 구조.

- 이름 유사도 매칭은 보수적으로 — Koreannet 핸드오버에서 확인된 짧은 토큰 오매칭(`곰곰` 류) 교훈을 따른다. 애매하면 매칭하지 않는다

### 4.4 tokenize.py — 규칙 기반 토크나이저

ingredients_raw 보유 행 대상. ingredients_raw → ingredients_tokens 자동화 (현재 수작업뿐, 이번에 신설).

- 처리 규칙: 괄호 중첩(원산지·세부 구성 분리), 함량 표기(`79.5%`), 로마숫자 첨자(`밀가루Ⅰ`), 대괄호/중괄호 하위 성분 전개, 구분자(쉼표·슬래시)
- 하위 성분 전개 정책은 **기존 시드와 동일하게**: 시드 50건의 (ingredients_raw → ingredients_tokens) 쌍을 운영 dump에서 추출해 **golden test**로 삼고, 토크나이저 출력이 일치할 때까지 규칙을 다듬는다
- 일치 불가능한 케이스(시드 자체의 수작업 편차)는 테스트에서 예외 목록으로 명시하고 사유를 적는다
- 성공 시 stage='tokenized'. 파싱 실패는 stage 유지 — `where stage='parsed' and ingredients_raw is not null`로 실패 목록 조회

### 4.5 judge.py — Dart 룰 엔진 판정

- `happycart/tool/compute_verdicts.dart`를 확장해 **JSON 입출력 모드** 추가 (현재는 시드 SQL 출력 전용): tokens 배열 입력 → verdict, bad/good_ingredients_detected, verdict_reason_codes, rule_version 출력
- Python에서 서브프로세스로 일괄 호출, 결과를 산출 컬럼에 기록 후 stage='judged'. 룰 엔진은 `packages/happycart_rules` 단일 소스 유지
- **rule_version 기반 resync 설계**: 판정 대상 선정을 `stage='tokenized'`뿐 아니라 `rule_version is distinct from <엔진 현재 버전>`인 행까지 포함하도록 처음부터 설계한다 (`<>`는 NULL 행을 못 잡으므로 NULL-safe 비교 필수 — 수집 테이블의 rule_version은 nullable). 이러면 룰 변경 시 judge.py 재실행만으로 구버전 행이 자동 재계산된다 (§7 참고). `--target masters` 옵션으로 product_masters도 같은 로직으로 재계산 가능하게 한다

### 4.6 promote.py — 서비스 테이블 승격

승격 조건: `stage='judged'` **and** `barcode is not null` **and** `ingredients_raw`/tokens 보유 **and** `brand`·`name`·`size` 모두 NOT NULL (서비스 테이블의 NOT NULL 제약과 정합 — title 파싱 실패 행이 judged까지 올라와도 여기서 걸러진다) **and** `confidence is distinct from 'low'` (저신뢰 육안 판독은 재판독 대기 — 틀린 원재료로 계산된 verdict가 서비스에 가지 않게).

- 조건 미충족 행은 stage='judged'에 머문다. 별도 stage를 추가하지 않고 `where stage='judged' and (brand is null or ...)` 조회로 수동 보정 대상을 관리한다
- **master 그룹핑**: 분리 계획과 동일 기준 — `ingredients_raw` 완전 일치 + `brand` 일치 → 같은 master
- **그룹핑 검토 리포트**: 2건 이상이 한 master로 묶인 그룹은 전수 출력해 사람이 확인한다. 그룹 내 `name`이 size 차이 이상으로 다르면 (변형이 아니라 별개 상품 의심) 해당 그룹은 승격 보류 — 잘못된 병합은 위험하고 보류는 안전하다
- master upsert 후 반환 id로 product_barcodes upsert. `verified_status='unverified'`(앱 비노출), `source` 소스별 명시 (`쿠팡 크롤링 + 직접 판독` 등), `source_url`, `source_checked_at`은 크롤링 시점
- 승격 행에 `promoted_master_id`, `promoted_at` 기록, stage='promoted' — 재실행 시 promoted는 건너뜀 (멱등)
- 승격 후 검증 쿼리: 승격 행 수 = 신규 barcodes 행 수, master 수 = 그룹핑 기대값, CHECK 위반 0건, EAN 체크섬 위반 바코드 승격 0건
- 승격 리포트: source별·confidence별 승격/보류 건수 출력
- **미달 건은 수집 테이블에 머문다**: 무바코드(원재료만 있음), 원재료 없음(kakamuka 단독 등). 추후 보강되면 stage가 올라가 다음 promote 때 승격

### 실측 규모 (2026-06-12 extract 후)

| 구분 | 실측 |
|------|------|
| collected_products | 6,223행 (쿠팡 4,501 + kakamuka 1,722) |
| 즉시 승격 후보 (바코드∩원재료) | **201건** + kakamuka 매칭으로 바코드 보강되는 건 |
| 승격 후 product_masters | ~200 미만 (동일 원재료 그룹핑으로 감소) |
| 승격 대기 (무바코드·원재료 없음) | ~6,000건 — 바코드 보강(Koreannet 재개)·라벨 판독이 후속 작업 |

> 최초 계획의 707건 추정은 placeholder 오산이었다 (§2 교정 참고). 물량 확대의 병목은 **라벨 판독**(원재료 552/4,501)과 **바코드 보강**(717/4,501) 양쪽이다.

---

## 5. Phase 2.5 — 이미지 처리 (prepare_images.py)

- **승격된(바코드 확정) 행에 한해** 이미지를 `pipeline/work/images/products/<barcode>.jpg`로 변환·정리. collected_products.image_path와 **로컬 product_barcodes.image_source_url을 함께 갱신** (서비스 테이블의 출처 기록이 이미지 준비와 같은 단계에서 완결되도록)
- 소스 우선순위: 쿠팡 detail 이미지(패키지 정면) > Koreannet images_page* > kakamuka detail 이미지 > 쿠팡 CDN 썸네일
- 규격: JPEG 변환(PNG 원본 포함), 512KB 이하 (Storage 버킷 제한), 기존 `upload_product_image.py` 변환 로직 재사용
- 산출물로 **이미지 manifest**를 생성: barcode, 원본 출처 URL, 로컬 경로, checksum, Storage 대상 경로. §6.4 업로드는 디렉토리 glob이 아니라 이 manifest를 입력으로 사용
- `image_url`(Storage public URL)은 운영 업로드 성공 후 채운다
- 변형(바코드)별 패키지가 다르므로 이미지는 barcode 단위로 관리 (분리 계획 §2와 정합)

---

## 6. Phase 3 — 운영 Supabase 반영

로컬에서 전 단계 검증이 끝난 뒤 진행. **운영에 올라가는 것은 서비스 테이블의 승격분뿐이다** — collected_products는 로컬에만 존재한다. 순서 고정:

1. **0014 push**: `supabase db push` — 분리 계획 §4의 절차·검증(전수 lookup diff) 그대로
   - 0014에 구 products **쓰기 동결 트리거** 포함 (insert/update 시 raise exception) — "같은 날 전환, 그 사이 업로드 금지"라는 운영 약속을 DB가 강제한다. service_role은 RLS를 우회하므로 구 경로 도구가 실수로 쓰는 것을 막을 다른 수단이 없다. 읽기는 허용(롤백 대조용), 0015에서 테이블과 함께 제거
2. **업로드 파이프라인 전환**: upload_to_supabase.py(happycart_crawler 레포) 2단계 upsert 수정 반영 (분리 계획 §3). 0014 push와 같은 날 — 동결 트리거 덕에 그 사이 구 경로 업로드는 실패로 드러난다
3. **승격 데이터 업로드** (`pipeline/upload_prod.py`): 로컬 서비스 테이블에서 승격분(~201건+)을 읽어 service_role로 운영에 upsert
   - **로컬 master id(uuid)를 운영에 그대로 쓰지 않는다** — 로컬 0014와 운영 0014가 각각 uuid를 생성하므로 동일 master라도 id가 다르다. 운영에는 `ingredients_hash`(UNIQUE, §3.4)를 conflict target으로 master를 upsert하고, 반환된 **운영 id**로 barcode 행을 연결한다 (분리 계획의 upload_to_supabase.py 2단계 upsert와 동일 패턴)
   - **hash는 최초 매칭·중복 방지용, 영속 식별자는 uuid** — 업로드 성공 시 반환된 운영 id를 collected_products.`prod_master_id`에 기록한다. 이후 brand/원문을 교정하면 hash가 바뀌므로, 이미 업로드된 master의 수정은 hash 재upsert가 아니라 **prod_master_id 기준 UPDATE**로 반영한다 (재upsert는 중복 master를 만든다). master 분리/병합이 필요한 수준의 교정은 이번 범위 밖 — 발생 시 건별 수동 처리
   - **verified 보호를 SQL 가드로 강제** — service_role은 RLS를 우회하므로 코드 규약만으로는 부족하다. `on conflict (ingredients_hash) do update set ... where product_masters.verified_status <> 'verified'` 형태로 쿼리 자체에 가드를 넣고, RETURNING으로 갱신되지 않은 충돌 건을 감지해 수동 검토 리포트로 보낸다
   - **기존 verified master에 새 barcode가 붙는 케이스는 자동 업로드에서 제외** — verified_status가 master 단위라서 연결 즉시 새 바코드가 lookup_product에 노출된다. 크롤링 유래의 barcode-master 연결은 그 정도 신뢰가 없으므로, 해당 건은 검토 리포트로 분리해 Data Desk 확인 후 수동 연결한다. (unverified master에 붙는 barcode는 어차피 비노출이라 자동 업로드)
   - 운영의 `verified` 행은 절대 덮어쓰지 않음 (§4.3에서 conflict 처리 완료된 상태)
   - 배치 단위 커밋 + 재실행 가능 (멱등 upsert)
   - 업로드 후 검증: 운영/로컬 행 수 대조, barcodes의 master FK 고아 0건, lookup_product 샘플 호출
4. **이미지 업로드**: §5의 manifest를 입력으로 Storage product-images 버킷에 업로드 (디렉토리 glob 아님 — barcode에 묶인 항목만). checksum으로 이미 업로드된 건은 스킵, 성공 건만 `image_url` 갱신
5. **pending_products 소급 처리**: 새로 등록된 바코드가 pending에 있으면 `status='registered'`로 갱신하는 쿼리 1회 실행
   - **정책 명확화**: pending의 의미는 "DB에 데이터 자체가 없음"으로 유지한다. unverified로 등록돼도 pending은 닫고(registered), log_pending_product의 존재 확인도 0013과 동일하게 verified 여부와 무관한 product_barcodes 존재 기준으로 한다. 등록 후 사용자가 여전히 lookup에서 못 찾는 문제는 pending이 아니라 **Data Desk 검증 큐(unverified masters)** 가 담당한다
   - 소급 처리는 status 변경일 뿐 행이 삭제되지 않으므로 `scan_count`·`last_scanned_at`은 보존된다 — 수요 신호는 사라지지 않는다. Data Desk 검증 큐는 별도 인계 산출물이 아니라 **운영 DB 쿼리(또는 뷰)로 정의**한다: unverified master ← product_barcodes ← pending_products(registered) 조인, scan_count 내림차순. 이 쿼리를 인계 문서에 수록해 검증 우선순위 신호로 사용
6. **SCHEMA.md 갱신** + Data Desk 인계 문서 갱신 (분리 계획 §3)
7. 1주 안정화 후 **0015**(구 products drop) — 분리 계획 §4 그대로

### 실패 복구·멱등성

업로드는 어느 단계에서 끊겨도 재실행으로 이어갈 수 있어야 한다.

- **순서 고정**: master/barcode upsert → 이미지 업로드 → image_url 갱신 → pending 소급. 각 단계는 앞 단계 완료를 전제하되 자체적으로 멱등
- **트랜잭션 경계**: master와 그에 딸린 barcodes는 같은 트랜잭션으로 커밋 — FK 고아가 생기는 중간 상태 금지. 배치 간에는 커밋 (중단 시 완료 배치는 보존)
- **이미지**: manifest checksum으로 업로드 완료 건 스킵, `image_url` 갱신은 업로드 성공 건만
- **pending 소급**: 운영 product_barcodes 존재 기준으로 매번 다시 계산되는 쿼리 — 몇 번 실행해도 동일 결과
- **dry-run**: 실행 전 단계별 예상 건수(신규 master/기존 재사용/barcode/이미지/pending) 출력 후 확인하고 진행
- **reconciliation**: 실행 후 대조 쿼리 일괄 실행 — 로컬/운영 행 수, barcodes FK 고아 0건, 업로드 대상 중 image_url NULL 잔여, registered 전환 누락 pending

---

## 7. 룰 변경 시 재계산 전략

verdict·bad/good_detected·reason_codes는 `ingredients_tokens`에서 룰 엔진이 결정적으로 산출하는 **파생 데이터**다. 입력(tokens)과 버전(rule_version)이 행에 보존되므로 룰이 바뀌면 재계산하면 되고, **verdict를 수동으로 수정하지 않는다**. 0008(rule v1.1.0 resync)이 선례.

분리 구조의 이점: 재계산이 master 단위 1회로 끝난다 (변형 바코드 수와 무관). tokens가 보존되어 있어 재토큰화 없이 judge 단계만 재실행하면 된다.

### 절차

1. `packages/happycart_rules`에서 룰 수정 + 버전 bump (예: v1.2.0) + 룰 패키지 테스트 통과
2. **로컬에서** judge.py 재실행 — product_masters와 collected_products(judged 이상) 양쪽. `rule_version is distinct from 현재 버전`인 행만 자동으로 잡힌다 (§4.5)
3. **diff 리포트 검토**: verdict가 뒤집힌 상품 목록(`okay→not_okay`, `not_okay→okay`)이 핵심 검토 지점. 룰 변경의 실제 영향을 눈으로 확인한 뒤 진행
4. 운영 반영: 0008 선례처럼 마이그레이션으로 하거나 service_role 재계산 스크립트로. masters만 갱신, barcodes는 무관
5. 앱 변경 불필요 — lookup_product가 새 verdict를 그대로 반환

### 주의

- **verified_status는 건드리지 않는다** — verified는 "원재료 데이터가 정확하다"는 뜻이고 verdict는 파생값. 단, verdict가 뒤집힌 행 목록은 Data Desk에 공유한다 (사용자가 보는 판정이 바뀌므로)
- **토크나이저 규칙 변경은 더 깊은 변경** — tokenize → judge를 둘 다 재실행하고 golden test 50건도 함께 갱신해야 한다. `ingredients_raw`가 master와 collected 양쪽에 보존되어 있어 가능
- CHECK 제약 3종(verdict ↔ bad/tokens 정합)은 엔진 출력이 자동으로 만족시킨다

---

## 8. 작업 순서 체크리스트

1. `bootstrap_local.sh` → Docker postgres + 00_compat + 마이그레이션(시드 포함, 0011 제외) → 검증: 적용 성공 ✅ 2026-06-16
2. 시드 = 운영 베이스라인 (dump 불필요, §3.3) → 검증: products 8건, 전부 verified ✅ 2026-06-16
3. 0014 작성·적용 → 검증: 전수 lookup diff 0건 + RLS default-deny (anon 거부) + RPC 하드닝 + masters/barcodes 각 8건 ✅ 2026-06-16
4. collected_products DDL 적용 (pipeline/sql, 로컬 전용) ✅ 2026-06-16
5. extract_coupang / extract_kakamuka → 검증: 실측치(4,524 / 1,722·1,642)와 행 수 일치 ✅ 2026-06-16
6. match_enrich → conflict 행 검토·수동 결정 → 재실행. 실측: A 교차매칭 60, 중복리스팅 58 rejected, 오매칭 의심 162 conflict, **시드 충돌 2** ✅ 2026-06-16
7. tokenize → golden 8/8 (예외 3건 문서화), 418행 토큰화 ✅ 2026-06-16
8. compute_verdicts JSON 모드 확장 + judge → SQL 출력 byte-identical 확인, 418행 판정 ✅ 2026-06-16
9. promote → 113건 승격(masters/barcodes 각 121=시드 8+113), CHECK·FK 위반 0 ✅ 2026-06-16
10. prepare_images → 검증: 샘플 수십 건 육안 확인, 512KB 초과 0건 (예정)
11. (운영 반영) §6 순서대로 1→7 (예정)

---

## 9. 리스크 & 대응

| 리스크 | 대응 |
|--------|------|
| 단독 postgres와 운영 Supabase의 환경 차이 (롤·확장·버전) | 00_compat.sql로 차이를 명시적으로 관리, 운영과 동일 메이저 버전 고정. 0014는 운영 push 전 로컬 검증 외에 push 시 supabase의 dry-run 확인 |
| collected_products가 실수로 운영에 배포 | supabase/migrations에 넣지 않고 pipeline/sql로 격리. db push 전 마이그레이션 목록 확인 |
| 쿠팡 title 파싱(brand/name/size) 오류 | 파싱 실패는 stage에 남아 SQL로 전수 조회 + 수동 보정 루프. brand 오류는 master 그룹핑 오판으로 이어지므로 그룹핑은 ingredients_raw 일치를 1차 기준으로 |
| 토크나이저가 시드 토큰과 미세 불일치 → 동일 상품의 verdict가 기존과 달라짐 | golden test 50건 강제. **이번 적재에서는** 기존 행을 재토큰화·재판정하지 않는다 (rule_version 동일하므로 §4.5 resync 대상도 아님). 추후 룰 버전 변경 시의 전체 재계산은 §7 정책(verified 포함 재계산 + diff를 Data Desk 공유)을 따른다 |
| 이름 유사도 매칭 오류 (쿠팡↔kakamuka) | 보수적 임계값 + 자동 병합 금지(conflict→수동 결정). 잘못된 매칭은 잘못된 바코드 연결로 직결되므로 애매하면 버린다 |
| raw jsonb와 정제 컬럼의 이중 진실 | raw는 "적재 시점 병합 스냅샷"으로 정의 고정, 정제 컬럼이 항상 1차 소스 |
| 운영 업로드 중단·부분 실패 | 멱등 upsert + 배치 커밋으로 이어서 재실행. 업로드 전 운영 dump 백업 |
| 승격 물량이 적음 (201건 수준 — 최초 추정 707은 placeholder 오산) | 의도된 보수성. 물량 확대는 라벨 판독(원재료 552/4,501)·바코드 보강(717/4,501) 후속 작업으로 — 수집 테이블에 대기 중이므로 보강 즉시 승격 가능 |

---

## 10. 이번 범위에서 제외 (추후 검토)

- 바코드 0인 6개 카테고리의 Koreannet 바코드 보강 작업 재개 (CoupangCrawler 레포, 별도 작업)
- 원재료 없는 상품의 원재료 수급 (라벨 판독 작업 연장)
- 변형 자동 감지·master 자동 dedup (분리 계획 §7과 동일)
- scan_events 로컬 분석 환경
- 수집 테이블 기반 Data Desk 검토 UI (현재는 SQL 직접 조회로 운용)
