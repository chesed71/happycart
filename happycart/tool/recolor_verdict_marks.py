#!/usr/bin/env python3
"""기존 위험(빨강) 카트·손 마크를 낮음(노랑)·중간(주황) 톤으로 색조 변경한다.

- 카트(cart_stop.png): 균일한 빨강 단색 아이콘. 알파>0 픽셀 전체의 RGB 를
  목표색으로 치환하고 알파는 원본 유지한다(안티에일리어싱 가장자리 포함).
- 손(hand_stop.png): 회색 손+얼굴 + 빨강 금지원 구조. R 채널이 G·B 채널보다
  각각 25 이상 큰 빨강 계열 픽셀만 목표색으로 치환하고, 무채색인 회색
  손·얼굴은 그대로 둔다.

실행 의존성(numpy·Pillow)은 `happycart/tool/requirements.txt` 참고.
기본적으로 기존 산출물이 있으면 덮어쓰지 않고 중단한다(수작업 보정본 보호).
덮어쓰려면 `--force`. 산출물 네 개를 전부 생성·검증해 임시 파일로 준비한 뒤에만
교체를 시작하므로, 생성·검증 실패로는 기존 세트가 부분 갱신되지 않는다.
(os.replace 는 파일 단위로만 원자적이라 교체 단계 자체가 중단되면 세트가 부분
갱신될 수 있다 — 이때 남은 .tmp 는 지우지 않고 복구 자료로 남긴다.)
"""

from __future__ import annotations

import argparse
import os
from pathlib import Path

# numpy·Pillow 는 실제 리컬러 시에만 필요하다. 존재 검사(--force 가드)와
# --help 는 무거운 의존성 없이도 동작하도록 함수 안에서 지연 import 한다.

ASSETS_DIR = Path(__file__).resolve().parents[1] / "assets" / "verdict"

# (hex 목표색, 접미사) — low=노랑, medium=주황.
TARGET_COLORS = {
    "low": "#E1A50B",
    "med": "#EE7A1A",
}

RED_DOMINANCE_THRESHOLD = 25  # R - G, R - B 가 이 값 이상이면 "빨강"으로 간주.


def hex_to_rgb(hex_color: str) -> tuple[int, int, int]:
    hex_color = hex_color.lstrip("#")
    return tuple(int(hex_color[i : i + 2], 16) for i in (0, 2, 4))  # type: ignore[return-value]


def recolor_cart(source: Path, target_rgb: tuple[int, int, int]) -> "Image.Image":
    """알파>0 픽셀 전체를 목표색으로 치환한다."""
    import numpy as np
    from PIL import Image

    img = Image.open(source).convert("RGBA")
    arr = np.array(img)

    alpha = arr[:, :, 3]
    mask = alpha > 0

    arr[mask, 0] = target_rgb[0]
    arr[mask, 1] = target_rgb[1]
    arr[mask, 2] = target_rgb[2]
    # 알파 채널은 원본 유지.

    return Image.fromarray(arr, mode="RGBA")


def recolor_hand(source: Path, target_rgb: tuple[int, int, int]) -> "Image.Image":
    """R 이 G·B 보다 25 이상 큰 빨강 픽셀만 목표색으로 치환한다."""
    import numpy as np
    from PIL import Image

    img = Image.open(source).convert("RGBA")
    arr = np.array(img)

    r = arr[:, :, 0].astype(int)
    g = arr[:, :, 1].astype(int)
    b = arr[:, :, 2].astype(int)
    alpha = arr[:, :, 3]

    is_red = (
        (alpha > 0)
        & (r - g >= RED_DOMINANCE_THRESHOLD)
        & (r - b >= RED_DOMINANCE_THRESHOLD)
    )

    arr[is_red, 0] = target_rgb[0]
    arr[is_red, 1] = target_rgb[1]
    arr[is_red, 2] = target_rgb[2]
    # 회색 손·얼굴(무채색) 픽셀과 알파는 그대로 유지.

    return Image.fromarray(arr, mode="RGBA")


