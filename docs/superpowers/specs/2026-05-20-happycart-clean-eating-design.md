# HappyCart — 바코드 클린이팅 스캐너 (MVP) 설계

**작성일:** 2026-05-20
**프로젝트 코드명:** HappyCart / 해피카트
**전신:** EatSafe (`/Users/ronen/Project/EatSafe`) — 일반 식품 영양 판정 / 초등 부모 신호등 컨셉. 본 프로젝트는 EatSafe 코드 자산을 포크해 **clean-eating ingredient 룰**로 재편한다.
**아이콘:** `/Users/ronen/Project/HappyCart/happy-cart.png`

> **고지** — 본 앱은 식품 라벨에 기반한 **참고 정보**를 제공한다. 의학적 안전 판단 도구가 아니며, 본 앱이 사용하는 clean-eating 철학(초가공·인공첨가물 회피, 성분 단순성 선호)에는 과학적으로 강하게 입증된 항목(예: 트랜스지방)과 아직 논쟁 중인 항목(예: seed oils, carrageenan)이 함께 포함되어 있다. 알레르기·질환·임신·영유아 식이는 반드시 제품 표시와 전문가 판단을 우선해야 한다.

---

## 0. 한 줄 요약

바코드 한 번으로 "이 제품을 마음 편히 카트에 담아도 되는지"를 **Okay / Not Okay** 두 단계로 보여주는 Flutter 앱. 판정은 영양 임계값이 아니라 **원재료 성분 키워드 매칭**에 기반한다. 인공감미료·합성 보존제·정제 씨앗유·고과당 옥수수시럽 등 "Bad Ingredient"가 하나라도 포함되면 Not Okay, 없으면 Okay. 등록되지 않은 제품은 "해피카트에서 이 물건을 찾을 수 없습니다" 안내. Supabase Postgres에 사전 평가된 데이터를 두고 클라이언트는 `lookup_product` RPC로 공개 컬럼만 받는다.

---

## 1. 핵심 결정 사항

| 항목 | 결정 |
|------|------|
| 플랫폼 | Flutter (iOS + Android 동시 빌드) |
| 화면 수 | 2개 — 스캔 화면, 결과 화면 |
| 판정 단계 | **2단계** (`okay` / `not_okay`) + `not_found` + `insufficient` |
| 판정 기준 | **성분(ingredient) 키워드 매칭**. Bad Ingredient 1개 이상 포함 → `not_okay`. 0개 → `okay`. 성분 정보 자체가 없으면 `insufficient` |
| 타깃 | 일반 성인 소비자 (특정 라이프스테이지 한정 없음) |
| 결과 정보량 | 제품명, 브랜드, 용량, verdict, 매칭된 bad ingredient 목록, 데이터 업데이트일, 룰 버전, 면책 문구 |
| 식품 DB | 자체 구축 (Supabase Postgres, 초기 시드 + 점진 추가). 출처·검증·라벨 버전 보존 |
| 평가 로직 | 룰 기반. **단일 소스는 `happycart_rules` 패키지** (Pure Dart). DB에 `verdict`, `bad_ingredients_detected`, `rule_version`, `computed_at` 저장. 클라이언트는 룰을 갖지 않음 |
| 데이터 노출 | 클라이언트는 `lookup_product(barcode)` RPC만 호출 (SECURITY DEFINER + hardening). 원본 `products` 테이블은 service_role만 접근 |
| 인증 | 익명 (Supabase publishable / anon key). 모바일 키는 비밀이 아니라 빌드 환경 분리 용도임을 명시 |
| 환경 분리 | Supabase 프로젝트 3개 — `dev`, `staging`, `prod` (EatSafe와 별개의 신규 프로젝트군). Flutter는 빌드 flavor로 전환 |
| 카메라/스캔 | `mobile_scanner` 패키지. EAN-13/EAN-8 형식만 허용. 국가 prefix 제한 없음 |
| 상태 관리 | Riverpod |
| 분석 추적 | 개인정보 없는 익명 집계 이벤트만 (`scan_success`, `not_found`, `insufficient`, `network_error`, `barcode_format`, `verdict`, `scan_latency_ms`). 바코드 식별자는 어떤 형태로도 저장하지 않음. RPC `log_scan_event` 경유 |
| 제품 이미지 | MVP는 placeholder 고정. Storage·이미지 수집은 후속 |
| 디자인 시스템 | HappyCart 아이콘의 **오렌지 톤** 메인 + 2-tier verdict 컬러 (green/red 계열) |
| 한글 폰트 | Pretendard |
| 첫 화면 | 스캔 화면 (홈/검색/저장/프로필 없음) |
| 스캔 이력 저장 | 사용자별 이력 없음. 익명 집계만 |
| 패키지/Bundle ID | `com.rimonhouse.happycart` |

---

## 2. 명시적 비-범위 (Out of Scope)

