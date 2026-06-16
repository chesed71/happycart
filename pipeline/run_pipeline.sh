#!/usr/bin/env bash
# Phase 2 파이프라인 전체 실행 (멱등). bootstrap_local.sh로 DB를 만든 뒤 호출한다.
#   extract → match_enrich → tokenize → judge → promote
#
# 최초 1회 셋업 (psycopg 설치):
#   python3 -m venv pipeline/.venv
#   pipeline/.venv/bin/pip install -r pipeline/requirements.txt
#
# 사용: pipeline/run_pipeline.sh
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
PY="$DIR/.venv/bin/python"

if [[ ! -x "$PY" ]]; then
  echo "error: $PY 없음. 셋업: python3 -m venv $DIR/.venv && $DIR/.venv/bin/pip install -r $DIR/requirements.txt" >&2
  exit 1
fi

"$PY" "$DIR/extract_coupang.py"
"$PY" "$DIR/extract_kakamuka.py"
"$PY" "$DIR/match_enrich.py"
"$PY" "$DIR/tokenize_ingredients.py"
"$PY" "$DIR/judge.py"
"$PY" "$DIR/promote.py"