def _validate(
    result: "Image.Image",
    source_size: tuple[int, int],
    target_rgb: tuple[int, int, int],
) -> None:
    """산출물이 원본 크기·RGBA·목표색 반영을 만족하는지 검증한다."""
    import numpy as np

    if result.mode != "RGBA":
        raise ValueError(f"출력 모드가 RGBA 가 아님: {result.mode}")
    if result.size != source_size:
        raise ValueError(f"출력 크기가 원본과 다름: {result.size} != {source_size}")

    arr = np.array(result)
    opaque = arr[:, :, 3] > 0
    if not opaque.any():
        raise ValueError("불투명 픽셀이 없음 — 빈 이미지")

    has_target = (
        opaque
        & (arr[:, :, 0] == target_rgb[0])
        & (arr[:, :, 1] == target_rgb[1])
        & (arr[:, :, 2] == target_rgb[2])
    )
    if not has_target.any():
        raise ValueError(f"목표색 {target_rgb} 픽셀이 하나도 없음 — 색 치환 실패")


def main() -> None:
    parser = argparse.ArgumentParser(
        description="위험 마크(빨강)를 low/med 톤으로 리컬러한다.",
    )
    parser.add_argument(
        "--force",
        action="store_true",
        help="기존 산출물이 있어도 덮어쓴다(기본: 존재 시 중단).",
    )
    args = parser.parse_args()

    cart_source = ASSETS_DIR / "cart_stop.png"
    hand_source = ASSETS_DIR / "hand_stop.png"
    for src in (cart_source, hand_source):
        if not src.exists():
            raise SystemExit(f"원본 없음: {src}")

    # (산출물, 원본, 리컬러 함수, 목표 RGB, hex) 계획 목록.
    plans = []
    for suffix, hex_color in TARGET_COLORS.items():
        target_rgb = hex_to_rgb(hex_color)
        plans.append((ASSETS_DIR / f"cart_{suffix}.png", cart_source, recolor_cart, target_rgb, hex_color))
        plans.append((ASSETS_DIR / f"hand_{suffix}.png", hand_source, recolor_hand, target_rgb, hex_color))

    if not args.force:
        existing = [str(dest) for dest, *_ in plans if dest.exists()]
        if existing:
            raise SystemExit(
                "이미 존재하는 산출물이 있어 중단합니다(수작업 보정본 보호). "
                "덮어쓰려면 --force:\n  " + "\n  ".join(existing)
            )

    from PIL import Image

    # 1단계: 네 산출물을 전부 생성·검증해 임시 파일로 준비한다 — 하나라도
    # 실패하면 기존 파일을 건드리지 않고 임시 파일만 정리한다.
    staged: list[tuple[Path, Path, str]] = []
    try:
        for dest, source, recolor, target_rgb, hex_color in plans:
            source_size = Image.open(source).size
            result = recolor(source, target_rgb)
            _validate(result, source_size, target_rgb)
            tmp = dest.with_name(dest.name + ".tmp")
            # 저장이 반쯤 쓰다 실패(디스크 부족 등)해도 정리 대상이 되도록
            # 저장 전에 등록한다.
            staged.append((tmp, dest, hex_color))
            # Pillow 는 확장자로 포맷을 추론하는데 .tmp 는 미지 확장자라 명시.
            result.save(tmp, format="PNG")
    except BaseException:
        for tmp, _, _ in staged:
            if tmp.exists():
                tmp.unlink()
        raise

    # 2단계: 전부 준비된 뒤에 파일 단위로 교체한다. os.replace 는 파일 하나에만
    # 원자적이라 이 단계가 도중에 중단되면 세트가 부분 갱신될 수 있다 — 이때는
    # 남은 .tmp 를 지우지 않고 복구 자료로 남긴다(재실행하면 전체 재생성됨).
    for tmp, dest, hex_color in staged:
        os.replace(tmp, dest)
        print(f"생성: {dest} ({hex_color})")


if __name__ == "__main__":
    main()
