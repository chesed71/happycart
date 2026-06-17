# 데이터 수집 → HappyCart 앱 — 전체 흐름

> **목적**: 크롤링 데이터 수집부터 사용자 앱 노출까지의 end-to-end 파이프라인을 한 장으로 본다. 각 단계의 적용 상태(로컬 ✅ / 운영 ❌)와 담당 컴포넌트를 정리한다.

- 작성일: 2026-06-17 (2026-06-17 정정: 2-verdict·마이그레이션 재번호·PR 머지 반영)
- 관련 스펙: `2026-06-11-products-table-split-plan.md`(products 분리), `2026-06-11-local-db-data-ingestion-plan.md`(적재 파이프라인), `2026-06-16-datadesk-collected-products-plan.md`(Data Desk 직결)
- **마이그레이션 번호**: `0014_remove_insufficient_verdict.sql`(verdict를 okay/not_okay 2단계로) + `0015_split_products.sql`(products → masters/barcodes 분리). 분리는 0015.
- **verdict는 okay / not_okay 2단계** (insufficient 제거됨).

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
 ③ Data Desk 검수  (review-sveltekit, mac-mini)               [✅ collected 직결]
═══════════════════════════════════════════════════════════════════════════════
        ┌───────────────┴───────────────────────┴───────────────┐
        │ 원재료 검수 화면: 바코드·원재료 판독 + 확인완료          │
        │  → review_collected_product() RPC (datadesk_review 롤)  │
        │  확인완료 = review_decision='verified'                  │
        └───────────────┬────────────────────────────────────────┘
                        │ promote.py  [게이트] barcode+원재료+판정+verified
                        ▼
═══════════════════════════════════════════════════════════════════════════════
 ④ 서비스 테이블 (로컬)                                        [✅ 로컬 / ❌ 운영]
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
 ⑤ 운영 반영 — Phase 3                                    [✅ 스키마 완료 / 업로드 도구 준비]
┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┼┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄
                        │ ① supabase db push (0014 2-verdict + 0015 분리)  ✅ 적용됨
                        │ ② upload_prod.py (승격분만 upsert, REST/postgres)  ✅ 작성·검증
                        │ ③ 이미지 업로드 → image_url                       (예정)
                        │   (Data Desk 등록 로직 수정 불필요 — pending status 전이만 함)
                        ▼
═══════════════════════════════════════════════════════════════════════════════
 ⑥ 운영 Supabase (ftgsnvvskbadegswvjnp)              [✅ 분리 적용됨 — masters 50/barcodes 51]
═══════════════════════════════════════════════════════════════════════════════
        product_masters / product_barcodes   ← 이미 운영 카탈로그(50/51, verified)
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
| ⑤ | 운영 반영 (Phase 3) | db push ✅ + 승격분 업로드(도구 준비) | 운영 서비스 테이블 |
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

**배포(운영 Supabase)**: 스키마 분리 ✅ 적용됨 (2026-06-17 REST로 확인). 데이터 업로드는 도구 준비 완료.

| 환경 | 스키마(0014 verdict / 0015 분리) | 파이프라인 | Data Desk 직결 |
|------|--------------------------------|-----------|----------------|
| 로컬 Docker (`happycart`) | ✅ 2-verdict + 0015 분리 (main 동기화 완료) | ✅ (실측 6,223행) | ✅ |
| **운영 Supabase** | ✅ **분리 적용됨** — masters 50 / barcodes 51, 전부 verified, lookup_product 정상 | — | `/pending` 탭만 운영 연결 |

- **운영은 이미 분리 완료** — products 51(frozen) → masters 50 / barcodes 51. 앱은 새 스키마로 정상 동작 중(lookup_product 13컬럼 그대로).
- **"시드 8 = 운영 베이스라인"은 틀림** — 운영엔 별도로 키워온 카탈로그 50/51이 있다. 로컬(시드 8)은 운영의 부분집합이 아니라 **크롤 기반 신규 상품 공급원**. 기존 50건은 ingredients_hash 가드로 보호된다.
- `upload_prod.py`는 REST(service_role 키)·postgres 두 백엔드. dry-run으로 운영 읽기·verified 가드 검증 완료(쓰기 0). **실제 업로드는 로컬 승격분이 생길 때**(현재 0건).
- **Data Desk 등록 로직**: pending 탭은 `pending_products` status 전이만 — 분리 무관, 고칠 것 없음.
- 안전·동시성 보강은 `pipeline/test_invariants.py` 32종으로 회귀 방지 (RPC 잠금·promote 경쟁·rollback 손상 데이터·최소권한 등).

---

## 컴포넌트 레퍼런스

| 레이어 | 파일/객체 | 레포 |
|--------|----------|------|
| 수집 | `products*.json`, `manual_ingredients_*`, `detail/*/info.json` | CoupangCrawler, DataCollector |
| 파이프라인 | `pipeline/extract_*.py`, `match_enrich.py`, `tokenize_ingredients.py`, `judge.py`, `promote.py` | HappyCart |
| 룰엔진 | `packages/happycart_rules`, `happycart/tool/compute_verdicts.dart --json` | HappyCart |
| 수집 테이블·RPC | `pipeline/sql/collected_products.sql`, `review_rpc.sql`, `rollback_ungated_promotions.sql` | HappyCart (로컬 전용) |
| 마이그레이션 | `supabase/migrations/0014_remove_insufficient_verdict.sql`(2-verdict), `0015_split_products.sql`(분리) | HappyCart |
| Data Desk | `review-sveltekit/` (collectedReviewData, review-items PATCH, +page.svelte) | happycart_crawler |
| 앱 | Flutter (anon key) → `lookup_product`, `log_pending_product` | HappyCart |

---

## 다음 작업

- ✅ **로컬 재동기화 완료** (2026-06-17): 2-verdict·0014/0015 재번호로 bootstrap·judge·review 롤 정정, 32/32 통과.
- ✅ **운영 스키마 분리 적용됨**, `upload_prod.py`(REST/postgres) 작성·검증 완료.
- **실제 업로드 대기**: 로컬 검수·승격분이 생기면 `upload_prod.py --dry-run` → 실행. 쓰려면 `pipeline/.env`에 `SUPABASE_URL`/`SUPABASE_SERVICE_ROLE_KEY` 필요.
- (예정) 이미지 업로드 → image_url, pending 소급.
- 물량 확대: Koreannet 바코드 보강(6개 카테고리 미진행)·라벨 판독 — 보강 즉시 collected_products에서 승격 가능.
