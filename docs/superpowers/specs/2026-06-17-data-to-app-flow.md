# 데이터 수집 → HappyCart 앱 — 전체 흐름

> **목적**: 크롤링 데이터 수집부터 사용자 앱 노출까지의 end-to-end 파이프라인을 한 장으로 본다. 각 단계의 적용 상태(로컬/운영, main 반영 여부)와 담당 컴포넌트를 정리한다.

- 작성일: 2026-06-17 (2026-06-17 정정: 2-verdict·마이그레이션 재번호·PR 머지 반영)
- 관련 스펙: `2026-06-11-products-table-split-plan.md`(products 분리), `2026-06-11-local-db-data-ingestion-plan.md`(적재 파이프라인), `2026-06-16-datadesk-collected-products-plan.md`(Data Desk 직결)
- **마이그레이션 번호**: `0014_remove_insufficient_verdict.sql`(verdict를 okay/not_okay 2단계로) + `0015_split_products.sql`(products → masters/barcodes 분리). 분리는 0015.
- **verdict는 okay / not_okay 2단계** (insufficient 제거됨).
- **운영 Supabase는 prod `sfnjgzzexshhjlkygnmq`**, 개발은 dev `ftgsnvvskbadegswvjnp`. Play 배포본(production flavor)은 prod 를 본다. Data Desk 도 prod 직결이며, 서비스 테이블 편집은 `save_service_product`(0018, service_role 전용) 로 한다. 이 문서 본문에서 "운영"은 prod 를 가리킨다.

---

## 전체 도식

```
═══════════════════════════════════════════════════════════════════════════════
 ① 데이터 수집 (크롤링)                                              [별도 레포]
═══════════════════════════════════════════════════════════════════════════════
 ┌─ CoupangCrawler ──────────────┐   ┌─ DataCollector (kakamuka) ───┐
 │ products*.json (4,524 고유)    │   │ detail/*/info.json (1,722)    │
 │ manual_ingredients (원재료 552)│   │ 바코드 1,642 · 원재료 없음     │
 │ Koreannet 바코드 717 · 이미지  │   │ 이미지 1,886                  │
 └───────────────┬───────────────┘   └───────────────┬───────────────┘
                 │                                     │
═══════════════════════════════════════════════════════════════════════════════
 ② 로컬 파이프라인 (Docker postgres :54322)                    [✅ 로컬 전용]
═══════════════════════════════════════════════════════════════════════════════
   extract_coupang/kakamuka.py        (JSON → parsed)
                 │
   match_enrich.py    바코드 교차매칭·보강, 충돌(conflict)·중복(rejected) 표시
                 │
   tokenize_ingredients.py   원문 → ingredients_tokens (규칙 토크나이저, golden)
                 │
   judge.py → compute_verdicts.dart(--json)   룰엔진 → verdict/bad/good
                 ▼
        ┌──────────────────────────────────────────────────────┐
        │      collected_products  (로컬 전용 수집 테이블)        │
        │  stage: raw→parsed→tokenized→judged→promoted           │
        │         (분기: conflict / rejected)                    │
        └───────────────┬───────────────────────▲───────────────┘
                        │ 읽기/쓰기(직접 postgres) │ review RPC (SECURITY DEFINER)
═══════════════════════════════════════════════════════════════════════════════
 ③ Data Desk 검수  (review-sveltekit, mac-mini)     [✅ collected 직결 + 운영은 prod 직결]
═══════════════════════════════════════════════════════════════════════════════
        ┌───────────────┴───────────────────────┴───────────────┐
        │ 원재료 검수 화면: 바코드·원재료 판독 + 확인완료          │
        │  → review_collected_product() RPC (datadesk_review 롤)  │
        │  확인완료 = review_decision='verified'                  │
        └───────────────┬────────────────────────────────────────┘
                        │ promote.py  [게이트] barcode+원재료+판정+verified
                        ▼
═══════════════════════════════════════════════════════════════════════════════
 ④ 서비스 테이블 — 로컬 승격 산출                              [✅ 로컬 파이프라인 출력]
═══════════════════════════════════════════════════════════════════════════════
        ┌──────────────────┐ 1     N ┌───────────────────┐
        │ product_masters  │◀────────│ product_barcodes  │
        │ (원재료·판정)      │   FK    │ (바코드·size·이미지)│
        └──────────────────┘         └───────────────────┘
          verified_status = 'unverified'  (아직 앱 비노출)
                        │
          Data Desk 검증 → verified_status='verified'  (앱 노출 승인)
                        │
┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┼┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄
 ⑤ 운영 반영 — Phase 3                        [✅ 스키마·업로드 도구·이미지 모두 완료]
┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┼┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄
                        │ ① supabase db push (0014 2-verdict + 0015 분리)  ✅ 적용됨
                        │ ② upload_prod.py (승격분만 upsert, REST/postgres)  ✅ main 반영
                        │ ③ 이미지 업로드 → image_url                       ✅ 완료(699장 prod)
                        │   (Data Desk 는 prod 직결 — pending status 전이 + 서비스 테이블 편집)
                        ▼
═══════════════════════════════════════════════════════════════════════════════
 ⑥ 운영 Supabase (sfnjgzzexshhjlkygnmq = prod)        [masters 699/barcodes 700, 노출 221]
═══════════════════════════════════════════════════════════════════════════════
        product_masters / product_barcodes   ← 운영 카탈로그(699/700, 앱 노출 221)
        Storage (product-images)
        pending_products  ◀────────────────────────────┐
                        │ lookup_product() RPC (anon)   │ log_pending_product()
                        ▼                               │ (미등록 바코드 적재)
═══════════════════════════════════════════════════════════════════════════════
 ⑦ HappyCart 앱 (Flutter, anon key)
═══════════════════════════════════════════════════════════════════════════════
        바코드 스캔 ──► lookup_product(barcode)
            │            ├─ verified 있음 → 판정/원재료/이미지 표시
            │            └─ 없음 → log_pending_product → pending_products ─┘ (재유입)
            ▼
        사용자: okay / not_okay 판정 확인 (2단계)

  범례:  ✅ 적용됨   (예정) 미작업   ┄┄ 로컬↔운영 경계
```

