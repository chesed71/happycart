# 식약처/공공데이터포털 공식 OpenAPI 데이터 출처 활용 검토

> NomaDamas `k-skill` 의 `mfds-food-safety` 스킬 문서를 검토하다 파생된 항목.
> 그 스킬 자체(부적합·회수 식품 체크)는 우리와 결이 다르지만, 그 스킬이 쓰는
> `data.go.kr` / 식품안전나라 OpenAPI 생태계에 우리 데이터 수집 파이프라인이
> 필요한 공식 데이터(바코드→제품정보, 원재료, 영양, 이미지)가 있다는 점이 핵심.
> 당장 구현하지 않고, 검증 실험 후 도입 여부 결정.

- 작성일: 2026-05-26
- 출처: `https://github.com/NomaDamas/k-skill/blob/main/docs/features/mfds-food-safety.md`
- 관련 스펙: `docs/superpowers/specs/2026-05-22-data-collection-design.md` (현재 OCR 기반 수집)
- 관련 원칙: 메모리 `feedback_ocr_hallucination` (OCR 추측 금지)

---

## 1. 배경 — 어디서 나온 항목인가

`k-skill` 의 `mfds-food-safety` 스킬은 **식약처 부적합 식품 + 식품안전나라
회수·판매중지 목록 조회 + 증상 인터뷰**가 전부다. 원재료/바코드/영양정보는
다루지 않으므로 그 기능 자체는 우리 verdict 엔진에 직접 쓸 게 없다.

그러나 그 스킬이 사용하는 **출처 생태계**(공공데이터포털 `data.go.kr`,
식품안전나라 OpenAPI)와 **단일 API 키(`DATA_GO_KR_API_KEY`)** 가, 우리 데이터
수집의 최대 약점(아래 §2)을 정면으로 해결할 수 있다는 게 이 백로그의 요지다.

---

## 2. 왜 중요한가 — 현재 수집 파이프라인의 약점

`2026-05-22-data-collection-design.md` 의 현재 흐름은 **라벨 사진 → vision OCR
→ 구조화(barcode/brand/name/ingredients_tokens) → 룰**이다. 그 문서의 위험
표(§10)에서 최상위가 "OCR 실패율 / 잘못된 데이터 자동 적재"이고, 메모리에도
"OCR 추측 금지" 피드백이 박혀 있다.

공식 API로 바코드 → 제품정보를 직접 조회하면:
- 추측(hallucination) 제거 → **정확도 상승**
- vision 호출 감소 → **LLM 토큰 비용 절감**
- `source = 식약처/식품안전나라` → **공식 출처** 확보 (`source_url`/`source_checked_at`)
- 보너스: 제품이미지URL 확보 (스펙상 MVP는 placeholder, 이미지 수집은 후속이었음)

도입 형태는 **완전 대체가 아니라 "공식 API 1차 조회 → 미등록/누락 시 OCR fallback"**.

---

## 3. 후보 데이터셋 (data.go.kr)

전부 동일한 `DATA_GO_KR_API_KEY` 하나로 접근. 필드 충실도·커버리지는 §6에서
실측 필요.

| 데이터셋 | 제공 필드(요지) | HappyCart 연결 | 링크 |
|---|---|---|---|
| 식약처_바코드연계제품정보 | 품목보고번호, 제품명, 식품유형, 제조사명, 유통바코드 | 바코드 → 제품 마스터 직결 | data.go.kr/data/15060549 |
| HACCP 제품이미지·포장지표기정보 | 제품명, 원재료, 알레르기, 영양성분, 바코드, 용량, 제품이미지URL | `products` 거의 전부 | data.go.kr/data/15033307 |
| 식약처_식품(첨가물)품목제조보고(원재료) | 품목별 원재료 | `ingredients_raw`/`tokens` 공급 | data.go.kr/data/15062098 |
| 식약처_식품원재료코드 | 원재료 표준 코드 | alias 정규화·표준화 | data.go.kr/data/15064780 |
| 식약처_유통바코드 | 유통 바코드 식별 | 바코드 보강 | data.go.kr/data/15064775 |
| 식약처_식품 원재료 정보 | 원재료 정보 | 원재료 보강 | data.go.kr/data/15058665 |

식품안전나라 OpenAPI 메인: `https://www.foodsafetykorea.go.kr/apiMain.do`

---

## 4. 아키텍처 정합성 (확인용 — 새 작업 아님)

- `k-skill-proxy` 가 키를 서버에 두고 클라이언트는 프록시만 호출 → 우리
  Supabase RPC(SECURITY DEFINER, 키 서버 보관)와 동일 철학.
- 도입 시 `DATA_GO_KR_API_KEY` 는 **nanoclaw 큐레이터 에이전트 / Supabase Edge
  Function 쪽에만** 두고 Flutter 앱엔 미포함. 보안 경계 원칙과 일치.

---

## 5. 부차 항목 — 회수·부적합 신호 오버레이 (보류)

우리 verdict는 순수 성분 기반이라, 성분은 깨끗(okay)한데 현재 회수 대상인
제품(대장균 초과·이물질 등)은 못 잡는다. 회수 API(`I0490` 등)를 "이 제품은 현재
회수 대상" 사실 배너로 덧붙이는 안.

**보류 사유**:
- 스펙이 "의학적 안전 판단 도구 아님"을 명시 — 스코프 확장 결정 필요.
- 회수 데이터는 제품명·업체명 기준(fuzzy) → 우리 바코드 키와 매칭 까다로움.
- → 별도 brainstorming 거리. 당장 안 함.

---

## 6. 다음 작업 (도입 결정 전 검증 — 지금은 실행 안 함)

1. `data.go.kr` API 키 발급 (본인 인증 필요).
2. 우리 시드 제품 바코드 몇 개로 `바코드연계제품정보` + `HACCP 포장지표기정보`
   실제 응답 확인 → **커버리지·필드 충실도 실측**.
3. 결과에 따라 `2026-05-22-data-collection-design.md` 에 "공식 API 1차 조회 →
   OCR fallback" 단계 추가 여부 결정.
4. 데이터셋별 라이선스(공공누리 유형)·rate limit 확인.

---

## 7. 주의점 (과대평가 금지)

- 정부 API 커버리지가 불완전할 수 있음(특히 수입식품·소규모 제조 누락) → OCR
  완전 대체 아님.
- 원재료명 표기가 비표준일 수 있어 토큰 정규화는 여전히 필요.
- rate limit·필드 실제 채움 정도·라이선스는 데이터셋마다 다름 → 키 발급 후
  실측 전까지 단정 금지.
