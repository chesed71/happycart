# Data Desk 원재료 검수 → collected_products 직결 계획 (옵션 B)

> **목적**: HappyCart Data Desk(`review-sveltekit`)의 원재료 검수 화면을 크롤링 JSON 파일 대신 **로컬 collected_products 테이블을 직접 읽고 쓰도록** 바꾼다. 검수(확인완료)가 곧바로 collected_products에 반영되고, 거기서 자동 파이프라인(tokenize → judge → promote)이 product_masters로 승격한다.

- 작성일: 2026-06-16
- 관련 스펙: `2026-06-11-local-db-data-ingestion-plan.md` (수집/서비스 파이프라인), `2026-06-11-products-table-split-plan.md` (테이블 분리)
- 상태: 계획 (착수 전)
- 대상 레포: `/Users/innovator/Project/CoupangCrawler/review-sveltekit` (Data Desk), `/Users/innovator/Project/HappyCart` (DB·파이프라인)

---

## 0. 한 줄 요약

Data Desk와 로컬 Docker postgres가 **같은 기계(mac-mini)에 있으므로**, 검수 화면을 localhost:54322의 collected_products에 직접 postgres 접속시킨다. 검수 결과는 파일 Export/Import 대신 collected_products를 UPDATE하고, 그 뒤는 기존 파이프라인이 받는다. collected_products는 **로컬 전용 유지** — 운영 Supabase로 옮기지 않는다.

---

## 1. 왜 B이고, 왜 지금 가능한가

이전 계획(`2026-06-11`)은 collected_products를 **로컬 전용**으로 두고 검토는 SQL로 한다고 했다(그 문서 §9 제외 항목). 검수를 Data Desk UI로 하려면 collected_products를 Data Desk가 닿는 곳에 둬야 하는데, Data Desk가 Supabase로만 접속한다고 가정하면 "수집 테이블을 운영 Supabase에 올려야" 해서 로컬 전용 원칙과 충돌했다.

**해소**: 현재 작업 기계의 hostname이 `Innovators-Mac-mini.local`이고, 인계 문서상 Data Desk도 mac-mini에서 돈다. 즉 **Data Desk = 로컬 Docker postgres와 동일 호스트**. Data Desk가 `localhost:54322`에 직접 붙으면 collected_products를 로컬에 둔 채로 읽고 쓸 수 있다 — 충돌 없이 B 달성.

> 이 문서는 이전 계획 §9의 "수집 테이블 기반 Data Desk 검토 UI는 범위 밖" 항목을 **범위 안으로 전환**한다.

---

## 2. 현재 구조 (조사 결과)

`review-sveltekit`은 한 앱에 화면 둘:

| 화면 (라우트) | 정체 | 데이터 소스 | 쓰기 |
|---------------|------|------------|------|
| `/` (메인) | 원재료 검수 | **크롤링 JSON 파일** (`products*.json`, `manual_ingredients_direct_*.json`) + detail 이미지 파일 | **없음** — 편집은 클라이언트 `progress` 객체에 모았다가 Export/Import 파일로만 |
| `/pending` | 미등록 상품 | **운영 Supabase** (`supabaseAdmin`, service_role) | pending_products PATCH (status) |

핵심 코드:
- `src/lib/server/categoryData.ts` — `loadReviewData(category)`가 JSON을 읽어 `ReviewItem[]` + `ReviewSummary` 생성. 읽기 전용. 카테고리별 탭. (page, rank, productId) 단위
- `src/routes/+page.server.ts`, `api/review-items` — 위를 그대로 노출
- `src/routes/api/summary` — 헤더 통계 (포함 988 · 확실 100 · 확인필요 67 · Unreadable 821 …)
- `src/routes/api/source-image/[...path]` — detail 이미지를 파일 트리에서 서빙 (경로 탈출 방지 포함)
- `src/routes/+page.svelte` — 편집 UI. `saveBarcodeEdit()`이 클라이언트 `progress`에 기록, `exportProgress`/Import로 파일 왕복
- `src/lib/server/supabaseAdmin.ts` — Supabase service_role 클라이언트 (pending 전용)