- 홈 / 검색 / 저장 / 프로필 4개 탭
- 다중 프로필 모드 (어린이 / 임산부 / 다이어터 / 알레르기) — EatSafe pivot 컨셉은 가져오지 않는다
- "대신 이건 어때요" — 대안 제품 추천
- 영양성분 막대 차트, 원료 분석 상세 리스트 (성분명 chip 리스트까지만)
- 사용자 계정 / 소셜 로그인 / 데이터 동기화
- 사용자별 스캔 이력 / 즐겨찾기 / 저장함
- 푸시 알림, 큐레이션 콘텐츠
- 영양성분표 OCR, 직접 입력
- 사용자 제품 제보 기능
- 제품 이미지 수집·Storage 운영
- 다국어 (한국어만, 단 성분 키워드는 한·영 동시 매칭)
- 영양 수치(나트륨/당류/포화지방/카페인) 기반 판정 — 본 MVP는 ingredient-only

---

## 3. 아키텍처

### 3.1 레이어 구조

- **UI 레이어**: `ScanScreen`, `ResultPage` 두 위젯. 디자인 토큰은 `app_theme.dart`.
- **상태 레이어 (Riverpod)**: `ScanController`(스캐너 lifecycle), `ProductRepository`(Supabase 조회), `AnalyticsClient`(익명 이벤트 전송).
- **데이터 레이어**: `mobile_scanner`로 카메라 프레임 디코딩, `supabase_flutter`로 `lookup_product` RPC 단건 호출.
- **룰 레이어 (`packages/happycart_rules`)**: Pure Dart. `IngredientInput` → `VerdictResult`. 클라이언트는 의존하지 않고, seed 스크립트와 admin 도구만 사용.

서버는 Supabase 하나로 통합. 별도 API 서버 없음. 클라이언트는 anon JWT로 `lookup_product` RPC를 호출해 제품 정보를 얻고, `log_scan_event` RPC로 익명 분석 이벤트를 기록한다. 테이블 직접 SELECT/INSERT는 불가.

### 3.2 환경 분리

- Supabase 프로젝트는 `dev`, `staging`, `prod` 3개로 분리한다 (EatSafe와 완전 분리).
- Flutter는 빌드 flavor (`development`, `staging`, `production`)로 `.env.{flavor}` 파일을 선택해 URL/anon key를 주입한다.
- 모바일 anon key는 디컴파일 시 노출되므로 "비밀 보호"가 아닌 "환경 라우팅 식별자"로만 사용한다. 보안 경계는 RLS와 SECURITY DEFINER RPC 정의에 둔다.

### 3.3 사용자 흐름 (Happy Path)

1. 앱 진입 → 곧장 스캔 화면 (스플래시 외 별도 홈 없음).
2. 최초 진입 시 카메라 권한 요청. 허용 시 프리뷰 활성.
3. 바코드 인식 → 미디엄 햅틱 1회 → 스캐너 일시정지.
4. `lookup_product(p_barcode := '...')` RPC를 호출해 단건 조회.
5. 응답 도착 시 결과 화면 푸시. 동시에 익명 분석 이벤트 발사.
6. 결과 화면 닫으면 스캔 화면 복귀 + 스캐너 재개.

### 3.4 결과 분기

- **조회 성공 + bad ingredient 0개** → `okay` 결과 화면 (그린 톤, "괜찮아요" + 단순 원재료 칩).
- **조회 성공 + bad ingredient 1+** → `not_okay` 결과 화면 (레드 톤, "잠깐, 확인해보세요" + 매칭된 bad ingredient 칩 목록 + 사유).
- **DB 미등록** → `not_found` 화면. "해피카트에서 이 물건을 찾을 수 없습니다" + 바코드 번호 + 다시 스캔 버튼.
- **성분 정보 부족** → `insufficient` 화면. "이 제품의 원재료 정보를 확인하지 못했어요" 안내.
- **네트워크 오류 / 타임아웃** → "연결을 확인해주세요" + 재시도 버튼.

---

## 4. 데이터 모델

### 4.1 `products` 테이블 (원본, service_role 전용)

