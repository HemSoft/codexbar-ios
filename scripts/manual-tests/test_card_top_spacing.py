#!/usr/bin/env python3
"""Local-only measurement-helper tests. Requires Pillow; not automatic CI.

Generated rectangles validate the measurement algorithm, not app layout.
The actual app regression still requires native before/after captures.
"""
import importlib.util
from pathlib import Path
import tempfile
import unittest

from PIL import Image, ImageDraw

SCRIPT = Path(__file__).resolve().parents[1] / "check-card-top-spacing.py"
SPEC = importlib.util.spec_from_file_location("card_top_spacing", SCRIPT)
SPACING = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SPACING)


class CardTopSpacingTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.addCleanup(self.folder.cleanup)
        self.path = Path(self.folder.name) / "fixture.png"

    def image(self, gap=20, scale=3, theme="light", card=True, title=True):
        width = (402 if scale == 3 else 1032) * scale
        image = Image.new("RGB", (width, 700 * scale), (242, 242, 247) if theme == "light" else (0, 0, 0))
        draw = ImageDraw.Draw(image)
        top = 184 * scale
        surface = (255, 255, 255) if theme == "light" else (28, 28, 30)
        ink = (0, 0, 0) if theme == "light" else (255, 255, 255)
        if card:
            draw.rectangle((16 * scale, top, width - 16 * scale, 600 * scale), fill=surface)
        if title:
            draw.rectangle((64 * scale, top + gap * scale, 150 * scale, top + (gap + 8) * scale), fill=ink)
        image.save(self.path)
        return self.path

    def test_both_scales_and_themes_measure_title_gap(self):
        for scale in (2, 3):
            for theme in ("light", "dark"):
                with self.subTest(scale=scale, theme=theme):
                    result = SPACING.measure(self.image(scale=scale, theme=theme), scale, theme)
                    self.assertEqual(result["card_top_pt"], 184)
                    self.assertEqual(result["gap_pt"], 20)
                    self.assertTrue(result["passed"])

    def test_bounds_are_inclusive_and_excess_or_crowding_fails(self):
        for gap, passed in ((13, False), (14, True), (28, True), (29, False), (48, False)):
            with self.subTest(gap=gap):
                result = SPACING.measure(self.image(gap=gap), 3, "light")
                self.assertEqual(result["gap_pt"], gap)
                self.assertEqual(result["passed"], passed)

    def test_missing_surface_fails_closed(self):
        with self.assertRaisesRegex(ValueError, "First card surface not found"):
            SPACING.measure(self.image(card=False), 3, "light")

    def test_missing_title_fails_closed(self):
        with self.assertRaisesRegex(ValueError, "Account title not found"):
            SPACING.measure(self.image(title=False), 3, "light")

    def test_wrong_theme_names_the_required_flag(self):
        with self.assertRaisesRegex(ValueError, "theme 'light'; check --theme"):
            SPACING.measure(self.image(theme="dark"), 3, "light")

    def test_wrong_portrait_width_fails_closed(self):
        Image.new("RGB", (100, 100)).save(self.path)
        with self.assertRaisesRegex(ValueError, "Expected portrait width"):
            SPACING.measure(self.path, 3, "light")


if __name__ == "__main__":
    unittest.main()
