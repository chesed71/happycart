# HappyCart 데이터 수집 시스템 설계

> **목적**: HappyCart 앱(또는 별도 큐레이션 앱)에서 제품 사진 + 메모만 던지면, **자동화 에이전트가 시드 등록·룰 매칭·DB 적재·문서 갱신까지 처리**하는 시스템을 설계한다.

- 작성일: 2026-05-22
- 관련 스펙: `docs/superpowers/specs/2026-05-20-happycart-clean-eating-design.md` §10.3 (시드/데이터 적재)
- 관련 백로그: `docs/superpowers/backlogs/2026-05-21-rule-gaps.md`
- 채택 아키텍처: **Supabase Queue 패턴 + nanoclaw 자동화 에이전트**

---

## 0. 한 줄 요약

폰의 HappyCart 앱에서 라벨 사진을 찍고 "전송" 버튼을 누르면, **Supabase 의 `product_submissions` 테이블에 INSERT** 되고, **nanoclaw 의 Claude Agent 가 정기 polling 으로 발견·자동 처리**한다. 처리 결과는 Supabase Realtime 으로 앱에 즉시 반영. 사람은 사진 찍는 일만 한다.

---

## 1. 배경 & 문제 정의

### 현재 워크플로 (2026-05-21 기준)
```
[사용자] 폰 사진 촬영
   ↓
[Claude 채팅] 사진 업로드 → 시각 OCR (정확도 들쭉날쭉)
   ↓
[Claude] seed_products.json 편집
   ↓
[로컬] dart run compute_verdicts → 0005_seed_products.sql
   ↓
[로컬] supabase db push
   ↓
[Supabase] products 테이블 INSERT
   ↓
[Claude] rule-gaps.md 분류 + README 갱신
```

### 문제점
| # | 문제 | 영향 |
|---|---|---|
| 1 | 단계가 8단계로 너무 많음 | 시드 1건당 5~10분 |
| 2 | 사람이 채팅·로컬 사이를 왕복 | 컨텍스트 스위칭 비용 |
| 3 | 토큰 비용 누적 (Claude 채팅) | 시드 100건 = 채팅 토큰 폭증 |
| 4 | 누적·재현·검색 불가능 | 작업 이력이 채팅에만 |
| 5 | 회색지대 판단·문서 갱신이 번거로움 | rule-gaps.md 매번 수동 |

### 목표
- **사용자 작업 시간 < 30초/건** (사진 + 메모 + 전송만)
- **자동화 처리 < 10분/건** (cron 주기 + LLM 응답)
- **모든 입력·결과 DB 기록** (감사·재처리 가능)
- **rule-gaps.md / git 까지 자동 갱신**
- **시드 1000건/월 운영 시 < $30/월**

---

## 2. 솔루션 개요

### 채택 아키텍처: Supabase Queue + nanoclaw

```
┌─────────────────────────────────────┐
│ [HappyCart 앱 - Admin/제보 모드]      │
│  사진 + 메모 입력                    │
└──────────────┬──────────────────────┘
               │
               │ ① Supabase Storage 업로드 (사진)
               │ ② product_submissions INSERT (status='pending')
               ▼
┌─────────────────────────────────────┐
│ [Supabase happycart-dev]             │
│   - storage.objects (사진)           │
│   - public.product_submissions (큐)  │
│   - public.products (최종 적재)      │
└──────────────┬──────────────────────┘
               │
               │ ③ nanoclaw scheduled task (매 5~10분)
               ▼
┌─────────────────────────────────────┐
│ [nanoclaw Docker container]          │
│  agent group: happycart-curator      │
│   - Claude Agent SDK (vision OCR)    │
│   - Codex CLI (선택, 룰 코드 변경)    │
│   - 마운트: HappyCart repo,          │
│            ~/.config/happycart       │
└──────────────┬──────────────────────┘
               │ ④ vision OCR → 구조화
               │ ⑤ happycart_rules 호출
               │ ⑥ products INSERT
               │ ⑦ rule-gaps.md 분류 추가
               │ ⑧ git commit + push
               │ ⑨ submissions.status='processed'
               ▼
┌─────────────────────────────────────┐
│ [Supabase Realtime]                  │
│  product_submissions 변경 이벤트 발사 │
└──────────────┬──────────────────────┘
               │
               │ ⑩ 앱이 status 변경 감지
               ▼
┌─────────────────────────────────────┐
│ [HappyCart 앱]                       │
│  결과 화면 표시 + 푸시 알림           │
│  ("✅ 등록 완료: 코카콜라 제로")      │
└─────────────────────────────────────┘
```