| 컬럼 | 타입 | 비고 |
|------|------|------|
| `id` | uuid (PK) | 내부 식별자 |
| `barcode` | text (UNIQUE, INDEX) | EAN-13/EAN-8. 시중 실제 GTIN만 입력. 임시 ID 금지 |
| `brand` | text | 브랜드명 |
| `name` | text | 제품명 |
| `size` | text | 용량 / 중량 표시 그대로 (예: "500ml") |
| `category` | text (nullable) | 카테고리 (예: "올리브오일", "탄산음료") — 표시·필터 용 |
| `ingredients_raw` | text | 원재료명 전문 (라벨 그대로) |
| `ingredients_tokens` | text[] | 정규화된 원재료 토큰 리스트 (소문자, 트림, 한·영 정규화). 키워드 매칭의 입력. nullable 아님 — 비어있으면 `insufficient` |
| `bad_ingredients_detected` | text[] | 룰 패키지가 매칭한 bad 키워드(canonical 이름, 예: `aspartame`, `hfcs`, `bha`) |
| `good_ingredients_detected` | text[] | (옵션) 매칭된 good 키워드. UI 부가 표시 용도 |
| `verdict` | enum (`okay` / `not_okay` / `insufficient`) | 사전 계산 결과. `not_found`는 행 부재로 표현되므로 enum에 없음 |
| `verdict_reason_codes` | text[] | 사람이 읽는 사유 코드 (예: `artificial_sweetener`, `seed_oil`, `synthetic_preservative`) |
| `rule_version` | text (예: `v1.0.0`) | 평가에 사용된 룰 버전 |
| `computed_at` | timestamptz | verdict 계산 시각 |
| `source` | text | `manual` / `식약처` / `제조사 공식` / `매장 라벨` 등 |
| `source_url` | text (nullable) | 출처 링크 |
| `source_checked_at` | timestamptz | 출처 확인 시각 |
| `label_version` | text (nullable) | 제조사 라벨 개정 식별자 |
| `verified_status` | enum (`unverified` / `verified` / `needs_review`) | 사람 검수 상태 |
| `image_url` | text (nullable) | MVP에선 항상 NULL |
| `created_at` | timestamptz | |
| `updated_at` | timestamptz | 트리거 자동 갱신 |

영양 수치 컬럼(`nutri_per_serving` 등)은 본 MVP에서 사용하지 않으므로 컬럼 자체를 두지 않는다. 후속 단계에서 ingredient + nutrition 결합 판정이 필요해지면 컬럼을 추가한다.

### 4.2 클라이언트 조회 경로 — `lookup_product` RPC

원본 `products` 테이블은 anon에게 어떤 권한도 부여하지 않는다. 클라이언트는 오로지 **`lookup_product(p_barcode text)` RPC**를 호출해 공개 컬럼만 받는다.

**함수 시그니처**: `lookup_product(p_barcode text) RETURNS TABLE (barcode text, brand text, name text, size text, category text, verdict text, bad_ingredients_detected text[], good_ingredients_detected text[], verdict_reason_codes text[], rule_version text, computed_at timestamptz, source_checked_at timestamptz)`

**반환 규칙**:
- `verified_status = 'verified'` 인 행만 반환.
- 노출 컬럼: 위 시그니처 명시 컬럼만. 원본 `ingredients_raw`(긴 텍스트), `ingredients_tokens`(내부 정규화 결과), 검증 상태, 출처 URL 등은 반환하지 않는다.

**보안 hardening** (RPC 정의 시 필수):
- `SECURITY DEFINER` 로 정의해 함수 owner(postgres) 권한으로 `products`를 조회.
- `SET search_path = ''` 명시.
- 본문 내 모든 객체 참조는 schema-qualified — `public.products`, `public.scan_events` 등.
- 함수 owner는 `postgres` 등 RLS bypass 가능한 관리 role 고정. anon / authenticated 가 owner가 되지 않게.
- `REVOKE ALL ON FUNCTION public.lookup_product(text) FROM PUBLIC;` 후 `GRANT EXECUTE ON FUNCTION public.lookup_product(text) TO anon, authenticated;`

### 4.3 RLS / 권한 정리

- `products` (원본): RLS 활성화. anon/authenticated용 정책 없음. service_role만 SELECT/INSERT/UPDATE/DELETE.
- `scan_events`: RLS 활성화. anon/authenticated 직접 INSERT 권한 없음. `log_scan_event` RPC만 INSERT.
- `lookup_product`, `log_scan_event` RPC: anon에게 EXECUTE GRANT, 그 외 PUBLIC에서 REVOKE.
- service_role 키는 시드/관리 스크립트에서만 사용. 앱 번들/소스 코드에 절대 포함 금지.

회귀 SQL 테스트로 다음을 검증한다:

1. anon이 `lookup_product('...')` 호출 시 verified 행만 정상 반환.
2. anon이 `public.products`를 직접 SELECT 시 실패.
3. anon이 `public.scan_events`를 직접 INSERT/SELECT 시 실패.
4. `lookup_product` 가 `verified_status != 'verified'` 행을 절대 반환하지 않음.
5. `log_scan_event` 가 잘못된 enum/길이 입력을 거부.

### 4.4 분석 이벤트 테이블 `scan_events`

| 컬럼 | 타입 | 비고 |
|------|------|------|
| `id` | bigserial | |
| `event_type` | enum (`scan_success` / `not_found` / `insufficient` / `network_error`) | CHECK 제약 |
| `barcode_format` | text | CHECK in (`EAN-13`, `EAN-8`) |
| `verdict` | text (nullable) | CHECK in (`okay`, `not_okay`, `insufficient`, NULL) |
| `scan_latency_ms` | integer | CHECK 0 ≤ x ≤ 60000 |
| `app_version` | text | 길이 ≤ 32, semver 정규식 |
| `platform` | text | CHECK in (`ios`, `android`) |
| `created_at` | timestamptz | 기본 now(). INDEX |

