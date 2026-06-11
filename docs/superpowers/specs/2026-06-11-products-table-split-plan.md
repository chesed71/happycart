# products 테이블 분리 계획 — 마스터 / 바코드 변형

> **목적**: 원재료가 동일한데 바코드·중량·번들 구성만 다른 "변형 상품"을 중복 없이 관리하기 위해 `products` 단일 테이블을 `product_masters`(원재료·판정)와 `product_barcodes`(바코드 변형)로 분리한다.

- 작성일: 2026-06-11
- 관련 스펙: `supabase/SCHEMA.md` (현행 스키마), `docs/superpowers/specs/2026-05-20-happycart-clean-eating-design.md`
- 상태: 계획 (착수 전)

---

## 0. 한 줄 요약

바코드는 SKU(중량·번들)마다 다르지만 원재료와 판정은 같은 경우가 많다. 원재료·verdict 를 `product_masters` 한 곳에만 두고, 바코드·중량·이미지를 `product_barcodes` 로 분리해 변형 등록을 "바코드 한 행 추가"로 줄인다.

---

## 1. 배경 & 문제 정의

### 실제 발생 사례 (2026-06-10)

해태제과 구운감자를 현장에서 스캔했더니 미등록으로 떨어졌다. DB에는 24g 낱개(8801019317132)가 있었지만 스캔한 것은 2번들 48g(8801019310355)이었다. 원재료·판정이 완전히 동일한 제품인데 바코드가 달라 별도 행을 수동 복사로 등록해야 했다.

### 단일 테이블 구조의 문제

- 변형마다 ingredients_raw, ingredients_tokens, verdict, bad/good 매칭 결과가 통째로 중복된다.
- 한 변형의 원재료를 수정하면 다른 변형을 까먹기 쉽다 (불일치 위험).
- Data Desk 에서 미등록 변형을 등록할 때 어떤 필드를 복사해야 하는지 매번 판단해야 한다.
- 변형 관계가 데이터에 기록되지 않아 "이 두 행이 같은 상품"이라는 정보가 사람 기억에만 있다.

### 분리 시 기대 효과

- 원재료 수정·룰 재계산이 master 단위 한 번으로 끝난다.
- 미등록 변형 등록 = 기존 master 에 바코드 한 행 연결 (Data Desk 작업 최소화).
- 변형 그룹이 스키마 차원에서 명시된다.

---

## 2. 목표 스키마

### product_masters (원재료 + 판정)

기존 products 에서 바코드·SKU 종속 필드를 뺀 나머지 전부를 가진다.

- id (uuid PK), brand, name, category
- ingredients_raw, ingredients_tokens
- bad_ingredients_detected, good_ingredients_detected, verdict_reason_codes
- verdict, rule_version, computed_at
- source, source_url, source_checked_at, label_version, verified_status
- created_at, updated_at (트리거 자동 갱신)

CHECK 제약 3종(not_okay ↔ bad 매칭, okay ↔ bad 비움, insufficient ↔ tokens 비움)은 이 테이블로 이동한다.

### product_barcodes (바코드 변형)

SKU 종속 필드만 가진다.

- barcode (text PK) — 8자리 또는 13자리 숫자 CHECK 유지
- master_id (uuid FK → product_masters, NOT NULL, on delete restrict)
- size — 예: "24g", "48g (24g×2번들)"
- image_url, image_source_url — 변형마다 패키지 사진이 다를 수 있으므로 바코드 쪽에 둔다
- created_at, updated_at

설계 결정: 이미지가 master 공유인 경우 변형 행의 image_url 에 같은 URL 을 넣는다. Storage 경로 규칙(products/바코드.jpg)은 유지하되 공유 시 한 파일을 여러 행이 참조해도 된다.

### verified_status 의 위치

master 에 둔다. 원재료 판독의 신뢰도는 변형이 아니라 원재료 데이터 자체의 속성이기 때문이다. 단, "이 바코드가 정말 이 master 의 변형이 맞는지"의 확인 상태가 필요해지면 barcodes 쪽에 별도 컬럼을 추가한다 (이번 범위 밖).

---

## 3. 영향 범위

