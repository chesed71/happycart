# HappyCart 시드 큐레이션 가이드

> 시드 데이터 생성 fixture 모음. clean-eating 철학 (ingredient-based) 기준의
> Okay / Not Okay 사례를 카테고리별로 균형있게 확보하는 것이 목표.

스펙 §5.7 참조.

---

## 큐레이션 목표 (MVP)

- 15~20개 소규모로 시작해 핵심 룰을 검증한다.
- 출시 단계에서 100개 이상으로 확장 (별도 작업).

### 카테고리별 권장 분포

| 카테고리 | 예시 | 기대 verdict |
|---|---|---|
| 올리브오일 | 유기농 EVOO 1~2종 | okay |
| 가공 식용유 | 일반 식용유 (대두유 / 카놀라유) | not_okay |
| 탄산음료 | 일반 콜라(HFCS·색소), 제로 콜라(아스파탐) | not_okay |
| 자연 감미료 | 국산 꿀, 메이플시럽 | okay |
| 가공 스낵 | 합성 보존제·향료 과자 | not_okay |
| 통곡물 | 통밀 시리얼 | okay |
| 가공육 | 아질산나트륨 햄/소시지 | not_okay |
| 발효식품 | 김치 (단순 원재료) | okay |

---

## fixture JSON 포맷

`seed_products.json` 한 파일에 `products` 배열을 둔다.

| 키 | 필수 | 비고 |
|---|---|---|
| `fixed_computed_at` | ✅ | 루트에 한 번. ISO8601 UTC. migration idempotency 용 |
| `barcode` | ✅ | EAN-13 또는 EAN-8 시중 실제 GTIN. 임시 ID 금지 |
| `brand` | ✅ | 브랜드 |
| `name` | ✅ | 제품명 |
| `size` | ✅ | 용량 표시 그대로 (예: "500ml") |
| `category` | ❌ | 한국어 카테고리명 (선택) |
| `ingredients_raw` | ✅ | 라벨 원재료 원문 |
| `ingredients_tokens` | ✅ | 정규화된 토큰 리스트 — 룰 매칭 입력 |
| `source` | ✅ | 출처 식별자 (`manual` / `식약처` / `제조사 공식` 등) |
| `source_url` | ❌ | 출처 링크 |
| `source_checked_at` | ✅ | 출처 확인 시각 (ISO8601 UTC) |
| `verified_status` | ❌ | 기본 `verified`. 검수 전이라면 `unverified` |
| `image_url` | ❌ | 앱에 노출할 대표 이미지 URL. 가능하면 Supabase Storage 공개 URL |
| `image_source_url` | ❌ | 대표 이미지를 만들 때 사용한 원본 벤더/CDN URL. 앱 RPC에는 노출하지 않음 |
| `expected_verdict` | ❌ | 선택. sanity check 용 (`okay` / `not_okay` / `insufficient`) |

룰 매칭 결과(`verdict`, `bad_ingredients_detected`, `good_ingredients_detected`,
`verdict_reason_codes`, `rule_version`, `computed_at`) 는 `compute_verdicts.dart`
가 자동 산출한다 — fixture 에 수동 입력하지 않는다.

---

## 토큰 정규화 권장 규칙

1. 괄호 안 부연 설명은 별도 토큰으로 분리 (예: "팜유(말레이시아산)" → "팜유", "팜유(말레이시아산)" 둘 다 추가).
2. "외 N종", "기타 1종" 같은 모호 표기는 제외하되, 추가 검증이 필요한 경우 `verified_status: needs_review` 로 둔다.
3. 외국어 표기와 한국어 표기를 둘 다 본 경우 두 토큰 모두 추가 (예: "탄산수소나트륨", "sodium bicarbonate").
4. 영양 정보(나트륨 mg 등) 는 본 MVP 룰의 입력이 아니다 — fixture 에 두지 않는다.

---

## 생성 절차

```bash
cd happycart
dart run --verbosity=error tool/compute_verdicts.dart \
  > ../supabase/migrations/0005_seed_products.sql
```

생성된 SQL 을 검수한 뒤 Supabase project 에 적용한다. 동일 fixture (특히
`fixed_computed_at`) 로 재실행하면 byte-identical 출력 → 마이그레이션 idempotent.

---

## 향후 확장

- OCR / 자동 라벨 수집 파이프라인 도입 시 fixture 생성을 자동화.
- 사용자 제보 흐름 (`product_submissions` 테이블) 도입 시 검수 워크플로와 연결.