**MVP에서 바코드 식별자는 어떤 형태로도 `scan_events`에 저장하지 않는다.** 원문도, 해시도. EatSafe와 동일 정책.

- 클라이언트는 `log_scan_event(p_event_type text, p_barcode_format text, p_verdict text, p_scan_latency_ms int, p_app_version text, p_platform text)` RPC만 호출.
- `log_scan_event` RPC도 `lookup_product`와 동일한 hardening 패턴: `SECURITY DEFINER`, `SET search_path = ''`, schema-qualified, owner=postgres, `REVOKE ALL ... FROM PUBLIC; GRANT EXECUTE ... TO anon;`.
- 90일 retention, Supabase cron으로 일괄 삭제. 일 단위 집계는 `scan_events_daily` 테이블 롤업.

### 4.5 Storage

- MVP에서는 사용하지 않는다. 결과 화면 이미지는 verdict 컬러 + 아이콘 placeholder.

---

## 5. 평가 룰 (`happycart_rules` 패키지)

### 5.1 단일 소스 원칙

- 룰은 **`packages/happycart_rules`** 한 곳에만 존재한다 (Pure Dart, no Flutter deps).
- 클라이언트(Flutter 앱)는 룰을 모른다. `verdict`, `bad_ingredients_detected`, `verdict_reason_codes`, `rule_version`만 RPC 응답에서 받아 표시한다.
- 룰 변경 시 `rule_version`을 올리고, 시드 스크립트로 전체 행을 재계산(`computed_at` 갱신).

### 5.2 입력 / 출력

**입력 (`IngredientInput`)**:
- `tokens: List<String>` — 정규화된 원재료 토큰. 빈 리스트는 `insufficient`.

**출력 (`VerdictResult`)**:
- `verdict: Verdict` — `okay` / `notOkay` / `insufficient`
- `badMatches: List<BadMatch>` — 매칭된 bad 키워드 (canonical name + reason code)
- `goodMatches: List<GoodMatch>` — 매칭된 good 키워드 (UI 보조 표시)

### 5.3 Bad Ingredient 룰 (v1.0.0)

성분 카테고리별 canonical 키워드와 매칭 대상(한·영). **하나라도 매칭되면 `not_okay`**.

| 카테고리 (reason code) | Canonical key | 매칭 대상 (한·영 정규식 + alias) |
|---|---|---|
| `artificial_sweetener` | aspartame | 아스파탐, aspartame, E951 |
|  | sucralose | 수크랄로스, sucralose, E955 |
|  | acesulfame_k | 아세설팜칼륨, acesulfame, ace-k, E950 |
|  | saccharin | 사카린, saccharin, E954 |
| `artificial_color` | red_40 | 적색40호, red 40, allura red, E129 |
|  | yellow_5 | 황색5호, yellow 5, tartrazine, E102 |
|  | yellow_6 | 황색6호, yellow 6, sunset yellow, E110 |
|  | blue_1 | 청색1호, blue 1, brilliant blue, E133 |
|  | red_3 | 적색3호, red 3, erythrosine, E127 |
| `hfcs` | hfcs | 고과당옥수수시럽, 액상과당, 과당시럽, high fructose corn syrup, HFCS, 콘시럽 |
| `seed_oil` | soybean_oil | 대두유, 콩기름, soybean oil |
|  | canola_oil | 카놀라유, 채종유, canola oil, rapeseed oil |
|  | corn_oil | 옥수수유, corn oil |
|  | sunflower_oil_refined | 정제 해바라기씨유, refined sunflower oil |
|  | cottonseed_oil | 면실유, cottonseed oil |
| `hydrogenated_oil` | hydrogenated | 경화유, 부분경화유, hydrogenated, partially hydrogenated, 트랜스지방 |
| `synthetic_preservative` | bha | BHA, 부틸하이드록시아니솔, E320 |
|  | bht | BHT, 부틸하이드록시톨루엔, E321 |
|  | tbhq | TBHQ, 터셔리부틸하이드로퀴논, E319 |
| `nitrite` | sodium_nitrite | 아질산나트륨, sodium nitrite, E250 |
|  | nitrate | 질산나트륨, sodium nitrate, E251 |
| `carrageenan` | carrageenan | 카라기난, carrageenan, E407 |
| `emulsifier_concern` | polysorbate_80 | 폴리소르베이트80, polysorbate 80, E433 |
|  | datem | DATEM, 다템 |
|  | mono_diglycerides | 모노글리세리드, 디글리세리드, mono- and diglycerides, E471 |
| `opaque_flavor` | natural_flavors | natural flavors, 천연향료 (구체 명시 없음), 합성착향료, 인공향료, artificial flavors |
| `refined_flour` | bleached_flour | 표백 밀가루, bleached flour |
|  | enriched_flour | 강화 밀가루, enriched flour |
| `bromate` | potassium_bromate | 브롬산칼륨, potassium bromate, E924 |
| `maltodextrin` | maltodextrin | 말토덱스트린, maltodextrin, E1400 |