타입(`src/lib/types.ts`)의 검수 관련 값:
- `Confidence = 'high' | 'medium' | 'low' | 'unreadable'` (원재료 판독 신뢰도)
- `ReviewStatus = 'confirmed' | 'needs_review' | 'unreadable'` — confidence에서 파생 (high→confirmed, medium/low→needs_review, unreadable→unreadable)
- `ReviewerDecision = '' | 'verified' | 'needs_fix' | 'skip'` — **검수자의 판정**. 현재 Export 파일에만 저장됨 (DB에 없음)
- `ReviewProgressRecord` — decision, note, editedIngredients, barcode, barcodeImageDataUrl 등 편집분

**시사점 3가지**:
1. 읽기 소스를 JSON → collected_products로 바꾸면 됨
2. 쓰기는 **새로 만들어야 함** — 지금은 서버 영속화 자체가 없음 (파일 Export뿐). Data Desk 편집 = collected_products UPDATE로 대체
3. `ReviewerDecision`(확인완료)을 담을 컬럼이 collected_products에 없음 → 스키마 추가 필요

---

## 3. 목표 구조

```
[Data Desk 원재료 검수 화면]            [HappyCart 파이프라인]
localhost:54322/happycart            (변경 없음)
  └ collected_products 읽기/쓰기
     · 원재료·바코드 입력
     · 확인완료(review_decision='verified')  ──→ tokenize → judge → promote
                                                        ↓
                                              product_masters / product_barcodes
                                                  (verified_status='unverified')
                                                        ↓
                                              [Data Desk /pending 또는 별도 검증]
                                              verified_status='verified' → 앱 노출
```

- detail 이미지는 **파일 그대로** — collected_products.raw에 경로가 있고 source-image API가 디스크에서 서빙 (변경 최소)
- collected_products는 로컬 전용 유지. 운영 Supabase에는 안 올라감 (Phase 3 업로드 때 승격분 masters/barcodes만)

---

## 4. 데이터 매핑 (ReviewItem ↔ collected_products)

검수 화면은 `source='coupang'` 행을 다룬다 (kakamuka는 원재료가 없어 검수 대상 아님).

| ReviewItem 필드 | collected_products 컬럼 | 비고 |
|-----------------|------------------------|------|
| productId | source_ref (source='coupang') | 자연키 |
| title / listTitle | name·brand·size (정제) / raw.product.title | |
| barcode | barcode | 검수에서 입력·수정. EAN 체크섬 검증 통과만 (실패 시 거부) |
| ingredients | ingredients_raw | 검수에서 판독·수정 |
| confidence | confidence | **high/medium/low만** — DDL이 'unreadable'을 허용하지 않음 (아래 참조) |
| status (파생) | ingredients_raw 유무 + confidence | 저장 안 함, 화면에서 파생 |
| **decision (확인완료)** | **review_decision (신규 컬럼)** | verified/needs_fix/skip/NULL (''는 API가 NULL로 정규화) |
| notes | review_note (신규 컬럼) | |
| sourceImages | **raw.ingredients_manual.sourceImages** (예: `detail/<pid>/03_bottom.jpg`) | 파일 경로, source-image API |
| thumbnail | **raw.product.image** (쿠팡 CDN URL) 또는 로컬 images_page | |
| detail 이미지 | 파일시스템 `detail/<source_ref>/` (raw에 저장 안 됨 — 디스크 직접) | |
| page, rank | raw.product.rank / raw.pages | 정렬·표시용 |

### confidence ↔ status 매핑 (HIGH-2 정정)

UI의 `unreadable`은 **confidence enum 값이 아니라 "원재료를 못 읽음" 상태**다. DDL의 confidence(low/medium/high/NULL)에 'unreadable'을 넣지 않고, **`ingredients_raw IS NULL`을 unreadable의 진짜 신호로 쓴다** (enum에 무데이터 sentinel을 섞지 않음 — extract/promote/test가 단순해짐):

| DB 상태 | UI status |
|---------|-----------|
| `ingredients_raw IS NULL` | **unreadable** (confidence도 NULL) |
| ingredients 있음 + confidence='high' | confirmed (확실) |
| ingredients 있음 + confidence in (medium, low) | needs_review (확인필요) |
| ingredients 있음 + confidence IS NULL (extracted 소스) | needs_review |

