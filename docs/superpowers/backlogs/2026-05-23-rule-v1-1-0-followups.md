# 룰 v1.1.0 적용 후 후속 작업

> 2026-05-22~23 사이 `refined_sugar` 카테고리 신설(룰 v1.1.0) 작업 이후
> 모이는 후속 정리 항목. 모이는 대로 한 번에 처리해서 빌드/배포 횟수 절약.

- 작성일: 2026-05-23
- 관련 파일:
  - `packages/happycart_rules/lib/src/bad_ingredients.dart`
  - `packages/happycart_rules/lib/src/headline.dart`
  - `packages/happycart_rules/lib/src/verdict.dart` (ruleVersion)
  - `supabase/migrations/0008_rule_v1_1_0_resync.sql`
  - `docs/superpowers/backlogs/2026-05-21-rule-gaps.md`

---

## 1. 백로그 Case 1/6/7 에 "v1.1.0 에서 해결됨" 표시

`2026-05-21-rule-gaps.md` 의 다음 케이스들이 룰 v1.1.0 의 `refined_sugar` 신설로
verdict 가 `okay → not_okay` 로 전환되어 갭이 해결됨. 각 케이스 헤더 또는
하단에 해결 표시 추가 필요.

- **Case 1 (오레오)**: tokens 에 `설탕` 포함 → 매칭 → not_okay. 기대 verdict 와
  계산 verdict 일치. Case 1 의 "제안되는 룰 보완" 중 6번(refined_sugar) 항목이
  이번 작업으로 부분 반영됨.
- **Case 6 (3분 쇠고기카레)**: tokens 에 `설탕` 포함 → 매칭 → not_okay.
  fixture 의 expected_verdict 도 `not_okay` 로 업데이트 완료.
- **Case 7 (진라면 매운맛)**: tokens 에 `설탕` 포함 → 매칭 → not_okay.
  fixture 의 expected_verdict 도 `not_okay` 로 업데이트 완료.

**남은 갭** (이번 작업으로 해결되지 *않은* 부분):
- Case 1 의 팜유/팜스테아린유, 향료, 바닐린, 폴리글리세린축합리시놀레인산에스테르 등.
- Case 6/7 의 변성전분, 식물성유지, 향미증진제, opaque seasoning 등.
- → 별도 카테고리 신설이 필요한 항목. 아래 §2 와는 별개 작업.

---

## 2. 정제당 alias 확장 (sugar 카테고리)

현재 sugar entry 의 alias 는 `['설탕']` 1개. 한국 라벨에 흔히 나오지만 매칭
안 되는 정제당 표기들이 다수 존재. 다음 단계로 확장 검토.

| alias 후보 | 매칭 예 | 영향받는 기존 시드 |
|---|---|---|
| `정백당` | `정백당` 그대로 | 동원 참치액, 칸쵸, 곡물100? |
| `백설탕` | `백설탕`, `정제 백설탕` | (이미 substring 으로 잡힘) |
| `분당` | `분당` (정제 설탕 가루) | 칸쵸 |
| `포도당` | `포도당` (글루코스) | 오레오, 진라면 |
| `과당` | `과당` (프럭토스) | (시드에 없음) |

**검토 사항**:
- `분당` 은 짧은 단어라 false positive 위험 (예: "분당 시" 지명 등). 룰은
  토큰 단위라 큰 위험은 아니지만 라벨 정규화 시 확인.
- `과당` 은 액상과당(HFCS)과 별개. 액상과당은 이미 `hfcs` 룰이 잡음.
- 자연 감미료(꿀, 메이플시럽, 코코넛슈가 등)는 별도 `good` 카테고리 또는
  단순 비대상.

**작업 절차** (룰 변경 후 작업 표준 — `2026-05-21-rule-gaps.md` §2.3 참조):
1. `bad_ingredients.dart` 의 sugar entry aliases 확장
2. `verdict_test.dart` 에 회귀 테스트 (정백당/분당 매칭 + false positive 검증)
3. `ruleVersion` v1.1.0 → v1.1.1 (patch — alias 확장만)
4. fixture `expected_verdict` 재검토 (시드 7건 영향 확인)
5. `compute_verdicts.dart` 전체 재실행 → 0009 migration 작성 (DELETE + INSERT)
6. dev push + RPC 검증

