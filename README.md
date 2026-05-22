# HappyCart (해피카트)

> **"바코드 한 번에 'Okay / Not Okay' — clean-eating 철학으로 카트에 담을지 결정하는 한국어 식품 스캐너 앱"**

| 항목 | 값 |
|---|---|
| 프로젝트 | HappyCart / 해피카트 |
| 작성 시작 | 2026-05-20 |
| 전신 | EatSafe (`/Users/ronen/Project/EatSafe`) — 영양 임계 기반 신호등에서 ingredient 기반 clean-eating 으로 pivot |
| 현재 단계 | **MVP 골격 완성 → 시드 큐레이션 + 룰 갭 발견 단계** |
| 룰 버전 | `v1.0.0` |
| Android 빌드 | App Distribution 배포 작동 (1.0.0-dev) |
| iOS 빌드 | 미진행 (Apple Developer Program 가입 후 진행) |

---

## 0. 한 줄 요약

바코드 → 우리 Supabase DB 조회 → 사전 계산된 verdict(`okay`/`not_okay`/`insufficient`) 반환 → 결과 화면 표시. **룰은 서버 사이드**에 두고 클라이언트는 결과만 받는다. 판정 기준은 **인공감미료·HFCS·합성보존제·정제 씨앗유·인공색소 등 "clean-eating bad ingredient" 키워드 매칭**.

---

## 1. 핵심 컨셉

### 어떤 앱인가
- **타깃**: 일반 성인 소비자 (특정 라이프스테이지 한정 없음)
- **판정**: 2단계 (`okay` / `not_okay`) + `insufficient`(원재료 정보 부족) + `not_found`(미등록)
- **판정 원리**: 원재료 토큰 키워드 매칭. Bad ingredient 1개 이상 매칭 → `not_okay`, 0개 → `okay`.

### 무엇이 아닌가
- 의학적 안전 판단 도구가 아님 (면책 상시 노출)
- 영양 임계 기반 신호등 아님 (그건 EatSafe — 별개 프로젝트)
- 어린이 / 임산부 / 알레르기 프로필 모드 없음 (후속)

### Clean-eating 철학 한계 명시
일부 판정(seed oils, carrageenan 등)은 과학적으로 논쟁이 있어 면책 카드에 명시한다. "유해·독성·위험" 단정 표현 금지, "포함되어 있어요·확인해보세요" 권장 표현 사용.

---

## 2. 모노레포 디렉토리 구조

