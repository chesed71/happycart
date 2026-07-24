#!/usr/bin/env python3
"""기존 위험(빨강) 카트·손 마크를 낮음(노랑)·중간(주황) 톤으로 색조 변경한다.

- 카트(cart_stop.png): 균일한 빨강 단색 아이콘. 알파>0 픽셀 전체의 RGB 를
  목표색으로 치환하고 알파는 원본 유지한다(안티에일리어싱 가장자리 포함).
- 손(hand_stop.png): 회색 손+얼굴 + 빨강 금지원 구조. R 채널이 G·B 채널보다
  각각 25 이상 큰 빨강 계열 픽셀만 목표색으로 치환하고, 무채색인 회색
  손·얼굴은 그대로 둔다.
"""

from __future__ import annotations

from pathlib import Path

import numpy as np
from PIL import Image

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


def recolor_cart(source: Path, target_rgb: tuple[int, int, int], dest: Path) -> None:
    """알파>0 픽셀 전체를 목표색으로 치환한다."""
    img = Image.open(source).convert("RGBA")
    arr = np.array(img)

    alpha = arr[:, :, 3]
    mask = alpha > 0

    arr[mask, 0] = target_rgb[0]
    arr[mask, 1] = target_rgb[1]
    arr[mask, 2] = target_rgb[2]
    # 알파 채널은 원본 유지.

    Image.fromarray(arr, mode="RGBA").save(dest)


def recolor_hand(source: Path, target_rgb: tuple[int, int, int], dest: Path) -> None:
    """R 이 G·B 보다 25 이상 큰 빨강 픽셀만 목표색으로 치환한다."""
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

    Image.fromarray(arr, mode="RGBA").save(dest)


def main() -> None:
    cart_source = ASSETS_DIR / "cart_stop.png"
    hand_source = ASSETS_DIR / "hand_stop.png"

    for suffix, hex_color in TARGET_COLORS.items():
        target_rgb = hex_to_rgb(hex_color)

        cart_dest = ASSETS_DIR / f"cart_{suffix}.png"
        recolor_cart(cart_source, target_rgb, cart_dest)
        print(f"생성: {cart_dest} ({hex_color})")

        hand_dest = ASSETS_DIR / f"hand_{suffix}.png"
        recolor_hand(hand_source, target_rgb, hand_dest)
        print(f"생성: {hand_dest} ({hex_color})")


if __name__ == "__main__":
    main()