### 왜 이 조합인가
- **Supabase Queue**: 앱이 백엔드 protocol 신경 안 쓰고 INSERT 한 번으로 끝
- **nanoclaw**: Claude Agent SDK + Docker container isolation + scheduled tasks 다 내장 (재구현 안 함)
- **Supabase Realtime**: 결과 알림에 별도 push 인프라 불필요
- **자체 앱**: 사용자 경험을 100% 통제. Telegram 의존성 없음

---

## 3. 컴포넌트 상세

### 3.1 HappyCart 앱 — Admin/제보 모드

기존 HappyCart Flutter 앱에 Admin flavor 또는 권한 기반 화면 추가.

**진입점 옵션**:
- (A) Admin flavor 빌드 (`com.rimonhouse.happycart.admin`) — 본인 디바이스만
- (B) 일반 빌드의 "..." 메뉴 (debug build 만 노출)
- (C) 일반 빌드 + Supabase Auth 로 admin 권한 확인

**UI 흐름**:
```
[ScanScreen 또는 메뉴]
       ↓ "제품 등록" 탭
[등록 화면]
  - 라벨 사진 1~5장 촬영/선택
  - 메모 1줄 (선택): "이거 제로콜라"
  - 바코드 (자동 채움 — 별도 스캔 결과 있으면)
  - "전송" 버튼
       ↓ ① Storage 업로드 (병렬)
       ↓ ② submissions INSERT
[대기 화면]
  - "처리 중... (보통 1~5분 소요)"
  - Realtime 구독 시작
  - 백그라운드 처리 가능 (앱 종료해도 OK)
       ↓ status='processed' 도착
[결과 화면]
  - ✅ 등록 완료: 코카콜라 제로
  - verdict: not_okay
  - bad: [인공감미료, 카페인]
  - "확인" 누르면 다음 등록으로
```

### 3.2 Supabase Queue — `product_submissions` 테이블

```
public.product_submissions (
  id                 uuid pk default gen_random_uuid(),
  status             text not null default 'pending'
                     check (status in ('pending','processing','processed','failed')),

  -- 입력 (앱)
  submitted_by       uuid references auth.users(id),  -- Auth 도입 시
  submitter_alias    text,                             -- 익명 단계용
  photo_urls         text[] not null,                  -- storage.objects 경로
  hint               text,                             -- "이거 제로콜라야" 같은 한 줄
  scanned_barcode    text,                             -- 별도 바코드 스캔 결과 (있으면)
  submitted_at       timestamptz not null default now(),

  -- 처리 (nanoclaw)
  picked_at          timestamptz,                      -- agent 가 가져간 시각
  processed_at       timestamptz,
  product_id         uuid references public.products(id),
  ocr_raw_text       text,                             -- 디버그/재처리용
  error_message      text,                             -- 실패 시 원인
  retry_count        integer not null default 0,

  -- 메타
  rule_version       text,                             -- 처리 시점 룰 버전
  agent_log          jsonb,                            -- agent 가 작성한 처리 로그
  created_at         timestamptz not null default now()
);

create index idx_submissions_status on public.product_submissions (status);
create index idx_submissions_submitted_at on public.product_submissions (submitted_at);
```