- **쓰기**: 검수자가 unreadable 표시 → `ingredients_raw=NULL, confidence=NULL`. confidence 저장은 high/medium/low만 허용
- **읽기**: 위 표대로 status 파생. confidence NULL이라도 ingredients가 있으면 unreadable이 아님 (extracted 소스 구분)

**신규 컬럼** (collected_products, 로컬 전용이라 pipeline/sql만 수정 — 운영 미반영):
- `review_decision text check (review_decision in ('verified','needs_fix','skip'))` — NULL 허용(미검수). API가 ''→NULL 정규화
- `review_note text`
- `reviewed_at timestamptz`

기존 행 backfill: ALTER 후 전 행 NULL(미검수) 시작. 마이그레이션은 `pipeline/sql`에 idempotent ALTER로.

카테고리 탭 = `select distinct category from collected_products where source='coupang' order by category`.

---

## 5. 편집 ↔ 파이프라인 정합 (중요)

검수가 collected_products를 고치면, 하류 산출(tokens·verdict·승격)이 그 변경을 반영해야 한다. stage 규칙으로 처리:

전이 로직은 앱이 아니라 **`review_collected_product()` SECURITY DEFINER 함수 안에서** 실행된다 (§보안) — 아래는 그 함수가 한 트랜잭션에서 보장하는 불변식이다:

- **원재료/바코드 수정 시** (함수가 한 트랜잭션에서):
  1. `stage='promoted'`면 **409 거부** (이미 서비스로 넘어간 데이터 — 수정은 product_masters 절차로). 검수 대상은 promoted 이전 stage만
  2. 그 외에는 `stage='parsed'`로 되돌리고 **파생 컬럼을 전부 NULL/비움**: `ingredients_tokens, verdict, bad_ingredients_detected, good_ingredients_detected, verdict_reason_codes, rule_version, computed_at`. (되돌리지 않으면 parsed 행에 옛 verdict가 남아 stale)
  3. `reviewed_at=now()` 기록
- **확인완료(review_decision='verified')**: 승격 게이트로 사용 (§8-1 확정). **promote.py 조건에 `review_decision='verified'` 추가**
- **needs_fix/skip**: 승격 제외. skip은 `stage='rejected'`로 옮기는 것도 검토

**extract 재실행 충돌 방지** (MEDIUM-3 정정): upsert 계약은 `extract_coupang.py`가 아니라 **공유 코드 `pipeline/common.py`의 `UPSERT_SQL`**에 있고 두 extractor가 같이 쓴다. 가드는 **공유 upsert 경로에** 넣는다:
- `UPSERT_SQL`의 갱신 조건 `where collected_products.stage in ('raw','parsed')`에 `and collected_products.reviewed_at is null`을 추가. 사람이 손댄 행(`reviewed_at is not null`)은 어느 extractor가 돌든 재적재에서 보존된다.

---

## 6. 변경 작업 목록

### Data Desk (`review-sveltekit`)
1. **pg 클라이언트 + 최소권한 롤** — `postgres`(또는 `pg`) 의존성. `src/lib/server/collectedDb.ts` 신설. **superuser가 아니라 `datadesk_review` 롤로 접속** — SELECT(읽기) + review RPC EXECUTE(쓰기)만 (§보안). `$env/dynamic/private`의 `HAPPYCART_DSN` 사용 (지연 초기화, 미설정 시 graceful)
2. **읽기 교체** — `categoryData.ts`의 `loadReviewData`를 collected_products 쿼리 버전으로. JSON 파일 의존 제거. `ReviewItem`/`ReviewSummary` 형태는 유지(프런트 호환). 하드코딩 `validateSummary`(988/100/67…)는 DB 기반 카운트로 교체
3. **쓰기 신설** — `src/routes/api/review-items/+server.ts`에 `PATCH` 추가: 직접 UPDATE가 아니라 **`review_collected_product(...)` RPC 호출** (§5 트랜잭션은 함수가 DB에서 강제). 함수가 던지는 promoted 예외 → 409 매핑. **fail-closed**: HAPPYCART_DSN 설정 + 인증 게이트 꺼짐이면 쓰기 거부. `pending-products/+server.ts` PATCH 패턴 재사용
4. **프런트** — `+page.svelte`의 Export/Import 기반 `progress` 저장을 PATCH 호출로 교체. (Export/Import는 백업용으로 남길지 §8)
5. **source-image** — 변경 최소. 출처 경로를 raw.ingredients_manual.sourceImages / 파일시스템 detail 디렉토리에서 얻고, **기존 `resolveSafeSourceImage`의 경로 탈출 방지를 그대로 유지**
6. **`.env`** — `HAPPYCART_DSN` 추가 (전용 롤 자격증명, 로컬 DB 접속)

