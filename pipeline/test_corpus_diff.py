"""corpus_diff·judge 순수/DB 함수 테스트 — self-run 러너 (test_invariants.py 패턴).

DB 불필요한 순수 함수는 항상 실행하고, DB 필요한 함수는 접속 실패 시 SKIP 한다
(DB 없는 CI 통과). 각 DB 테스트는 트랜잭션 안에서 픽스처를 만들고 rollback 한다.

사용: pipeline/.venv/bin/python test_corpus_diff.py
"""
from __future__ import annotations

import os
import sys

# judge.resolve_app_dir 의 기본값과 동일해야 한다 (현재 머신 실경로).
DEFAULT_APP_DIR = "/Users/ronen/Project/HappyCart/happycart"

# (name, ok) — ok=True PASS / ok=False FAIL / ok=None SKIP
results: list[tuple[str, bool | None, str]] = []


def check(name: str, cond: bool, detail: str = "") -> None:
    results.append((name, bool(cond), detail))


def skip(name: str, reason: str) -> None:
    results.append((name, None, reason))


def test_resolve_app_dir_precedence():
    """resolve_app_dir: CLI 인자 > 환경변수 HAPPYCART_APP_DIR > 기본값."""
    import judge

    saved = os.environ.get("HAPPYCART_APP_DIR")
    try:
        # (a) CLI 값이 주어지면 env 가 있어도 CLI 우선
        os.environ["HAPPYCART_APP_DIR"] = "/env/path"
        check("resolve_app_dir: CLI 우선",
              judge.resolve_app_dir("/cli/path") == "/cli/path")
        # (b) CLI 없으면 env 사용
        check("resolve_app_dir: env 사용",
              judge.resolve_app_dir(None) == "/env/path")
        # (c) 둘 다 없으면 기본값
        os.environ.pop("HAPPYCART_APP_DIR", None)
        check("resolve_app_dir: 기본값",
              judge.resolve_app_dir(None) == DEFAULT_APP_DIR)
    finally:
        if saved is None:
            os.environ.pop("HAPPYCART_APP_DIR", None)
        else:
            os.environ["HAPPYCART_APP_DIR"] = saved


def main():
    tests = [
        test_resolve_app_dir_precedence,
    ]
    for t in tests:
        try:
            t()
        except Exception as e:  # noqa
            check(t.__name__, False, f"테스트 예외: {e}")

    failed = skipped = 0
    for name, ok, detail in results:
        if ok is None:
            mark, skipped = "SKIP", skipped + 1
        elif ok:
            mark = "PASS"
        else:
            mark, failed = "FAIL", failed + 1
        show = detail and (ok is None or not ok)
        print(f"  {mark}  {name}" + (f"  [{detail}]" if show else ""))
    passed = len(results) - failed - skipped
    print(f"\n{passed} pass, {failed} fail, {skipped} skip")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