**상태 전이**:
```
pending → processing → processed
                    ↘ failed (retry_count++ 후 다시 pending or 영구 failed)
```

**RLS**:
- 익명/authenticated 인증된 사용자: 본인 행만 SELECT + INSERT
- service_role (nanoclaw): 전체 RW

### 3.3 nanoclaw + Claude Agent SDK

**셋업 (1회)**:
```bash
git clone https://github.com/nanocoai/nanoclaw.git
cd nanoclaw
bash nanoclaw.sh
# Telegram 채널 안 쓸 거니 /add-telegram 건너뜀
# 직접 cron skill 만 사용
```

**Agent group**: `happycart-curator`
**마운트**:
- `/Users/ronen/Project/HappyCart` (HappyCart repo, read-write)
- `/Users/ronen/.config/happycart` (Supabase token, DB password 등, read-only)
- `/Users/ronen/.config/happycart/android-keystore` 는 마운트 X (서명은 안 함)

**`agents/happycart-curator/CLAUDE.md`** (요지):
```
# HappyCart Curator Agent

당신은 HappyCart 시드 큐레이터입니다.

## 환경
- HappyCart repo: /workspace/happycart
- Supabase token: /secrets/supabase-token
- 룰 버전: happycart_rules v1.0.0

## 정기 작업 (10분마다)

1. Supabase product_submissions 에서 status='pending' 행 fetch
2. 각 행에 대해:
   a. status='processing', picked_at=now() 로 UPDATE
   b. photo_urls 의 사진들을 vision OCR
   c. structured output:
      { barcode, brand, name, size, category,
        ingredients_raw, ingredients_tokens }
   d. dart run happycart/tool/check_verdict.dart 로 룰 호출
   e. products 테이블 INSERT
   f. 회색지대 판단 시 rule-gaps.md 에 Case N 추가
   g. git commit + push
   h. status='processed', processed_at=now(), product_id=$id UPDATE
3. 실패 시:
   - error_message 기록
   - retry_count += 1
   - retry_count <= 3 이면 status='pending' 복귀
   - retry_count > 3 이면 영구 'failed'

## 룰 매칭 규칙
- happycart_rules 의 결과를 그대로 신뢰
- 매칭 0건이지만 사용자가 "가공식품" 같은 hint 줬으면
  → rule-gaps.md 에 회색지대 case 로 기록 (verdict 는 그대로 okay 유지)

## 금지 사항
- ingredients_tokens 비어있으면 절대 룰 추측하지 말 것 → insufficient
- products 의 verified_status 는 'verified' 또는 'needs_review' 만 사용
- rule_version 은 임의로 올리지 말 것 (룰 v1.1.0 도입은 별도 PR)

## git 컨벤션
- branch: main 직접 push (현재 단계)
- message: "seed: {brand} {name} ({verdict})"
- AI co-author 추가 금지
```

**Scheduled Task** (nanoclaw 의 cron skill 활용):
```
@HappyCart 매 10분마다:
  product_submissions 에서 pending 처리 절차 실행
```

### 3.4 `happycart_rules` 호출 방식

nanoclaw container 안에서 dart 실행:
```
# /workspace/happycart 안에서
$ dart run tool/check_verdict.dart \
    --tokens="정제수,고과당옥수수시럽,아스파탐"
# 출력: JSON {verdict, bad, good, reason_codes}
```

별도 HTTP 서버 안 만들고, dart CLI 직접 호출. nanoclaw container 에 dart SDK 설치.

(향후 트래픽 늘면 별도 Cloud Run dart 서버로 분리 가능 — 현재 단계 불필요)

### 3.5 결과 알림 — Supabase Realtime + FCM

**1차: Supabase Realtime**
- 앱이 자기 행만 구독: `from('product_submissions').on('UPDATE', ...).filter('submitter_alias', 'eq', myAlias)`
- status 변경 감지 즉시 결과 화면 표시
- 앱이 켜져있을 때 작동