```
HappyCart/
├── README.md                          ← 이 파일
├── .gitignore                         ← 루트 모노레포 ignore
├── happy-cart.png                     ← 원본 마스코트 아이콘 (1024x1024)
│
├── docs/                              ← 문서
│   └── superpowers/
│       ├── specs/
│       │   └── 2026-05-20-happycart-clean-eating-design.md   ← 본 MVP 설계 스펙
│       ├── plans/                     ← (현재 비어있음)
│       └── backlogs/
│           └── 2026-05-21-rule-gaps.md  ← 시드 입력하며 발견된 룰 갭 누적
│
├── happycart/                         ← Flutter 앱 (메인)
│   ├── lib/
│   │   ├── main.dart                  ← Firebase + Supabase + Crashlytics 초기화
│   │   ├── firebase_options.dart      ← flutterfire configure 자동 생성
│   │   ├── app/
│   │   │   ├── app.dart               ← MaterialApp 루트
│   │   │   ├── env.dart               ← .env.{flavor} 로드
│   │   │   └── theme.dart             ← 오렌지 브랜드 팔레트
│   │   ├── core/
│   │   │   ├── barcode_validator.dart ← EAN-13 / EAN-8 체크섬
│   │   │   ├── disclaimer_card.dart   ← 상시 면책 카드
│   │   │   └── verdict.dart           ← 룰 패키지 enum re-export
│   │   ├── data/
│   │   │   ├── analytics_client.dart  ← log_scan_event RPC (익명 집계)
│   │   │   ├── exceptions.dart        ← NetworkException
│   │   │   ├── product_repository.dart ← lookup_product RPC
│   │   │   └── models/
│   │   │       └── product_lookup_result.dart
│   │   └── features/
│   │       ├── scan/
│   │       │   ├── scan_controller.dart   ← Riverpod ScanController
│   │       │   └── scan_screen.dart       ← 카메라 + EAN 인식
│   │       └── result/
│   │           ├── result_state.dart      ← 5상태 sealed class
│   │           └── result_page.dart       ← okay/not_okay/not_found/insufficient/network_error
│   ├── android/                       ← Android (com.rimonhouse.happycart)
│   ├── ios/                           ← iOS (com.rimonhouse.happycart)
│   ├── assets/icon/icon.png           ← happy-cart.png 복사본 (launcher icon 입력)
│   ├── tool/
│   │   ├── compute_verdicts.dart      ← 시드 빌더 (fixture → SQL)
│   │   └── fixtures/
│   │       ├── README.md              ← 큐레이션 가이드
│   │       └── seed_products.json     ← 5개 시드 (오레오·참치액·칸쵸·현미유·올리고당)
│   ├── test/                          ← 단위/위젯 테스트 (stub — 후속 재작성)
│   ├── pubspec.yaml                   ← name: happycart
│   └── .env.development               ← Supabase URL + publishable key (gitignored)
│
├── packages/happycart_rules/          ← Pure Dart 룰 패키지
│   ├── lib/
│   │   ├── happycart_rules.dart       ← 패키지 export
│   │   └── src/
│   │       ├── verdict.dart           ← Verdict enum + computeVerdict()
│   │       ├── bad_ingredients.dart   ← 15가지 reason code × 30+ 키워드
│   │       ├── good_ingredients.dart  ← 9가지 reason code × 17 키워드
│   │       └── headline.dart          ← 결과 화면 카피 + 라벨 매핑
│   └── test/                          ← 31개 테스트 (전부 통과)
│
└── supabase/
    ├── config.toml                    ← Supabase CLI 설정
    └── migrations/
        ├── 0001_products.sql          ← products 테이블 (ingredient 컬럼 + verdict enum)
        ├── 0002_lookup_product.sql    ← SECURITY DEFINER RPC
        ├── 0003_scan_events.sql       ← 익명 집계 테이블
        └── 0004_log_scan_event.sql    ← 90일 retention RPC
```

---

## 3. 기술 스택

| 영역 | 사용 기술 |
|---|---|
| 앱 프레임워크 | Flutter 3.41.9 / Dart 3.11.5 |
| 상태 관리 | Riverpod 3.3.1 |
| 바코드 스캔 | `mobile_scanner` 7.x (EAN-13/EAN-8 only) |
| DB / Auth | Supabase Postgres (anon key + SECURITY DEFINER RPC) |
| 분석/배포 | Firebase Crashlytics + App Distribution |
| 폰트 | Pretendard 대체로 Noto Sans KR (`google_fonts`, 런타임 다운로드) |
| 룰 엔진 | `packages/happycart_rules` — Pure Dart, no Flutter deps |
| 빌드 시그닝 | Android keystore (jks) — release.jks |
| iOS 빌드 | (보류 — Apple Developer Program 가입 후 진행) |

---

## 4. 데이터 흐름

```
[사용자]
   │
   │ 바코드 스캔
   ▼
[ScanScreen + mobile_scanner]
   │ EAN-13/EAN-8 체크섬 검증
   ▼
[ScanController (Riverpod)]
   │
   ▼
[ProductRepository.lookupByBarcode()]
   │
   │ RPC: lookup_product(p_barcode)
   ▼
[Supabase happycart-dev]
   │  - public.products (RLS default-deny)
   │  - lookup_product() RPC (SECURITY DEFINER + search_path='')
   │
   ▼ 0행 / 1행
[ResultState 분기]
   │
   ├─ 0행            → NotFoundResultState
   ├─ verdict=okay    → SuccessResultState (괜찮아요)
   ├─ verdict=not_okay→ SuccessResultState (잠깐, bad chip 표시)
   ├─ verdict=insufficient → InsufficientResultState
   └─ NetworkException → NetworkErrorResultState
   
   동시에: AnalyticsClient.logScanXxx() → log_scan_event RPC (90일 retention)
```