매칭 규칙:
- 토큰 단위 부분 문자열 매칭 (대소문자 무시).
- E-number 매칭은 단어 경계 검사 (E1400이 E14000과 충돌 않도록).
- 한국어는 띄어쓰기/괄호 정규화 후 매칭.
- 매칭된 키워드는 canonical key로 `bad_ingredients_detected`에 누적.

### 5.4 Good Ingredient 룰 (보조)

판정 자체에는 영향 없음. 결과 화면 보조 칩으로만 사용. 매칭된 항목은 `good_ingredients_detected`에 저장.

| Canonical key | 매칭 대상 |
|---|---|
| extra_virgin_olive_oil | 엑스트라버진 올리브유, EVOO, extra virgin olive oil |
| avocado_oil | 아보카도 오일, avocado oil |
| coconut_oil | 코코넛 오일, coconut oil |
| grass_fed_butter | 그래스페드 버터, grass-fed butter, ghee, 기 버터 |
| sea_salt | 천일염, sea salt |
| honey | 꿀, honey |
| maple_syrup | 메이플시럽, maple syrup |
| date | 대추야자, dates, medjool |
| organic | 유기농, organic |
| whole_grain | 통곡물, 통밀, whole grain, whole wheat |
| sprouted_grain | 발아곡물, sprouted grain |
| fermented | 김치, 케피어, 사우어크라우트, kombucha, kefir, kimchi, sauerkraut |
| pasture_raised_egg | 방목 달걀, pasture-raised egg, free-range egg |
| grass_fed_beef | 그래스페드 소고기, grass-fed beef |

### 5.5 최종 verdict 산정

```
if ingredients_tokens 비어있음 → insufficient
else if bad_matches.length >= 1 → not_okay
else → okay
```

`good_matches`는 화면 보조 정보일 뿐 verdict를 바꾸지 않는다.

### 5.6 결과 화면 표시 문구

- `okay` → "마음 편히 담아도 괜찮아요"
- `not_okay` → "잠깐, 이런 성분이 들어 있어요" + bad ingredient 칩
- `insufficient` → "이 제품의 원재료 정보를 확인하지 못했어요"
- `not_found` → "해피카트에서 이 물건을 찾을 수 없습니다"

clean-eating 철학의 한계를 면책 카드에 항상 포함한다 (§12).

### 5.7 시드 데이터

**모든 시드 항목은 실제 시중 제품의 실제 EAN-13 바코드만 사용**. 임시 13자리 ID 금지.

MVP 초기 시드 (각 카테고리 2~3개씩, 총 15~20개):

| 카테고리 | 후보 |
|---|---|
| 올리브오일 | 유기농 EVOO 1~2종 (Okay 케이스) |
| 가공유 | 일반 식용유 (대두유/카놀라유 — Not Okay 케이스) |
| 탄산음료 | 일반 콜라(HFCS·인공색소), 제로 콜라(아스파탐) — Not Okay |
| 천연 감미료 | 국산 꿀 1종, 메이플시럽 1종 — Okay |
| 가공 스낵 | 합성 보존제·인공향료 포함 과자 — Not Okay |
| 통곡물 | 통밀 시리얼 — Okay 후보 |
| 가공육 | 아질산나트륨 햄/소시지 — Not Okay |
| 발효식품 | 김치 — Okay |

각 제품의 원재료·실제 바코드는 제조사 표기 또는 식품안전나라 공식 출처로 확인 후 `source`/`source_url`/`source_checked_at`를 기록.

---

## 6. 화면 명세

### 6.1 ScanScreen

**구조**
- 풀스크린 카메라 프리뷰, 어두운 배경.
- 상단: 좌측 닫기 버튼(앱 종료 확인), 우측 플래시 토글. 반투명 원형 글래스.
- 중앙: 260 × 260 스캔 프레임. 4모서리 **오렌지 코너 마커**(HappyCart 브랜드 컬러), 가로 스캔 라인.
- 하단: "바코드를 비춰주세요" 헤딩 + "제품 뒷면의 바코드" 서브.

**상태**
- `idle` / `scanning` / `permission_denied` / `processing`

**동작**
- 진입 시 권한 없으면 요청. 거부 시 권한 거부 화면.
- EAN-13/EAN-8 외 형식 무시.
- 인식 시 미디엄 햅틱 1회 → 스캐너 일시정지 → 결과 화면 푸시.
- 결과 화면 닫히면 스캐너 재개.
- mobile_scanner lifecycle handler 연결, `detectionTimeoutMs = 250` 디바운스.
- ML Kit `bundled` 모드 기본.

### 6.2 ResultPage

다섯 가지 상태(`okay` / `not_okay` / `not_found` / `insufficient` / `network_error`)를 동일 페이지에서 분기. 모든 상태에 면책 문구와 데이터 업데이트일 표시.

