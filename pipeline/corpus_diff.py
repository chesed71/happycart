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

import argparse
import hashlib
import json
import subprocess

from common import connect
from judge import resolve_app_dir, run_rules

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
                   bad_ingredients_detected, good_ingredients_detected, verdict_reason_codes
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
            "prev_good": good or [],
            "prev_reason": reason or [],
        }
        for cid, tokens, verdict, bad, good, reason in rows
    ]


def fetch_masters(conn) -> list[dict]:
    """product_masters(서비스 노출) 를 조회 — rule_version 변경 시 재판정 대상.

    collected 와 달리 review-gating 이 없다(이미 승격된 서비스 상품). 빈 토큰만 제외.
    ruleVersion bump 로 masters 도 flip/검출배열 변화가 생길 수 있으므로 오탐0 게이트를
    collected 뿐 아니라 masters 에도 돌릴 수 있게 한다(스펙 §9 재판정 대상 = collected+masters).
    """
    with conn.cursor() as cur:
        cur.execute(
            """
            select id, ingredients_tokens, verdict::text,
                   bad_ingredients_detected, good_ingredients_detected, verdict_reason_codes
            from product_masters
            where array_length(ingredients_tokens, 1) >= 1
            """
        )
        rows = cur.fetchall()
    return [
        {
            "ref": str(mid),
            "tokens": tokens or [],
            "prev_verdict": verdict,
            "prev_bad": bad or [],
            "prev_good": good or [],
            "prev_reason": reason or [],
        }
        for mid, tokens, verdict, bad, good, reason in rows
    ]


def select_fetch(target: str):
    """--target 에 따라 모집단 조회 함수 선택 (masters=서비스 상품, collected=기본)."""
    return fetch_masters if target == "masters" else fetch_corpus


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


def judge_snapshot(snapshot_rows: list[dict], app_dir: str) -> dict:
    """스냅샷 토큰을 현재 checkout 룰로 판정 → {ref: 판정결과}.

    judge.run_rules 를 재사용해 compute_verdicts.dart --json 을 호출한다 (룰 단일 소스).
    반환 결과는 compute_verdicts 출력 형태({ref, verdict, bad_ingredients_detected,
    good_ingredients_detected, verdict_reason_codes, rule_version}).
    """
    items = [{"ref": r["ref"], "tokens": r["tokens"]} for r in snapshot_rows]
    return {res["ref"]: res for res in run_rules(items, app_dir)}


def diff_results(before: dict, after: dict) -> list[dict]:
    """ref 별로 verdict·bad·reason·good 배열 중 하나라도 달라진 항목만 반환.

    verdict 가 같아도 검출배열(bad/reason/good) 변화를 포착한다 (스펙 §8 — verdict-only
    diff 는 reason/canonicalKey 변화를 놓침). good_ingredients_detected 도 앱에 노출되므로
    (result_page 의 Good 섹션·product_lookup_result) 함께 diff 해 룰 출력 drift 를 빠짐없이
    잡는다. 배열은 정렬 비교라 순서 무관. new_bad_keys/new_good_keys 는 새로 검출된 키,
    removed_good_keys 는 사라진 good 키, newly_not_okay 는 판정이 not_okay 로 새로 뒤집혔는지.
    """
    diffs = []
    for ref in sorted(set(before) | set(after)):
        b = before.get(ref, {})
        a = after.get(ref, {})
        vb, va = b.get("verdict"), a.get("verdict")
        bb = sorted(b.get("bad_ingredients_detected") or [])
        ba = sorted(a.get("bad_ingredients_detected") or [])
        rb = sorted(b.get("verdict_reason_codes") or [])
        ra = sorted(a.get("verdict_reason_codes") or [])
        gb = sorted(b.get("good_ingredients_detected") or [])
        ga = sorted(a.get("good_ingredients_detected") or [])
        if vb == va and bb == ba and rb == ra and gb == ga:
            continue
        diffs.append({
            "ref": ref,
            "verdict_before": vb, "verdict_after": va,
            "bad_before": bb, "bad_after": ba,
            "reason_before": rb, "reason_after": ra,
            "good_before": gb, "good_after": ga,
            "new_bad_keys": sorted(set(ba) - set(bb)),
            "new_good_keys": sorted(set(ga) - set(gb)),
            "removed_good_keys": sorted(set(gb) - set(ga)),
            "newly_not_okay": vb != "not_okay" and va == "not_okay",
        })
    return diffs