---

## 3. APK 재빌드 + Firebase App Distribution 재배포

룰 패키지 코드는 v1.1.0 으로 업데이트됐지만 테스터 폰에 설치된 APK 는
v1.0.0 시점 빌드. 다음 빌드 시점까지의 동작:

- ✅ verdict 자체 (`not_okay`) 는 RPC 응답이라 옛 APK 도 정확히 표시.
- ⚠️ reason 칩이 `refined_sugar` 영문으로 표시됨 (옛 APK 의 headline 매핑에
  refined_sugar 없음). 사용자가 의미는 이해 가능하지만 UX 손실.

**작업 절차**:
1. `flutter build apk --release --flavor=staging` 또는 적절한 빌드 옵션
2. `firebase appdistribution:distribute build/app/outputs/.../app-release.apk`
3. 테스터 그룹에 자동 배포 알림
4. 테스터 확인 후 production 빌드 검토 (현 시점은 production 배포 아직 없음)

**묶어서 처리하면 좋은 다른 변경**:
- §2 (정제당 alias 확장) 작업 끝나면 함께 빌드 — 한 번 배포로 다중 변경 반영.
- backlog 새 카테고리(`palm_oil_processed`, `vague_seasoning_blend` 등) 작업도
  쌓이면 동시 반영.

---

## 4. git commit 정리

현재 작업 트리에 미커밋 변경분 다수 (CLAUDE.md 규칙: 사용자 명시 요청 시에만
커밋). 정리할 시점 가늠.

**미커밋 파일 (예상)**:
- `supabase/migrations/0005_seed_products.sql` — 이미 push 됨, untracked
- `supabase/migrations/0006_seed_products_v2.sql` — 3분 쇠고기카레 시드
- `supabase/migrations/0007_seed_products_v3.sql` — 진라면 시드
- `supabase/migrations/0008_rule_v1_1_0_resync.sql` — v1.1.0 resync
- `happycart/tool/fixtures/seed_products.json` — 시드 7건 + expected_verdict 갱신
- `packages/happycart_rules/lib/src/bad_ingredients.dart` — refined_sugar entry
- `packages/happycart_rules/lib/src/verdict.dart` — ruleVersion bump
- `packages/happycart_rules/lib/src/headline.dart` — refined_sugar 라벨
- `packages/happycart_rules/test/verdict_test.dart` — sugar 테스트
- `packages/happycart_rules/test/headline_test.dart` — refined_sugar 테스트
- `docs/superpowers/backlogs/2026-05-21-rule-gaps.md` — Case 6, 7 추가
- `docs/superpowers/backlogs/2026-05-23-rule-v1-1-0-followups.md` — 본 문서
- `docs/superpowers/specs/2026-05-22-data-collection-design.md` — 별도 작업
- `.env.local` — gitignored, 커밋 대상 아님

**제안 커밋 분리**:
1. `feat(seeds): 6/7번 시드 추가 (오뚜기 3분 카레, 진라면) — v1.0.0 룰 기준`
   - 0006/0007 migration + seed_products.json (해당 2건만)
   - rule-gaps.md Case 6, 7
2. `feat(rules): refined_sugar 카테고리 신설 — 룰 v1.1.0`
   - bad_ingredients.dart, verdict.dart, headline.dart
   - verdict_test.dart, headline_test.dart
   - seed_products.json (expected_verdict 갱신 부분)
   - 0008 migration
3. `docs(backlogs): v1.1.0 후속 정리 노트`
   - 본 문서

---

## 5. 검토 보류 / 미정 항목 (참고)

- `caution` verdict 단계 도입 여부 (Case 6, 7 누적 분석 §1.2)
- 회색지대 카테고리 신설 (`palm_oil_processed`, `vague_seasoning_blend`,
  `modified_starch_concern`, `gum_thickener`, `vague_msg`)
- 영양 임계 결합 룰 (Case 2 §1.2)
- 의도된 production 배포 시점 (현재는 dev 만 활성)