**2차: FCM 푸시 (앱 종료 상태 대비)**
- nanoclaw 가 processed 처리 후 추가로 FCM Admin SDK 호출
- "코카콜라 제로 등록 완료" 푸시
- 탭하면 결과 화면 deep link

**3차: 본인용 알림 (선택)**
- 실패 케이스만 Telegram/Slack/메일로 본인에게 알림
- 정상 처리는 silent

---

## 4. 데이터 모델 변경 요약

### 신규 테이블
- `public.product_submissions` (§3.2)

### Storage bucket
- `submission_photos` — 라벨 사진 저장
  - RLS: 본인 행만 read
  - 보존 기간: 30일 (cron cleanup)

### 신규 RPC (앱에서 호출)
- `submit_for_review(p_photo_urls text[], p_hint text, p_scanned_barcode text)` returns uuid
  - SECURITY DEFINER, search_path=''
  - 입력 검증 + product_submissions INSERT
  - 호출자(anon or authenticated)에 따라 submitter_alias 설정

### 기존 테이블 변경 없음
- `public.products` — 그대로 유지 (lookup_product 도 동일)
- `public.scan_events` — 그대로 유지

---

## 5. 권한 모델

### Phase 1 (MVP): 익명 + secret key 임베드
- HappyCart 앱 admin flavor 빌드에 service_role token 임베드
  - 일반 사용자 빌드(development/staging/production) 에는 미포함
- nanoclaw 도 service_role 사용 (마운트된 token 파일)
- 장점: Auth 코드 작성 안 함, 즉시 작동
- 단점: admin flavor APK 디컴파일 시 키 노출 위험 → admin 빌드는 본인 디바이스만 install

### Phase 2 (멀티 사용자): Supabase Auth
- 이메일/Google OAuth 로그인
- `public.admins` 테이블에 본인 uid 등록
- `submit_for_review` RPC 가 admin 여부 검사
- 일반 사용자 제보는 verified_status='unverified' 로 들어감 (lookup_product 응답에 미포함)
- Admin 검수 화면에서 승인/반려

### Phase 3 (운영): 자동 승인 정책
- Bad ingredient 매칭 N건 이상 + 사진 ≥ 3장 → 자동 verified
- 그 외 → admin 검수 대기

---

## 6. 사용자 흐름 (구체 시나리오)

### 시나리오 A: 정상 처리 (Happy Path)

```
[T+00:00] 사용자가 폰에서 코카콜라 제로 박스 사진 4장 촬영
[T+00:30] 메모 "제로콜라" 입력 후 "전송" 탭
[T+00:31] Supabase Storage 사진 업로드 (병렬, 약 5초)
[T+00:36] product_submissions INSERT (status='pending')
[T+00:36] 앱: "처리 중... (보통 1~5분)" 표시 + Realtime 구독
[T+00:40] (선택) 사용자가 앱 종료 / 다른 작업

[T+10:00] nanoclaw cron 발동
[T+10:00] agent: pending 1건 fetch → status='processing' UPDATE
[T+10:01] vision OCR (4장 병렬, 약 30~60초)
[T+10:45] structured output:
   {barcode:"8801056111111", brand:"코카콜라",
    name:"제로", size:"355ml", category:"탄산음료",
    ingredients_raw:"...", ingredients_tokens:["정제수","아스파탐",...]}
[T+10:45] dart run check_verdict → {verdict:"not_okay", bad:["aspartame","acesulfame_k","caffeine"],...}
[T+10:46] products INSERT (verdict='not_okay', rule_version='v1.0.0')
[T+10:46] rule-gaps.md 검사: 매칭 명확 → Case 추가 안 함
[T+10:47] git add . && git commit -m "seed: 코카콜라 제로 (not_okay)" && git push
[T+10:47] submissions: status='processed', product_id=$id UPDATE
[T+10:47] FCM 푸시 전송

[T+10:47] 사용자 폰: 푸시 알림 "코카콜라 제로 — Not Okay (인공감미료)"
[T+10:48] 앱 진입 시 결과 화면 표시
```

