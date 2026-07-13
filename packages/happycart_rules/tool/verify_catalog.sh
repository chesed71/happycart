#!/usr/bin/env bash
# 카탈로그 생성 검증 게이트: freshness(재생성 diff 없음) + 멱등 + analyze + test.
#
# 사용: bash tool/verify_catalog.sh (패키지 루트 어디서 실행해도 무관 — 스크립트
# 위치 기준으로 패키지 루트로 이동한다.)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PACKAGE_ROOT"

echo "==> [1/4] data/ingredient_catalog.json → lib/src/*.g.dart 재생성"
dart run tool/generate_catalog.dart

echo "==> [2/4] freshness 확인 (재생성 결과가 커밋본과 동일해야 함 = freshness + 멱등)"
git diff --exit-code -- lib/src/bad_ingredients.g.dart lib/src/good_ingredients.g.dart

echo "==> [3/4] dart analyze"
dart analyze

echo "==> [4/4] dart test"
dart test

echo "verify_catalog: OK — 카탈로그 freshness·analyze·test 모두 통과."
