#!/usr/bin/env bash
set -euo pipefail

HOST="${1:-mac-mini}"
REMOTE_ROOT="${2:-/Users/innovator/Project/HappyCart}"
LOCAL_ROOT="$(cd "$(dirname "$0")" && pwd)"

# 원격 디렉터리 준비
ssh "$HOST" "mkdir -p '$REMOTE_ROOT/happycart' '$REMOTE_ROOT/docs/Quote'"

# .env 파일
rsync -av --progress \
  "$LOCAL_ROOT/happycart/.env.development" \
  "$LOCAL_ROOT/happycart/.env.staging" \
  "$LOCAL_ROOT/happycart/.env.production" \
  "$LOCAL_ROOT/happycart/.env.test" \
  "$HOST":"$REMOTE_ROOT/happycart/"

# 견적서
rsync -av --progress \
  "$LOCAL_ROOT/docs/Quote/" \
  "$HOST":"$REMOTE_ROOT/docs/Quote/"