**룰 계산 위치**: 클라이언트 아님. 시드 빌드 시점에 `tool/compute_verdicts.dart` → `happycart_rules` 패키지가 ingredient 토큰을 매칭해 `verdict`/`bad_ingredients_detected`/`reason_codes` 컬럼을 미리 채워서 Supabase에 INSERT. 클라이언트는 결과만 받는다.

---

## 5. 룰 시스템 (`happycart_rules` v1.0.0)

### Bad Ingredient 카테고리 (Not Okay 트리거)
1개 이상 매칭되면 `verdict=not_okay`.

| reason code | canonical 키 예시 | 라벨 alias 예시 |
|---|---|---|
| `artificial_sweetener` | aspartame, sucralose, acesulfame_k, saccharin | 아스파탐, 수크랄로스, E951 등 |
| `artificial_color` | red_40, yellow_5/6, blue_1, red_3 | 적색40호, 황색5호, tartrazine, E102 등 |
| `hfcs` | hfcs | 고과당옥수수시럽, 액상과당, 콘시럽, HFCS |
| `seed_oil` | soybean_oil, canola_oil, corn_oil, sunflower_oil_refined, cottonseed_oil | 대두유, 카놀라유, 옥수수유, 정제 해바라기씨유, 면실유 |
| `hydrogenated_oil` | hydrogenated | 경화유, 부분경화유, 트랜스지방 |
| `synthetic_preservative` | bha, bht, tbhq | BHA, BHT, TBHQ, E319-321 |
| `nitrite` | sodium_nitrite, sodium_nitrate | 아질산나트륨, sodium nitrate, E250/251 |
| `carrageenan` | carrageenan | 카라기난, E407 |
| `emulsifier_concern` | polysorbate_80, datem, mono_diglycerides | 폴리소르베이트80, DATEM, 모노/디글리세리드, E471 |
| `opaque_flavor` | natural_flavors_opaque, artificial_flavors | natural flavors, 천연향료, 합성착향료, 인공향료 |
| `refined_flour` | bleached_flour, enriched_flour | 표백 밀가루, 강화 밀가루 |
| `bromate` | potassium_bromate | 브롬산칼륨, E924 |
| `maltodextrin` | maltodextrin | 말토덱스트린, E1400 |

### Good Ingredient (보조 chip 표시 — verdict에 영향 없음)
clean fat (EVOO, 아보카도, 코코넛, grass-fed 버터), natural sweetener (꿀, 메이플시럽, 대추야자), sea salt, whole grain, fermented (김치, 케피어, 콤부차), organic, pasture-raised egg, grass-fed beef.

### 매칭 규칙
- 토큰 단위 정규화 (소문자, 공백·괄호·하이픈 제거) 후 부분 문자열 매칭
- E-number alias 는 정확 매칭만 (E1400 ≠ E14000)
- 한국어/영어 alias 모두 동일 정규화 함수 적용

### Wire 표기 (DB enum)
- `Verdict.okay` ↔ `'okay'`
- `Verdict.notOkay` ↔ `'not_okay'`
- `Verdict.insufficient` ↔ `'insufficient'`
- `not_found` 는 DB 행 부재로 표현 (enum 미포함)

---

## 6. 외부 서비스

### Supabase (happycart-dev)
| 항목 | 값 |
|---|---|
| Project Ref | `ftgsnvvskbadegswvjnp` |
| URL | `https://ftgsnvvskbadegswvjnp.supabase.co` |
| Region | Northeast Asia (Seoul) |
| 조직 | `mapjrndumwtqscmzyznp` (건물클리닉) |
| 마이그레이션 | 0001~0004 적용 완료 |
| 시드 SQL | 미생성 (룰 갭 결정 후 일괄 생성 예정) |
| 계정 | EatSafe Supabase 와 별개 계정 |

### Firebase (happycart-dev)
| 항목 | 값 |
|---|---|
| Project ID | `happycart-dev` |
| Android Package | `com.rimonhouse.happycart` |
| Mobile App ID | `1:417373019518:android:6d5d968b68c9ed0969e72f` |
| Google Account | `hagjun580400@gmail.com` |
| App Distribution | 1.0.0-dev 두 차례 배포됨 (EatSafe 아이콘 → HappyCart 마스코트) |
| Crashlytics | 활성화 (debug 빌드 비활성, release 만 수집) |
| 테스터 | `hagjun580400@gmail.com`, `chesed71@gmail.com` |

