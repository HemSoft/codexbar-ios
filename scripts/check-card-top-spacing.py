#!/usr/bin/env python3
"""Local-only pixel regression for an unscrolled synthetic Codex dashboard.

Requires Pillow. Use native portrait screenshots at the named device's scale.
This deliberately measures rendered title ink, not a source-code padding value.
Only the first account card is measured; interactions and other cards need UI tests.
"""
import argparse
import json
from pathlib import Path

from PIL import Image


def measure(path: Path, scale: int, theme: str) -> dict:
    image = Image.open(path).convert("RGB")
    expected_width = 402 * scale if scale == 3 else 1032 * scale
    if image.width != expected_width:
        raise ValueError(f"Expected portrait width {expected_width}, got {image.width}")

    def surface(pixel):
        return min(pixel) >= 250 if theme == "light" else all(22 <= channel <= 34 for channel in pixel)

    # x=24 pt is inside the card's rounded corner but outside its padded contents.
    # Start below navigation chrome; require a sustained surface run, not a glyph.
    top = next((y for y in range(120 * scale, min(500 * scale, image.height - 20 * scale))
                if all(surface(image.getpixel((24 * scale, y + dy))) for dy in range(20 * scale))), None)
    if top is None:
        raise ValueError(f"First card surface not found for theme '{theme}'; check --theme and use a loaded, unscrolled fixture")

    def title_ink(pixel):
        return max(pixel) < 80 if theme == "light" else min(pixel) > 190

    # The Codex logo ends at x=56 pt; account title ink starts at x=64 pt.
    title = next((y for y in range(top, min(top + 160 * scale, image.height))
                  if sum(title_ink(image.getpixel((x, y))) for x in range(64 * scale, 220 * scale)) >= 4 * scale), None)
    if title is None:
        raise ValueError("Account title not found; this check requires the Codex fixture")
    gap = (title - top) / scale
    return {"image": str(path), "theme": theme, "card_top_pt": top / scale,
            "title_top_pt": title / scale, "gap_pt": gap, "passed": 14 <= gap <= 28}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("images", type=Path, nargs="+")
    parser.add_argument("--scale", type=int, choices=(2, 3), required=True)
    parser.add_argument("--theme", choices=("light", "dark"), default="light",
                        help="Theme of every supplied screenshot; run light and dark batches separately")
    args = parser.parse_args()
    results = [measure(path, args.scale, args.theme) for path in args.images]
    print(json.dumps(results, indent=2))
    return 0 if all(result["passed"] for result in results) else 1


if __name__ == "__main__":
    raise SystemExit(main())