### 시나리오 B: 실패 + 재시도

```
[T+00:00] 사용자 사진 전송
[T+10:00] agent 시작 → vision OCR
[T+10:30] OCR 결과에 바코드 없음 (사진이 흐림)
[T+10:30] agent: error_message="barcode not detected", retry_count=1, status='pending'
[T+20:00] cron 재실행 → 같은 행 재처리 → 또 실패 → retry_count=2
[T+30:00] 또 실패 → retry_count=3
[T+40:00] retry_count > 3 → status='failed' 영구 표시

[알림] 사용자 본인에게 메일/Telegram: "처리 실패 — 사진 재촬영 필요"
[앱] 실패 목록에서 사진 다시 보고 메모 추가 후 재전송 가능
```

### 시나리오 C: 회색지대 발견

```
[T+10:45] agent 가 처리 중인 제품: 청정원 곡물100 올리고당
[T+10:46] 룰 매칭 결과: 0건 → verdict='okay'
[T+10:47] agent 판단: "옥수수전분 99.5% 베이스인데 매칭 0건이라
                       false negative 가능. 회색지대로 분류 필요"
[T+10:48] rule-gaps.md 에 Case N 추가 (정해진 템플릿 사용):
   - 바코드, 매칭 결과
   - 회색지대 사유
   - clean-eating 진영별 분기
   - 보완 옵션 (A/B/C)
[T+10:49] git commit "docs: rule gap Case N - 청정원 곡물100"
[T+10:50] submissions: status='processed', agent_log 에 "rule_gap_case=N" 기록
```

---

## 7. 실패 처리 / 재시도 정책

| 실패 유형 | 처리 |
|---|---|
| vision OCR 결과 없음 | retry_count++, status=pending (10분 후 재시도) |
| 바코드 미검출 | 동일 |
| 동일 바코드 이미 products 에 존재 | status='processed', product_id 만 채움 (중복 무시) |
| dart 룰 호출 실패 | retry_count++, 5회 후 영구 failed + 알림 |
| Supabase INSERT 실패 (제약 위반) | error_message 상세 기록 + 영구 failed |
| git push 충돌 | git pull --rebase 자동 → 재push, 3회 실패 시 알림 |
| LLM API rate limit | exponential backoff 30s → 1m → 5m → 영구 failed |
| nanoclaw container OOM | nanoclaw 자체 재시작 (Docker restart=on-failure) |

### Dead Letter Queue 정책
- retry_count > 5 → `status='failed'` + 본인 알림
- failed 행은 별도 admin 화면에서 사진 재확인 후 수동 처리 또는 삭제

---

## 8. 단계적 전개

### Phase 1: 기반 인프라 (1주)
- [ ] product_submissions 테이블 + RLS + Storage bucket 마이그레이션
- [ ] submit_for_review RPC 작성
- [ ] HappyCart 앱에 Admin flavor 추가
- [ ] Admin 화면: 사진 촬영 + 메모 + 전송
- [ ] Supabase Realtime 구독 + 대기/결과 화면
- [ ] secret key 임베드 + 본인 디바이스 install 검증

이 단계에서는 nanoclaw 없이 **수동 처리**:
- 사용자가 사진 던지면 → 본인이 채팅에서 처리 (지금처럼)
- 단, 사진과 메모가 Supabase 에 저장돼 있어서 추후 자동화 시 그대로 활용 가능

### Phase 2: nanoclaw 도입 (1주)
- [ ] nanoclaw 셋업 (Docker, OneCLI, Agent SDK)
- [ ] happycart-curator agent group 생성
- [ ] 마운트 + CLAUDE.md 작성
- [ ] tool/check_verdict.dart 작성 (dart CLI 룰 호출)
- [ ] scheduled task 10분 cron 설정
- [ ] 첫 자동 처리 시드 1건 검증 (Phase 1 에서 쌓인 데이터로)
- [ ] FCM Admin SDK 통합