---

## 7. 빌드 / 배포 흐름 (Android)

```
1. flutter pub get
2. dart run --verbosity=error tool/compute_verdicts.dart > ../supabase/migrations/0005_seed_products.sql
3. supabase db push                                  ← 시드 적용
4. flutter build apk --flavor development --release  ← release.jks 로 서명
5. firebase appdistribution:distribute build/.../app-development-release.apk \
     --app 1:417373019518:android:6d5d968b68c9ed0969e72f \
     --release-notes "버전 노트" \
     --testers "hagjun580400@gmail.com,chesed71@gmail.com"
```

### Flavor
모든 flavor 동일 `applicationId = com.rimonhouse.happycart` (Firebase 단일 등록 매칭). 환경 분리는 `.env.{development,staging,production}` 파일 선택으로만 처리.

### `versionNameSuffix`
- development → `-dev`
- staging → `-staging`
- production → (없음)

---

## 8. 안전 보관 위치 (Secrets / Keys)

| 파일 | 용도 | 권한 |
|---|---|---|
| `~/.config/happycart/supabase-token` | Supabase access token | 600 |
| `~/.config/happycart/db-password-dev` | Supabase DB 비밀번호 | 600 |
| `~/.config/happycart/android-keystore/release.jks` | Android release 서명 키 | 600 |
| `~/.config/happycart/android-keystore/keystore-password` | keystore 비밀번호 | 600 |
| `happycart/.env.development` | Supabase URL + anon key | (gitignored) |
| `happycart/android/key.properties` | gradle 이 read 하는 keystore 참조 | 600, gitignored |
| `happycart/android/app/google-services.json` | Firebase Android 구성 | 커밋 OK (앱 측 식별자만) |

### ⚠️ 분실 시 영향
- **`release.jks`**: 분실 시 동일 앱 업데이트 불가. **1Password / iCloud Drive 등에 백업 강력 권장**.
- **Supabase token**: 채팅에 노출됐던 토큰은 폐기/재발급 권장.

---

## 9. 시드 현황 (2026-05-21 기준)

5개 제품 입력 / SQL 미생성 (룰 갭 결정 후 일괄 push 예정)

| # | 바코드 | 브랜드 | 제품명 | expected | computed | 일치 | 백로그 |
|---|---|---|---|---|---|---|---|
| 1 | 8801037088168 | 오레오 | 오리지널 100g | not_okay | okay | ❌ | Case 1 |
| 2 | 8801047216438 | 동원 | 순참치액 500g | okay | okay | ✅ | Case 2 |
| 3 | 8801062516735 | 롯데 | 칸쵸 초코 196g | not_okay | not_okay | ✅ | Case 3 |
| 4 | 8851103220480 | Golden Field | Rice Bran Oil 1L | okay | okay | ✅ | Case 4 |
| 5 | 8801052727523 | 청정원 | 곡물100 1.2kg | okay | okay | ✅ | Case 5 |

---

## 10. 룰 갭 현황 (`docs/superpowers/backlogs/2026-05-21-rule-gaps.md`)

### 발견된 5종 케이스
- **Case 1 (오레오)** ⚠️ — 룰 갭 false negative
- **Case 2 (참치액)** ✅ — 룰 정상
- **Case 3 (칸쵸 초코)** ✅✅ — 룰 적중 (HFCS+카라기난+말토덱스트린)
- **Case 4 (현미유)** 🟡 — clean-eating 회색지대 (식물유 분류)
- **Case 5 (옥수수 올리고당)** 🟡 — clean-eating 회색지대 (정제 시럽)

### v1.0.0 가장 큰 한계
**라벨에 키워드가 두루뭉술하게 적힌 가공식품** (오레오 = "향료"·"바닐린"으로만 표기)을 통과시킴. 반면 라벨이 솔직한 가공식품(칸쵸 = "고과당옥수수시럽" 명시)은 잘 잡음.

### 보완 옵션 (백로그 §1 안에 상세)
- 카테고리 신설: `palm_oil_processed`, `vague_flavor`, `processed_corn_syrup`
- alias 확장: 바닐린, vanillin, 폴리글리세린지방산에스테르, 해바라기유 등
- 영양 임계 결합 룰 (현재 ingredient-only)
- false positive 위험 vs strict 정책 trade-off