def write_diff_report(diffs: list[dict], path: str) -> None:
    """diff 리포트 저장 — 요약(총 변화 수·신규 not_okay 수)과 항목 리스트."""
    report = {
        "changed_count": len(diffs),
        "newly_not_okay_count": sum(1 for d in diffs if d["newly_not_okay"]),
        "diffs": diffs,
    }
    with open(path, "w", encoding="utf-8") as f:
        json.dump(report, f, ensure_ascii=False, indent=2)


def _load_json(path: str):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def _judge_phase(app_dir: str, snapshot_path: str, result_out: str) -> dict:
    """스냅샷을 로드해 현재 룰로 판정하고 결과를 저장. before/after 공통."""
    snap = _load_json(snapshot_path)
    results = judge_snapshot(snap["rows"], app_dir)
    with open(result_out, "w", encoding="utf-8") as f:
        json.dump(results, f, ensure_ascii=False, indent=2)
    return results


def main():
    ap = argparse.ArgumentParser(description="corpus 전/후 판정 diff (오탐0 게이트)")
    ap.add_argument("--phase", choices=["before", "after", "diff"], required=True)
    ap.add_argument("--app-dir", default=None,
                    help="happycart 앱 디렉터리 (미지정 시 HAPPYCART_APP_DIR/기본값)")
    ap.add_argument("--catalog", default=None, help="before: 스냅샷 메타용 카탈로그 경로")
    ap.add_argument("--snapshot", default=None, help="토큰 스냅샷 JSON (before 작성, after 재사용)")
    ap.add_argument("--result-out", default=None, help="before/after: 판정 결과 저장 경로")
    ap.add_argument("--result-before", default=None, help="diff: before 판정 결과")
    ap.add_argument("--result-after", default=None, help="diff: after 판정 결과")
    ap.add_argument("--diff-out", default=None, help="diff: 리포트 저장 경로")
    ap.add_argument("--target", choices=["collected", "masters"], default="collected",
                    help="before: 스냅샷 모집단 — collected_products(기본) 또는 product_masters(서비스)")
    ap.add_argument("--dsn", default=None)
    args = ap.parse_args()

    app_dir = resolve_app_dir(args.app_dir)

    if args.phase == "before":
        # 토큰 스냅샷 1회 materialize (DB) + 반영 전 룰로 판정.
        with connect(args.dsn) as conn:
            rows = select_fetch(args.target)(conn)
        write_snapshot(rows, args.snapshot, args.catalog, app_dir)
        results = _judge_phase(app_dir, args.snapshot, args.result_out)
        print(f"before[{args.target}]: {len(rows)}행 materialize → {args.snapshot}, "
              f"판정 {len(results)} → {args.result_out}")
    elif args.phase == "after":
        # 반영 후 — 동일 스냅샷 토큰을 재판정.
        results = _judge_phase(app_dir, args.snapshot, args.result_out)
        print(f"after: 판정 {len(results)} → {args.result_out}")
    else:  # diff
        before = _load_json(args.result_before)
        after = _load_json(args.result_after)
        diffs = diff_results(before, after)
        write_diff_report(diffs, args.diff_out)
        nno = sum(1 for d in diffs if d["newly_not_okay"])
        print(f"diff: {len(diffs)}건 변화, {nno}건 신규 not_okay → {args.diff_out}")


if __name__ == "__main__":
    main()