### Phase 3: 운영 안정화 (1~2주)
- [ ] Codex CLI 추가 (`/add-codex`) — 룰 v1.1.0 자동 PR
- [ ] 회색지대 자동 분류 prompt 튜닝
- [ ] 실패 케이스 패턴 학습 → prompt 보완
- [ ] Phase 2 자동 처리율 95% 이상 도달 시 다음 단계
- [ ] 본인 외 1~2명 admin 추가 (Supabase Auth 도입)
- [ ] 일반 사용자 제보 기능 (verified_status='unverified')

### Phase 4: 확장 (출시 후)
- [ ] 일반 사용자 제보 검수 워크플로
- [ ] 자동 승인 정책 도입 (Phase 3 권한 모델)
- [ ] 룰 v2.0.0 도입 (영양 임계 결합 등)
- [ ] 시드 1000+ 건 큐레이션 운영

---

## 9. 비용 산정

### Phase 1 (수동 처리 시점)
| 항목 | 월 비용 |
|---|---|
| Supabase | $0 (Free tier) |
| Firebase (FCM) | $0 (Spark plan) |
| 인프라 | $0 |
| **합계** | **$0** |

### Phase 2~3 (자동화 시점, 시드 100건/월 가정)
| 항목 | 단가 | 월 비용 |
|---|---|---|
| Anthropic API (vision, Sonnet) | ~$0.02/사진 × 4장 | $8 |
| Anthropic API (rule-gaps 분류, 텍스트) | ~$0.005/케이스 | $1 |
| OpenAI API (Codex, 룰 PR 생성, 선택) | ~$0.10/PR × 4회 | $0.4 |
| Supabase | Free tier | $0 |
| Firebase | Spark plan | $0 |
| nanoclaw 호스트 | 본인 Mac (상시 실행) | $0 |
| **합계** | | **약 $10/월** |

### Phase 4 (시드 1000건/월)
- 약 $80~100/월 (LLM API 비용 비례 증가)
- nanoclaw 호스트를 Cloud (Fly.io / Hetzner) 로 이전 시 +$10/월

---

## 10. 위험 / 완화책

| 위험 | 완화책 |
|---|---|
| **잘못된 데이터 자동 적재** | (1) Phase 1 수동 검증으로 prompt 튜닝, (2) verified_status='needs_review' 로 일단 들어가고 lookup_product 응답에 미포함 |
| **LLM 추론 비결정성** | dart 룰 호출은 항상 결정적. LLM 은 OCR/구조화에만 사용 |
| **사진 OCR 실패율** | 사용자가 다시 찍어 재전송, 또는 사진과 함께 텍스트 메모 |
| **service_role 키 admin APK 노출** | admin 빌드는 본인 디바이스만 install, Phase 2 에서 Auth 전환 |
| **nanoclaw 의존성 (deprecate 가능)** | 동일 패턴(Claude Agent SDK + cron) 으로 자체 구현 fallback 가능 |
| **Supabase Free tier 한도 초과** | DB row · Storage GB 모니터링, 필요 시 Pro 플랜 ($25/월) |
| **agent 가 잘못된 git commit** | (1) git history 항상 검토 가능, (2) CLAUDE.md 에 "AI co-author 금지" 명시, (3) PR 기반 워크플로 도입 (main 직접 push 안 함) |
| **사진의 개인정보 노출** | 사진은 라벨만 촬영하도록 가이드, 30일 후 자동 삭제 |
| **회색지대 오분류** | rule-gaps.md 의 분류 결과는 인덱스만 자동, 케이스 본문은 admin 검수 가능 |

---

## 11. 결정 보류 항목

