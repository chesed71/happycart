"""corpus 오탐0 게이트 — collected_products 토큰 스냅샷 materialize + 전/후 판정 diff.

토큰 스냅샷을 1회 materialize 하고, 카탈로그 반영 전/후 동일 토큰을 각각 그 시점의
checkout 룰로 판정해 verdict·검출배열 변화를 diff 한다 (스펙 §8). 판정은 judge.py 와
동일하게 compute_verdicts.dart --json 서브프로세스를 재사용한다.

사용(Task 3 에서 main 조립):
  # 반영 전: 스냅샷 materialize + 현재 룰 판정
  .venv/bin/python corpus_diff.py --phase before --app-dir <happycart> \
      --catalog <catalog.json> --snapshot snap.json --result-out before.json
  # (카탈로그 반영·재생성 후) 동일 스냅샷 재판정
  .venv/bin/python corpus_diff.py --phase after --app-dir <happycart> \
      --snapshot snap.json --result-out after.json
  # 전/후 diff 리포트
  .venv/bin/python corpus_diff.py --phase diff \
      --result-before before.json --result-after after.json --diff-out diff.json
"""
from __future__ import annotations

import hashlib
import json
import subprocess

# judge.py 와 동일 상수 — review-gated source 는 verified 행만 판정 대상.
REVIEW_GATED_SOURCES = {"lottemartzetta"}


def fetch_corpus(conn, review_gated=REVIEW_GATED_SOURCES) -> list[dict]:
    """판정 대상 collected_products 를 1회 조회 (judge_collected 모집단과 동일).

    stage in ('tokenized','judged'), review-gated source 는 review_decision='verified',
    빈 토큰(array_length < 1) 제외. 이전 판정값(prev_*)도 함께 담아 baseline 으로 보존.
    rule_version 은 게이트하지 않는다 — 반영 전 전체를 동일 스냅샷으로 판정해야 하므로.
    """
    with conn.cursor() as cur:
        cur.execute(
            """
            select id, ingredients_tokens, verdict::text,
                   bad_ingredients_detected, verdict_reason_codes
            from collected_products
            where stage in ('tokenized', 'judged')
              and (source <> all(%s) or review_decision = 'verified')
              and array_length(ingredients_tokens, 1) >= 1
            """,
            (list(review_gated),),
        )
        rows = cur.fetchall()
    return [
        {
            "ref": str(cid),
            "tokens": tokens or [],
            "prev_verdict": verdict,
            "prev_bad": bad or [],
            "prev_reason": reason or [],
        }
        for cid, tokens, verdict, bad, reason in rows
    ]


def catalog_sha256(catalog_path: str) -> str:
    """카탈로그 파일 raw bytes 의 SHA-256 (lowercase hex) — 매니페스트 대조용."""
    with open(catalog_path, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()


def git_head(repo_dir: str) -> str:
    """repo_dir 의 현재 HEAD sha. git 실패 시 'unknown'."""
    try:
        proc = subprocess.run(
            ["git", "-C", repo_dir, "rev-parse", "HEAD"],
            capture_output=True, text=True, check=True,
        )
        return proc.stdout.strip()
    except (subprocess.CalledProcessError, FileNotFoundError):
        return "unknown"


def write_snapshot(rows: list[dict], path: str, catalog_path: str, app_dir: str) -> None:
    """토큰 스냅샷을 메타(카탈로그 sha256·git ref·행수)와 함께 JSON 으로 저장.

    before 단계에서 1회 materialize 하고, after 단계가 같은 파일을 재사용해 동일 토큰을
    재판정한다 (스펙 §8 '토큰 스냅샷 1회 materialize·동일 입력').
    """
    snapshot = {
        "catalog_sha256": catalog_sha256(catalog_path),
        "git_ref": git_head(app_dir),
        "count": len(rows),
        "rows": rows,
    }
    with open(path, "w", encoding="utf-8") as f:
        json.dump(snapshot, f, ensure_ascii=False, indent=2)