---

## 11. 다음 마일스톤

### 즉시 가능
- [ ] 시드 더 입력 (회색지대 패턴 확정 위해 5~10건 더)
- [ ] 현재 시드 5건만 Supabase에 push → 앱에서 실제 스캔 검증
- [ ] 첫 git commit (현재 stage 대기 중)

### 단기 (1~2주)
- [ ] 룰 v1.1.0 결정 (회색지대 정책 + 라벨 키워드 보완)
- [ ] 깨진 테스트 파일 6개 재작성 (현재 stub)
- [ ] 시드 30~50개 큐레이션 (베타 출시 최소 규모)
- [ ] Pretendard 폰트 로컬 번들

### 중기 (1~2개월)
- [ ] iOS 빌드 추가 (Apple Developer Program 가입 시)
- [ ] staging / production Supabase + Firebase 프로젝트 분리
- [ ] CI/CD (GitHub Actions: analyze + test + auto distribute)
- [ ] 사용자 인터뷰 5명 (회색지대 진영 결정)

### 후속 (스펙 §13)
- 영양 임계 결합 룰
- 다중 프로필 모드 (저당, 키토, 비건, 글루텐프리)
- 익명 디바이스 ID + 스캔 이력 / 즐겨찾기
- 미등록 제품 사용자 제보 + OCR
- 식약처 식품안전나라 API 정기 동기화

---

## 12. 빠른 명령 레퍼런스

### 룰 패키지 테스트
```bash
cd /Users/ronen/Project/HappyCart/packages/happycart_rules
dart test
```

### 시드 SQL 생성 (드라이런)
```bash
cd /Users/ronen/Project/HappyCart/happycart
dart run --verbosity=error tool/compute_verdicts.dart
```

### Flutter 정적 분석
```bash
cd /Users/ronen/Project/HappyCart/happycart
flutter analyze
```

### Android Release 빌드
```bash
cd /Users/ronen/Project/HappyCart/happycart
flutter build apk --flavor development --release
```

### Firebase App Distribution 업로드
```bash
unset NODE_OPTIONS
cd /Users/ronen/Project/HappyCart/happycart
firebase appdistribution:distribute build/app/outputs/flutter-apk/app-development-release.apk \
  --app 1:417373019518:android:6d5d968b68c9ed0969e72f \
  --release-notes "릴리스 노트" \
  --testers "hagjun580400@gmail.com,chesed71@gmail.com"
```

### Supabase 마이그레이션 push
```bash
cd /Users/ronen/Project/HappyCart
SUPABASE_ACCESS_TOKEN=$(cat ~/.config/happycart/supabase-token) \
SUPABASE_DB_PASSWORD=$(cat ~/.config/happycart/db-password-dev) \
  supabase db push
```

---

## 13. 문서 인덱스

| 문서 | 위치 | 용도 |
|---|---|---|
| **스펙** | `docs/superpowers/specs/2026-05-20-happycart-clean-eating-design.md` | 본 MVP의 모든 설계 결정 (15개 섹션) |
| **룰 갭 백로그** | `docs/superpowers/backlogs/2026-05-21-rule-gaps.md` | 시드 입력하며 발견되는 룰 한계 누적 |
| **시드 큐레이션 가이드** | `happycart/tool/fixtures/README.md` | fixture JSON 작성 규칙 |
| **Flutter 앱 README** | `happycart/README.md` | Flutter 프로젝트 자체 안내 |

---

## 14. 면책 (App 내 + 본 문서)

> 본 앱은 **'clean eating' 철학을 기준으로 한 참고 정보**입니다. 일부 성분(예: seed oils, carrageenan 등)에 대한 평가는 과학적으로 논쟁이 있을 수 있으며, 알레르기·질환·임신·영유아 식이는 제품 표시와 전문가 판단을 우선해주세요.

- 단정 표현 금지: "유해", "독성", "위험", "발암 확정" 등
- 권장 표현: "포함되어 있어요", "주의 신호", "확인해보세요", "괜찮아요"
- 결과 화면 모든 상태에 면책 카드 상시 노출 (`DisclaimerCard`)