---

## 단계별 설명

| # | 단계 | 핵심 | 산출물 |
|---|------|------|--------|
| ① | 데이터 수집 | 쿠팡·kakamuka 크롤링 (별도 레포) | JSON·이미지 파일 |
| ② | 로컬 파이프라인 | extract→match→tokenize→judge | `collected_products` (stage 진행) |
| ③ | Data Desk 검수 | 원재료·바코드 판독 + 확인완료 | `review_decision='verified'` |
| ④ | 승격 | barcode+원재료+판정+verified 게이트 | `product_masters`/`product_barcodes` (unverified) |
| ⑤ | 운영 반영 (Phase 3) | db push ✅ + 승격분 업로드(`upload_prod.py`, main 반영) | prod 서비스 테이블 |
| ⑥ | 운영 Supabase | lookup_product / pending (분리 적용됨) | 앱이 조회하는 DB |
| ⑦ | HappyCart 앱 | 바코드 스캔 → 판정 표시 | 사용자 노출 |

### 두 개의 사람 게이트

1. **원재료 검수 (③)** — 원재료/바코드가 정확한가? 확인완료(`review_decision='verified'`)해야 승격 자격.
2. **노출 검증 (④)** — 앱에 내보내도 되는가? `verified_status='verified'`로 전환해야 `lookup_product`에 노출.

승격된 행은 `unverified`로 올라가 앱에 안 보이며, 노출 검증을 따로 통과해야 한다.

### pending 순환

앱에서 미등록 바코드를 스캔하면 `log_pending_product`가 `pending_products`에 적재 → Data Desk 검수로 재유입된다 (도식의 점선 루프). scan_count가 검증 우선순위 신호가 된다.

---

## 적용 상태 (2026-06-17)

**코드(PR)**: 양쪽 머지 완료.
- HappyCart: PR #2 `feature/collected-products-pipeline` **머지**. 이후 main에서 insufficient 제거(2-verdict)·마이그레이션 0014/0015 재번호가 추가됨.
- Data Desk: 원본 PR #1은 closed, 변경은 `fix/datadesk-security-hardening` PR로 **머지**(+ localStorage quota 안전처리 등 하드닝).

**배포(운영 Supabase)**: 아래 표는 **2026-08-10 실측 기준**이다(그 이전 수치는 dev 를 운영으로 쓰던 시절의 것).