### HappyCart (`pipeline/`, `supabase`)
7. **collected_products DDL + review RPC** — `pipeline/sql/collected_products.sql`(또는 별도 `pipeline/sql/review_rpc.sql`)에 review_decision·review_note·reviewed_at 컬럼(idempotent ALTER) + `review_collected_product(...)` SECURITY DEFINER 함수 + `datadesk_review` 롤 생성·권한(SELECT + 함수 EXECUTE)
8. **공유 upsert 가드** — `pipeline/common.py`의 `UPSERT_SQL`에 `and reviewed_at is null` (양쪽 extractor 보존). extract_coupang/kakamuka 코드는 변경 없음
9. **promote.py** — 승격 조건에 `review_decision='verified'` 추가 (§8 결정 1) + held-count 리포트에 "미검수" 사유 분리

### 보안 (HIGH-1 + watch: 전이를 DB가 강제)

기존 운영 스키마와 동일한 패턴을 따른다 — 앱은 테이블을 직접 쓰지 않고 **`SECURITY DEFINER` 함수로만** 쓴다 (lookup_product/log_pending_product 선례).

- **review 전이를 RPC로 캡슐화**: `review_collected_product(p_id, p_barcode, p_ingredients_raw, p_confidence, p_decision, p_note)` 같은 SECURITY DEFINER 함수를 만든다. 이 함수가 §5 트랜잭션 전부를 **DB 안에서** 강제한다 — promoted면 예외(409 매핑), stage='parsed' 복원, 파생 컬럼 비움, decision 화이트리스트·''→NULL, confidence 화이트리스트, barcode 형식, reviewed_at 기록. 앱 코드가 규칙을 어겨도 DB가 막는다
- **전용 DB 롤**: `datadesk_review` 롤에 `collected_products` **SELECT** + 위 함수 **EXECUTE**만 부여. **직접 UPDATE/INSERT/DELETE·DDL 권한 없음**. 다른 테이블 접근 없음. Data Desk는 이 롤로 접속 (superuser 금지). 함수 소유자는 권한 있는 별도 롤
- **쓰기 fail-closed**: 인증 게이트(AUTH_*)가 현재 fail-open(자격증명 미설정 시 인증 없이 동작)이다. HAPPYCART_DSN이 설정된 환경에서는 PATCH 등 쓰기 라우트를 **인증 필수**로 — 미인증이면 403
- **loopback 바인딩**: Docker postgres 포트(54322)와 Data Desk dev server는 `127.0.0.1`에만 바인딩. 외부 노출 금지를 문서화

> EAN 체크섬은 함수 내 검증 또는 앱 선검증 중 택1 — 형식(8/13자리)은 함수가, 체크섬은 앱(common.py `ean_valid`)이 선검증하고 함수는 형식까지만 강제하는 절충도 가능. 구조 불변식(stage·파생·promoted-lock)은 반드시 함수 안.

---

## 7. 이미지 / 카테고리 처리

이미지 출처별 정확한 경로 (MEDIUM-5 정정 — extract_coupang의 raw 구조 기준):

- **썸네일**: `raw.product.image` (쿠팡 CDN URL). 로컬 정리본이 있으면 `images_page<page>/<rank>_<pid>.*`
- **원재료 판독 출처 이미지**: `raw.ingredients_manual.sourceImages` (예: `["detail/9355738365/03_bottom.jpg"]`)
- **detail 이미지 묶음**: raw에 저장돼 있지 않다 — 파일시스템 `<카테고리>/detail/<source_ref>/`를 디스크에서 직접 읽는다 (구 `detailStats`와 동일)
- source-image API는 위 상대경로를 받아 서빙하되 **`resolveSafeSourceImage`의 경로 탈출 방지(절대경로·`..` 차단, 카테고리 루트 이탈 차단)를 그대로 유지**
- kakamuka raw는 `raw.images`에 경로가 있지만, kakamuka는 원재료 검수 대상이 아니므로(원재료 없음) 화면에서 제외 (source='coupang' 필터)