| 항목 | 옵션 | 잠정 |
|---|---|---|
| Admin 진입점 | A (별도 flavor) / B (메뉴) / C (Auth) | A 권장 (Phase 1) |
| 권한 모델 | secret 임베드 / Supabase Auth / Firebase Auth | secret 임베드 (Phase 1) → Auth (Phase 2) |
| nanoclaw 호스트 | 본인 Mac 상시 / Cloud VM / Raspberry Pi | 본인 Mac (Phase 1~2) |
| LLM 공급자 | Anthropic / OpenAI / Gemini | Anthropic (Claude) |
| 보조 LLM | Codex 사용 / 안 함 | Codex (Phase 3 부터, 룰 PR 자동화용) |
| 사진 저장 위치 | Supabase Storage / Cloudflare R2 / S3 | Supabase Storage (단일 인프라) |
| FCM 푸시 도입 시점 | Phase 1 / Phase 2 | Phase 2 |
| 사진 보존 기간 | 30일 / 90일 / 영구 | 30일 (storage 비용 절감) |
| 다중 사용자 제보 | Phase 3 / Phase 4 | Phase 3 |
| 큐레이션 전용 별도 앱 | 같은 앱에 admin flavor / 별도 앱 | admin flavor (인프라 재활용) |

---

## 12. 다음 작업 (이 문서 밖)

### 즉시 가능
1. **Phase 1 실행 계획서 작성** — `plans/2026-05-XX-data-collection-phase-1.md`
2. **product_submissions 테이블 마이그레이션 SQL 작성** (`supabase/migrations/0006_*.sql`)
3. **submit_for_review RPC 작성**
4. **Admin flavor 추가** (`android/app/build.gradle.kts` productFlavors)
5. **Admin 화면 UI 구현** (사진 촬영 + 폼)
6. **Supabase Realtime 구독 + 대기/결과 화면**

### Phase 1 검증 후
7. **Phase 2 실행 계획서 작성**
8. **nanoclaw fork + 셋업**
9. **`tool/check_verdict.dart` CLI 작성** (dart 룰 호출 인터페이스)
10. **happycart-curator agent group CLAUDE.md 작성**

---

## 13. 참고: 옵션 비교 (왜 #3 채택했는가)

| 옵션 | 응답 시간 | nanoclaw 수정 | 추가 인프라 | 개발 | 자연스러움 |
|---|---|---|---|---|---|
| #1 Custom channel adapter | 즉시 | 있음 (TypeScript) | 없음 | 2~3일 | ⭐⭐⭐⭐ |
| #2 Telegram bot 백엔드 | 즉시 | 없음 | Telegram Bot | 1일 | ⭐⭐⭐ |
| **#3 Supabase queue** ⭐ | 2~5분 | 없음 | 없음 | 1.5~2일 | ⭐⭐⭐⭐⭐ |
| #4 nanoclaw HTTP fork | 즉시 | 있음 (큼) | HTTPS host | 3~5일 | ⭐⭐⭐⭐ |

**#3 채택 이유**:
- 앱이 Supabase 한 곳만 알면 됨 (낮은 결합)
- 모든 인프라가 이미 Supabase 중심 (Auth, Storage, Realtime, DB)
- nanoclaw 도 모름 → 다른 처리자로 교체 가능 (수동 검수, GitHub Actions 등)
- 2~5분 응답 지연은 시드 워크플로에 전혀 문제 없음
- nanoclaw 의 scheduled task 가 이미 내장

---

## 14. 면책 / 정책 정합성

- **개인정보 처리방침**: Admin 모드 Phase 1 은 본인만. Phase 3 다중 사용자 도입 시 약관 업데이트.
- **사진 저장**: 라벨만 촬영. 30일 자동 삭제. 사용자 동의 명시.
- **검수 정책**: Phase 3 일반 사용자 제보는 verified='unverified' → admin 승인 전까지 lookup_product 응답 미포함.
- **데이터 무결성**: rule_version, agent_log 모두 기록해 룰 변경 시 재계산·감사 가능.
- **AI 사용 명시**: 처리 자동화에 LLM 이 사용된다는 점을 약관에 명시 (Phase 3 부터).