| 환경 | 스키마 | 파이프라인 | Data Desk 직결 |
|------|--------|-----------|----------------|
| 로컬 Docker (`happycart`) | ✅ 2-verdict + 0015 분리 (main 동기화 완료) | ✅ (실측 6,223행) | ✅ collected_products |
| **운영 Supabase (prod)** | ✅ 0018 까지 적용 — masters 699 / barcodes 700, verified 220(앱 노출 바코드 221) | `upload_prod.py` (prod 자격증명 필요) | ✅ `/products`·`/pending` 둘 다 prod |
| 개발 Supabase (dev) | ✅ 0018 까지 적용 (prod 와 동일 스키마) | — | — (개발 빌드·dev 웹 전용) |

- **prod 는 dev 의 2026-07-23 스냅샷을 그대로 물려받았다** — masters/barcodes 수량과 `ingredients_hash` 집합 해시가 dev 와 일치한다. Data Desk 수동 편집분(`rule_version='manual'`) 160건도 포함.
- 앱 노출은 `verified_status='verified'` 인 것만이다(lookup_product 게이트). 전체 699/700 중 **바코드 221건**이 실제 서비스 대상.
- `upload_prod.py`(REST(service_role 키)·postgres 두 백엔드 + 0016 RPC)는 **main 반영 완료**. 다만 `pipeline/.env` 가 없어 `SUPABASE_URL` 이 비어 있고 `.env.local` 의 SERVICE_ROLE_KEY 는 dev 것이므로, **prod 에 올리려면 prod 자격증명을 명시해야 한다**.
- **Data Desk 는 prod 직결**이다. `/pending` 은 `pending_products` status 전이, `/products` 는 `save_service_product`(0018, service_role 전용)로 서비스 테이블을 편집한다.
- 안전·동시성 보강은 `pipeline/test_invariants.py` 32종으로 회귀 방지 (RPC 잠금·promote 경쟁·rollback 손상 데이터·최소권한 등).

---

## 컴포넌트 레퍼런스

| 레이어 | 파일/객체 | 레포 |
|--------|----------|------|
| 수집 | `products*.json`, `manual_ingredients_*`, `detail/*/info.json` | CoupangCrawler, DataCollector |
| 파이프라인 | `pipeline/extract_*.py`, `match_enrich.py`, `tokenize_ingredients.py`, `judge.py`, `promote.py` | HappyCart |
| 룰엔진 | `packages/happycart_rules`, `happycart/tool/compute_verdicts.dart --json` | HappyCart |
| 수집 테이블·RPC | `pipeline/sql/collected_products.sql`, `review_rpc.sql`, `rollback_ungated_promotions.sql` | HappyCart (로컬 전용) |
| 마이그레이션 | `supabase/migrations/0014_remove_insufficient_verdict.sql`(2-verdict), `0015_split_products.sql`(분리), `0018_save_service_product.sql`(Data Desk 편집 RPC) | HappyCart |
| Data Desk | `review-sveltekit/` (collectedReviewData, review-items PATCH, +page.svelte) | happycart_crawler |
| 앱 | Flutter (anon key) → `lookup_product`, `log_pending_product` | HappyCart |

---

## 다음 작업

- ✅ **로컬 재동기화 완료** (2026-06-17): 2-verdict·0014/0015 재번호로 bootstrap·judge·review 롤 정정, 32/32 통과.
- ✅ **운영 스키마 분리 적용됨** (운영 Supabase에 masters/barcodes 존재).
- ✅ **`upload_prod.py` main 반영 완료**. 운영 RPC 0016 도 prod 에 적용됨(prod 는 0018 까지).
- ✅ **이미지 업로드 완료** (2026-08-10): dev Storage 의 `product-images` 699장을 prod 로 복사하고 prod `image_url` 을 prod ref 로 치환 — dev 참조 0건.
- **실제 업로드 대기**: 로컬 검수·승격분이 생기면 `upload_prod.py --dry-run` → 실행. 쓰려면 `pipeline/.env`에 **prod** 의 `SUPABASE_URL`/`SUPABASE_SERVICE_ROLE_KEY` 필요(`.env.local` 의 키는 dev 것이라 그대로 쓰면 dev 로 올라간다).
- (예정) pending 소급.
- 물량 확대: Koreannet 바코드 보강(6개 카테고리 미진행)·라벨 판독 — 보강 즉시 collected_products에서 승격 가능.