카테고리 탭은 `select distinct category from collected_products where source='coupang' order by category`.

---

## 8. 결정 포인트

1. **승격 게이트를 확인완료로 강화** — ✅ **확정 (2026-06-16, 사용자 결정)**. promote.py에 `review_decision='verified'` 요구. "확인완료된 것만 product_masters로"라는 모델과 일치.
   - **결과 — pre-gate 자동 승격분 롤백 필요**: 현재 로컬 product_masters/barcodes에는 검수 없이 자동 승격된 113건이 있다. 게이트 강화 후 일관성을 위해 이들을 **judged로 되돌린다**(masters/barcodes에서 제거, collected_products.stage='judged', promoted_master_id/promoted_at NULL). 시드 8건은 운영 베이스라인이므로 건드리지 않는다. 로컬 전용이고 운영 미반영 상태라 롤백은 안전.
2. **Export/Import 유지?** — 권장: 백업용으로 남김 (DB 직결이 주 경로, 파일은 오프라인 이관/백업).
3. **promoted 행 검수 잠금** — 권장: 잠금(409). 서비스로 넘어간 데이터는 product_masters 절차로.
4. **DB 미접속 graceful** — 권장: pending 탭처럼 "DB 미설정/미연결" 표시, 읽기 화면은 빈 상태로 graceful.

---

## 9. 작업 순서 체크리스트

1. collected_products review 컬럼 3종 + 전용 롤(권한) DDL (idempotent ALTER) → bootstrap 재적용 or ALTER
2. Data Desk `collectedDb.ts`(전용 롤) + `.env` HAPPYCART_DSN → 검증: 연결 확인
3. `loadReviewData` DB 버전 → 검증: 과자 카테고리 행 수·status 분포가 DB와 일치, 화면 정상 렌더
4. review PATCH API + 프런트 배선 → 검증: 바코드·원재료·확인완료 저장이 collected_products에 반영
5. 공유 upsert(common.py) no-clobber 가드 → 검증: 검수 후 extract 재실행이 사람 편집을 덮지 않음
6. **pre-gate 자동 승격분(113) 롤백** → judged 복원 (시드 8건 제외) → 검증: masters/barcodes에 시드 8건만 남음
7. promote.py 확인완료 게이트(§8-1 확정) → 검증: review_decision='verified' 행만 승격
8. 회귀: `/pending` 탭(운영 Supabase) 영향 없음 확인

### 수용 기준 테스트 (LOW-1)

- **바코드**: EAN 체크섬 불합격 입력은 PATCH 거부(4xx), 합격만 저장. 선행 0 보존(text)
- **인가**: 인증 게이트 켜진 상태에서 미인증 PATCH는 403. DSN 설정 + 인증 꺼짐이면 쓰기 거부(fail-closed)
- **decision 정규화**: ''→NULL, verified/needs_fix/skip 허용, 그 외 거부
- **unreadable 매핑**: ingredients_raw NULL 행이 화면에서 unreadable로, extracted(confidence NULL+ingredients 있음)는 needs_review로 구분
- **파생 비움**: 원재료 수정 시 ingredients_tokens·verdict·rule_version 등이 한 트랜잭션에서 비워지고 stage='parsed'
- **promoted 잠금**: promoted 행 PATCH는 409
- **no-clobber**: reviewed_at 있는 행은 extract 재실행 후에도 사람 편집값 유지; reviewed_at NULL 행은 정상 갱신
- **마이그레이션/backfill**: ALTER 재실행 idempotent, 기존 행 review_decision NULL 시작
- **권한**: `datadesk_review` 롤로 collected_products **직접 UPDATE/INSERT/DELETE 시도가 거부됨**(EXECUTE만 허용), 다른 테이블 접근·DDL 거부. 모든 review 쓰기는 RPC 경유만 성공

---

## 10. 범위 제외 (추후)

- collected_products를 운영 Supabase로 이전 (현재 로컬 전용 유지 결정)
- kakamuka 행의 검수 UI (원재료 없음)
- 다중 검수자·권한 분리
- product_masters의 verified 검증 UI (별도 — 앞 계획 §6.5)
