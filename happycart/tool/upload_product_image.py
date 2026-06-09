#!/usr/bin/env python3
"""Resize one product image and upload it to HappyCart Supabase Storage."""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
from pathlib import Path


def parse_env(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    if not path.exists():
        return values
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key.strip()] = value.strip().strip('"').strip("'")
    return values


def run(cmd: list[str], cwd: Path, *, check: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        cmd,
        cwd=cwd,
        check=check,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )


def resize_with_sips(source: Path, target: Path, max_size: int) -> None:
    target.parent.mkdir(parents=True, exist_ok=True)
    run(
        [
            "sips",
            "-s",
            "format",
            "jpeg",
            "-s",
            "formatOptions",
            "85",
            "-Z",
            str(max_size),
            str(source),
            "--out",
            str(target),
        ],
        cwd=Path.cwd(),
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--barcode", required=True)
    parser.add_argument("--image", required=True, help="Local source image path")
    parser.add_argument("--bucket", default="product-images")
    parser.add_argument("--prefix", default="products")
    parser.add_argument("--max-size", type=int, default=600)
    parser.add_argument("--env", default=".env.development")
    args = parser.parse_args()

    app_root = Path(__file__).resolve().parents[1]
    repo_root = app_root.parent
    source = Path(args.image).expanduser().resolve()
    if not source.exists():
        print(f"error: image not found: {source}", file=sys.stderr)
        return 2

    env = parse_env(app_root / args.env)
    supabase_url = env.get("SUPABASE_URL")
    if not supabase_url:
        print(f"error: SUPABASE_URL missing in {app_root / args.env}", file=sys.stderr)
        return 2

    object_name = f"{args.prefix.strip('/')}/{args.barcode}.jpg"
    resized = app_root / ".dart_tool" / "product-images" / f"{args.barcode}.jpg"
    resize_with_sips(source, resized, args.max_size)

    remote = f"ss:///{args.bucket}/{object_name}"
    run(["supabase", "--experimental", "storage", "rm", remote], cwd=repo_root, check=False)
    result = run(
        [
            "supabase",
            "--experimental",
            "storage",
            "cp",
            str(resized),
            remote,
            "--content-type",
            "image/jpeg",
            "--cache-control",
            "public, max-age=31536000, immutable",
        ],
        cwd=repo_root,
    )
    if result.stdout.strip():
        print(result.stdout.strip(), file=sys.stderr)

    public_url = f"{supabase_url.rstrip('/')}/storage/v1/object/public/{args.bucket}/{object_name}"
    print(public_url)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