**Okay 레이아웃**
- 상단 컬러 영역: 그린 soft 배경.
- 제품 정보: 좌 텍스트(브랜드 · 용량, 제품명, 바코드 모노스페이스), 우 원형 placeholder (HappyCart 마스코트 미니).
- 메인 verdict 카드:
  - 좌 54 × 54 그린 박스 + ✅ 또는 OK 손 아이콘
  - 우 "괜찮아요" 라벨 + "마음 편히 담아도 괜찮아요" headline
- Good ingredient 칩 (있을 경우): "유기농", "EVOO", "꿀" 등 그린 outline 칩.
- 메타 라인: "데이터 업데이트 {YYYY-MM-DD} · 룰 {rule_version}"
- 면책 카드 (상시).
- 하단: "다시 스캔하기" primary 버튼.

**Not Okay 레이아웃**
- 상단 컬러 영역: 레드/오렌지 soft 배경.
- 메인 verdict 카드:
  - 좌 54 × 54 레드 박스 + ⚠️ 또는 X 손 아이콘
  - 우 "잠깐" 라벨 + "이런 성분이 들어 있어요" headline
- Bad ingredient 칩: reason code별 그룹핑. 예: "인공감미료: 아스파탐", "정제 씨앗유: 카놀라유". 레드 outline.
- (옵션) good ingredient 칩 별도 섹션.
- 메타 라인 + 면책 카드 + 다시 스캔 버튼.

**Not Found 상태**
- 큰 안내 아이콘(돋보기) + "해피카트에서 이 물건을 찾을 수 없습니다" + 바코드 번호 모노스페이스.
- 보조 문구: "아직 등록되지 않은 제품이에요. 점차 늘려갈게요."
- 면책 카드 + "다시 스캔하기" 버튼.

**Insufficient 상태**
- "이 제품의 원재료 정보를 확인하지 못했어요" 헤딩 + 설명("라벨 정보가 일부 누락된 제품이에요").
- 면책 카드 + "다시 스캔하기" 버튼.

**네트워크 오류 상태**
- "연결을 확인해주세요" + 부가 설명.
- "다시 시도" primary, "다시 스캔하기" secondary.
- 면책 카드.

### 6.3 디자인 토큰

HappyCart 아이콘의 오렌지를 메인 브랜드 컬러로 채택. EatSafe의 warm 베이지 팔레트는 떠나 **더 밝고 활기찬 톤**으로 이동.

- 배경: #FFFAF5 / 표면: #FFFFFF / 표면 보조: #FFF1E0
- 텍스트: 잉크 #1F1B16 / 소프트 #5C544A / 뮤트 #9B9388
- 라인: #F0E2CF
- 브랜드 (오렌지): #FF7A1A / 브랜드 강조: #E85F00 / 브랜드 soft: #FFE6CC
- okay: #2E8B57 / okayBg: #E0F2E5
- notOkay: #D04437 / notOkayBg: #FBE3DF
- insufficient (회색): #6B6660 / insufficientBg: #EEE9E0

폰트는 Pretendard. 바코드 표시는 시스템 모노스페이스.

브랜드 아이콘은 `assets/icon/happy-cart.png` (1024x1024 원본). adaptive icon 배경은 #FF7A1A.

---

## 7. 에러 처리 & 엣지 케이스

| 상황 | 처리 |
|------|------|
| 카메라 권한 거부 | 안내 화면 + "설정 열기" (`permission_handler`) |
| 카메라 사용 불가(시뮬레이터 등) | 안내 텍스트. 디버그 빌드에서만 "테스트 바코드 입력" 토글 |
| 바코드 인식 안 됨 | 타임아웃 없이 스캔 지속 |
| 같은 바코드 연속 인식 | 결과 화면 푸시 동안 스캐너 일시정지로 자연 차단 + detectionTimeoutMs 디바운스 |
| Supabase 응답 지연 | 200ms 후 인라인 스피너, 5초 후 타임아웃 → 네트워크 오류 상태 |
| 네트워크 오류 | 오류 상태 + 재시도 버튼 |
| DB 미등록 바코드 | `not_found` 상태 |
| 원재료 정보 부족 | `insufficient` 상태 |
| 잘못된 바코드 형식 | 클라이언트 EAN 체크섬 검증. 실패 시 무시하고 스캔 지속 |
| 앱 백그라운드/포그라운드 전환 | 백그라운드: 카메라 정지 + 스캐너 dispose. 포그라운드: 재초기화 |
| ML Kit 모델 로딩 실패 | bundled 모드이므로 거의 발생 안 함. 발생 시 "카메라 초기화 실패" 안내 + 재시도 |
| 룰 매칭 거짓양성 (false positive) | 키워드별 alias·정규식 회귀 테스트로 사전 차단. 운영 중 발견 시 룰 버전 올리고 재계산 |

---

## 8. 테스트 전략

### 8.1 단위 테스트

