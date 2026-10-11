"""파이프라인 테스트 전용 DB 안전장치.

테스트는 happycart_test(원본 역할)·happycart_test_target(운영 대상 역할)에만 붙는다.
운영 LOCAL happycart에는 절대 연결하지 않는다 — 연결 전에 DSN의 DB 이름을 먼저 검사하고,
연결 뒤 current_database()로 한 번 더 검사한다.
"""
from __future__ import annotations

import os
from urllib.parse import urlparse

import psycopg

from common import dsn

SOURCE_DB = "happycart_test"
TARGET_DB = "happycart_test_target"
ALLOWED_DBS = (SOURCE_DB, TARGET_DB)


def source_dsn() -> str:
    """원본 테스트 DB DSN. HAPPYCART_DSN을 무시하도록 DB 이름을 명시한다."""
    return dsn(SOURCE_DB)


def target_dsn() -> str:
    return dsn(TARGET_DB)


def review_dsn() -> str:
    """검수 롤 datadesk_review가 원본 테스트 DB에 붙는 DSN."""
    host = os.environ.get("HAPPYCART_PG_HOST", "127.0.0.1")
    port = os.environ.get("HAPPYCART_PG_PORT", "54322")
    return f"postgresql://datadesk_review:datadesk_review@{host}:{port}/{SOURCE_DB}"


def _dsn_db(d: str) -> str:
    return urlparse(d).path.lstrip("/")


def connect_test(d: str, **kwargs) -> psycopg.Connection:
    """테스트 DB 두 개가 아니면 연결 전에 예외, 연결 뒤에도 current_database()를 재확인."""
    name = _dsn_db(d)
    if name not in ALLOWED_DBS:
        raise RuntimeError(f"테스트는 {ALLOWED_DBS}에만 연결할 수 있습니다: {name!r}")
    conn = psycopg.connect(d, **kwargs)
    try:
        actual = conn.execute("select current_database()").fetchone()[0]
        if actual not in ALLOWED_DBS:
            raise RuntimeError(f"연결된 DB가 테스트 DB가 아닙니다: {actual!r}")
        if not conn.autocommit:
            conn.rollback()
    except BaseException:
        conn.close()
        raise
    return conn