| 대상 | 변경 내용 |
|------|----------|
| lookup_product RPC | products 단일 조회 → barcodes 와 masters 조인으로 재작성. 반환 컬럼·타입은 기존과 동일하게 유지해 앱 호환성 보장 |
| log_pending_product RPC | "이미 등록된 상품" 존재 확인을 products → product_barcodes 조회로 변경 |
| Flutter 앱 | 변경 없음 (RPC 응답 형태가 동일하므로). 단 회귀 테스트는 수행 |
| upload_to_supabase.py (happycart_crawler 레포) | upsert 를 2단계로 변경 — master 를 먼저 upsert 하고 반환된 id 로 barcode 행 upsert. 동일 원재료 중복 판별 로직 추가 검토 |
| compute_verdicts.dart | 출력 SQL 이 단일 INSERT 전제이므로 시드 파이프라인 재작성 또는 산출물을 파이썬 쪽에서 변환 |
| Data Desk 인계 문서 | handover_pending_products_tab.md 의 등록 흐름에 "기존 master 검색 → 바코드 연결" 시나리오 추가 |
| supabase/SCHEMA.md | 분리 후 스키마로 갱신 |
| 기존 시드 마이그레이션 (0005~0009) | 수정하지 않는다 — 과거 이력으로 그대로 두고 신규 마이그레이션에서 데이터를 이전한다 |

---

## 4. 마이그레이션 전략

원칙: 한 마이그레이션 파일에서 "새 테이블 생성 → 데이터 이전 → RPC 재작성"까지 끝내되, 기존 products 테이블은 즉시 삭제하지 않고 한 단계 유예한다 (롤백 여지 확보).

### 0014 — 테이블 생성 + 데이터 이전 + RPC 전환

1. product_masters, product_barcodes 생성 (제약·인덱스·트리거 포함).
2. 기존 products 행을 masters 로 복사하되, 변형 그룹은 하나의 master 로 합친다.
   - 그룹핑 기준: ingredients_raw 가 완전히 동일하고 brand 가 같은 행들을 같은 master 로 본다.
   - 현재 데이터 기준 해당 케이스는 구운감자 24g/48g 한 쌍뿐이므로, 자동 그룹핑 + 마이그레이션 작성 시점에 수동 확인을 병행한다.
3. 각 products 행의 barcode, size, image_url, image_source_url 을 product_barcodes 로 복사하고 master 에 연결한다.
4. lookup_product 를 조인 버전으로 재작성한다 (drop 후 create, 권한 재부여).
5. log_pending_product 의 존재 확인 대상을 product_barcodes 로 바꾼다.
6. 이전 검증 쿼리를 마이그레이션 끝에 둔다 — barcodes 행 수가 기존 products 행 수와 같은지, master 수가 기대값(전체 - 변형 쌍 수)인지 assert.

### 0015 — 구 테이블 정리 (안정화 확인 후 별도 배포)

- products 테이블 RLS 는 default-deny 그대로이므로 노출 위험은 없다. 앱·파이프라인이 신규 구조로 1주 이상 정상 동작한 뒤 drop 한다.
- drop 전에 service_role 로 접근하는 도구(업로드 스크립트, Data Desk)가 더 이상 products 를 참조하지 않는지 grep 으로 확인한다.

---

## 5. 작업 순서 체크리스트

1. 마이그레이션 0014 작성 → 로컬 검토 → 검증: supabase db push 후 lookup_product 를 기존 50개 바코드 전수 호출해 분리 전 응답과 diff 가 없는지 확인
2. upload_to_supabase.py 를 2단계 upsert 로 수정 → 검증: dry-run + 실제 1건 업로드 후 masters/barcodes 행 확인
3. 시드 파이프라인(compute_verdicts.dart 산출물 처리) 방향 결정 및 수정 → 검증: 신규 fixture 1건으로 end-to-end
4. Flutter 회귀 테스트 → 검증: flutter test 전체 + 실기기에서 등록/미등록/변형 바코드 3종 스캔
5. Data Desk 인계 문서 갱신
6. SCHEMA.md 갱신
7. 1주 안정화 후 0015 로 products drop

---

## 6. 리스크 & 롤백

| 리스크 | 대응 |
|--------|------|
| 마이그레이션 중 데이터 누락 | 0014 안에 행 수 assert 포함. products 원본은 0015 까지 보존 |
| RPC 응답 형태가 미세하게 달라져 앱이 깨짐 | 반환 타입을 컬럼 단위로 기존과 동일하게 고정하고, 배포 전 전수 diff |
| 그룹핑 오판 (다른 상품을 같은 master 로 합침) | ingredients_raw 완전 일치 + brand 일치라는 보수적 기준 사용. 애매하면 합치지 않는다 — 중복은 안전하고 잘못된 병합은 위험하다 |
| 업로드 파이프라인과 마이그레이션 배포 타이밍 어긋남 | 0014 배포 직후 파이프라인 수정 버전을 같은 날 반영. 그 사이 업로드 작업 금지 |

---

## 7. 이번 범위에서 제외 (추후 검토)

- 변형 자동 감지 (미등록 스캔 시 이름·원재료 유사도로 기존 master 후보 제안) — Data Desk 기능으로 추후
- barcodes 쪽 변형 확인 상태 컬럼
- product_masters 의 동일 원재료 자동 dedup (업로드 파이프라인에서 ingredients_raw 해시 비교) — 2단계 upsert 안정화 후