- **`happycart_rules` 패키지가 본진**. 카테고리별 bad/good 키워드 매칭, 한·영 alias, E-number 경계, 빈 토큰 → `insufficient`, 단일 bad → `not_okay`, 다중 bad → 모두 누적 등.
- 바코드 EAN-13/EAN-8 체크섬 검증 함수 (Dart 측).
- `ProductRepository` — Supabase 클라이언트 mock으로 정상(`okay`/`not_okay`) / `insufficient` / 빈 결과(`not_found`) / 예외 케이스.
- `AnalyticsClient` — `log_scan_event` RPC payload 검증, 실패 silent 처리.
- DB 회귀 테스트(SQL): §4.3과 동일.

### 8.2 위젯 테스트

- `ResultPage` 5가지 상태 위젯 트리 검증.
- `ScanScreen` 권한 거부 상태.
- 면책 카드가 모든 결과 상태에 노출되는지 회귀 테스트.
- Not Okay 상태에서 bad ingredient 칩이 정확히 그려지는지.

### 8.3 통합 / 수동 테스트

- 시드 제품 바코드 인쇄 → 실기기 스캔으로 verdict 확인.
- 임의 ISBN/등록 안 된 바코드 스캔 → `not_found` 흐름.
- 원재료 누락 시드 1건 → `insufficient` 흐름.
- 비행기 모드 → 네트워크 오류 흐름.
- 권한 거부 → 설정 열기 → 허용 후 복귀.
- 백그라운드/포그라운드 lifecycle.

### 8.4 검증 디바이스

- iOS 실기기 1대 이상 (시뮬레이터는 카메라 검증 불가).
- Android 실기기 1대 이상.

### 8.5 도구

- `flutter analyze` — 경고 0.
- `flutter test` — 단위 + 위젯 테스트 통과.
- 룰 패키지 단위 테스트는 별도 CI step.

---

## 9. 패키지 의존성 (초안)

| 패키지 | 용도 |
|--------|------|
| `flutter_riverpod` ^3.3.1 | 상태 관리 |
| `supabase_flutter` ^2.12.4 | Supabase 클라이언트 |
| `mobile_scanner` ^7.2.0 | 카메라 + 바코드 디코딩 (ML Kit bundled) |
| `permission_handler` ^12.0.1 | 카메라 권한 처리 |
| `google_fonts` ^8.1.0 또는 번들 Pretendard | 한글 폰트 |
| `flutter_dotenv` ^6.0.1 | flavor별 `.env.{dev,staging,prod}` 로딩 |
| `happycart_rules` (path) | 자체 룰 패키지 |

버전은 EatSafe 시점 기준으로 시작하고 포크 직후 최신 안정으로 일괄 업그레이드 검토.

---

## 10. 운영 · 배포 · 데이터 거버넌스

### 10.1 환경 분리
- Supabase: `dev` / `staging` / `prod` 프로젝트 분리 (HappyCart 전용 신규 생성).
- 시드 데이터는 dev/staging에서 검증 후 prod에 적용. prod 직접 편집 금지.

### 10.2 스키마 마이그레이션
- Supabase CLI 마이그레이션 디렉터리(`supabase/migrations`) 사용.
- 모든 DDL은 마이그레이션 파일로만 적용.

### 10.3 시드 / 데이터 적재
- 시드 스크립트(`eatsafe/tool/compute_verdicts.dart` 의 HappyCart 버전)는 룰 패키지 호출 → `verdict`, `bad_ingredients_detected`, `good_ingredients_detected`, `verdict_reason_codes`, `rule_version`, `computed_at` 자동 계산.
- 모든 적재 행은 `source`, `source_url`, `source_checked_at`, `verified_status` 필드를 채워야 한다.
- 시드 입력 fixture는 `tool/fixtures/{category}/{slug}.json` 형식. 원재료 전문(`ingredients_raw`)과 정규화 토큰을 함께 보관.

### 10.4 백업
- prod는 Supabase 유료 플랜 자동 백업 또는 일 1회 SQL dump cron.

### 10.5 anon key 정책
- anon key는 빌드 산출물에 포함되며 비밀이 아니다.
- service_role 키는 절대 모바일 빌드에 포함하지 않으며, 로컬/CI 환경 변수로만 노출.

---

## 11. 분석 추적 (개인정보 없는 집계)

### 11.1 이벤트
- `scan_success`, `not_found`, `insufficient`, `network_error`.
- `verdict` 컬럼 값: `okay`, `not_okay`, `insufficient`, NULL.
- 클라이언트는 `log_scan_event(...)` RPC만 호출.

### 11.2 바코드 식별자 처리
- **어떤 형태로도 저장하지 않음** (원문도, 해시도). EatSafe와 동일 원칙.

### 11.3 남용 방어 & 보존
- 90일 retention, Supabase cron 일괄 삭제.
- 일 단위 집계는 `scan_events_daily` 롤업.

### 11.4 사용 목적
- 미등록률, 인식 실패율, 응답 지연 분포 등 MVP 운영 학습.
- okay/not_okay 비율로 시드 큐레이션 방향 조정.
- 사용자 식별 / 광고 추적 목적 사용 금지.

---

## 12. 안전 · 면책 정책

- 결과 화면 모든 상태에 면책 카드 상시 노출. 닫기 불가.
- 문구 (clean-eating 한계 명시):
  > "본 앱은 'clean eating' 철학을 기준으로 한 **참고 정보**입니다. 일부 성분(예: seed oils, carrageenan 등)에 대한 평가는 과학적으로 논쟁이 있을 수 있으며, 알레르기·질환·임신·영유아 식이는 제품 표시와 전문가 판단을 우선해주세요."
- 단정 표현 금지: "유해", "독성", "위험", "발암 확정" 등.
- 권장 표현: "포함되어 있어요", "주의 신호", "확인해보세요", "괜찮아요".
- 등급 라벨도 안전 보증으로 읽히지 않도록 한다.
  - `okay` → "괜찮아요" (절대 "안전" 단어 금지)
  - `not_okay` → "잠깐" (clean eating 기준상의 권고)
- 데이터 업데이트일(`source_checked_at`)과 룰 버전(`rule_version`) 결과 화면 메타 라인 표시.

---

## 13. 후속 단계 (이 스펙 밖)

- 결과 화면 확장: 원재료 전문 보기, 대안 제품 추천 ("이건 좀 더 깔끔해요").
- 영양 임계값 결합 판정 (ingredient + nutrition 듀얼 룰).
- 다중 프로필 모드 (저당 / 키토 / 비건 / 글루텐프리 등) — verdict가 프로필별로 달라짐.
- 익명 디바이스 ID 도입 후 스캔 이력 / 저장 / 즐겨찾기.
- 홈 / 검색 / 저장 / 프로필 4개 탭.
- 미등록 제품 사용자 제보 흐름 (사진 + 원재료 입력).
- 영양성분표 / 원재료명 OCR.
- 제품 이미지 수집 & Storage 운영.
- 식약처 식품안전나라 API 정기 동기화.
- 룰 출처 투명성 화면 ("왜 이 성분이 not_okay인가요?" → 카테고리별 근거 + 논쟁 여지 명시).

---

## 14. EatSafe → HappyCart 포크 시 주요 변경점 요약

본 스펙은 EatSafe `2026-05-13-eatsafe-barcode-scanner-design.md`를 베이스로 한다. 포크 시 다음 항목이 변경된다:

| 영역 | EatSafe | HappyCart |
|---|---|---|
| 컨셉 | 영양 임계 기반 4-tier 신호등 (초등 부모 타깃) | clean-eating ingredient 기반 2-tier (일반인 타깃) |
| Verdict | `ok` / `warn` / `bad` / `insufficient` | `okay` / `not_okay` / `insufficient` |
| 결정 입력 | 나트륨/당류/포화지방/카페인 수치 + 첨가물 트리거 | 원재료 토큰 키워드 매칭만 |
| 룰 패키지 | `eatsafe_rules` (threshold 기반) | `happycart_rules` (keyword 기반) |
| 결과 화면 카피 | "먹어도돼" / "잠깐" / "안돼" | "괜찮아요" / "잠깐" |
| 미등록 메시지 | "아직 등록되지 않은 제품이에요" | "해피카트에서 이 물건을 찾을 수 없습니다" |
| 브랜드 컬러 | warm 베이지 (#F4EFE6) | 오렌지 (#FF7A1A) |
| 아이콘 | EatSafe 마스코트 (없음 — 텍스트) | OK 손 + 쇼핑카트 (`happy-cart.png`) |
| Bundle ID | `com.eatsafe.*` | `com.rimonhouse.happycart` |
| Supabase | EatSafe dev/staging/prod | HappyCart 전용 신규 dev/staging/prod |
| 면책 강조점 | 의학/어린이 식이 | clean-eating 철학의 과학적 논쟁 가능성 |

---

## 15. 확정 결정 (2026-05-20 사용자 리뷰 반영)

| 항목 | 결정 |
|---|---|
| Verdict 라벨 | **"괜찮아요" / "잠깐"** (한글만, 영문 병기 없음) |
| Good ingredient 칩 | `not_okay` 상태에서도 별도 섹션으로 **함께 노출** (균형감) |
| Insufficient vs Not Found | **분리 유지** (분석 정확도 + 후속 OCR 도입 시 전환 가치) |
| 시드 큐레이션 규모 | **15~20개**로 MVP 검증 시작. 출시 단계에서 100개 이상으로 확장 |
| 지원 바코드 형식 | **EAN-13 / EAN-8 만**. UPC-A는 후속 단계 (단, EAN-13의 0-prefix 형태로 들어오는 UPC-A는 자동 매칭됨) |
| 룰 출처 / 근거 노출 화면 | MVP **out of scope**. §13 후속 단계에 명시 |

---
