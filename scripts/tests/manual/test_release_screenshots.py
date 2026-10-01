#!/usr/bin/env python3
"""Explicit local-only screenshot contract checks; not automatic test discovery."""
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest
import struct
import zlib

ROOT = Path(__file__).resolve().parents[3]


class ReleaseScreenshotContractTests(unittest.TestCase):
    def test_all_capture_scenes_parse_and_feature_the_intended_account(self):
        fixture = (ROOT / "CodexBarIOS/Services/AppStoreScreenshotFixtures.swift").read_text()
        # Compile the real configuration/parser and featured-account helper.
        # The store spy observes routing only; native captures prove rendering.
        source = fixture.split("    static func results", 1)[0] + "}\n#endif\n"
        scenes = re.findall(r'^  "([^:]+):(?:light|dark)"$',
                            (ROOT / "scripts/capture-app-store-screenshots.sh").read_text(), re.M)
        self.assertEqual(len(scenes), 9)
        self.assertEqual(len(set(scenes)), 9)
        catalog = (ROOT / "CodexBarIOS/Models/GoogleUsageMetricCatalog.swift").read_text()
        source += catalog.split("    public static func metrics", 1)[0] + "}\n"
        source += r'''
public enum ProviderID: String, Sendable { case gemini, antigravity, other }
enum MetricTileWidthPreference { case half }
@MainActor final class ProviderConfigurationStore {
    var orders: [[String]] = []
    var halfWidthMetrics: [String] = []
    func updateDashboardCardOrder(_ ids: [String]) { orders.append(ids) }
    func updateMetricWidth(_ width: MetricTileWidthPreference, accountID: String, metricID: String) {
        precondition(accountID == AppStoreScreenshotFixtureID.geminiAccount)
        halfWidthMetrics.append(metricID)
    }
}
@main struct Contract {
    @MainActor static func main() {
        let scenes = SCENES
        let featured = ["gemini": AppStoreScreenshotFixtureID.geminiAccount,
                        "grok": AppStoreScreenshotFixtureID.grokAccount,
                        "github-billing": AppStoreScreenshotFixtureID.githubBillingAccount]
        for raw in scenes {
            let config = AppStoreScreenshotConfiguration.parse(arguments: [
                "--app-store-screenshots", "--app-store-scene", raw,
                "--app-store-appearance", "dark", "--app-store-settle-seconds", "50"
            ])!
            precondition(config.scene.rawValue == raw)
            precondition(config.appearance == .dark && config.settleDelay == 30)
            let store = ProviderConfigurationStore()
            AppStoreScreenshotFixtures.featureAccount(for: config.scene, in: store)
            precondition(store.orders == (featured[raw].map { [[$0]] } ?? []))
            precondition(store.halfWidthMetrics == (raw == "gemini" ? [
                "gemini.five-hour", "gemini.weekly", "antigravity.gemini-5h",
                "antigravity.gemini-weekly", "antigravity.3p-5h", "antigravity.3p-weekly"
            ] : []))
        }
        precondition(AppStoreScreenshotConfiguration.parse(arguments: ["--app-store-scene", "gemini"]) == nil)
        let fallback = AppStoreScreenshotConfiguration.parse(arguments: [
            "--app-store-screenshots", "--app-store-scene", "invalid",
            "--app-store-settle-seconds", "-2"
        ])!
        precondition(fallback.scene == .dashboardOverview && fallback.settleDelay == 0)
        print("Nine real parser/routing contracts passed; normal launch stays inactive.")
    }
}
'''.replace("SCENES", str(scenes).replace("'", '"'))
        env = dict(os.environ, DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer")
        with tempfile.TemporaryDirectory(prefix="codexbar-screenshot-contract-") as directory:
            path = Path(directory)
            (path / "Contract.swift").write_text(source)
            subprocess.run(["xcrun", "swiftc", "-DDEBUG", "-parse-as-library",
                            str(ROOT / "CodexBarIOS/Models/AppAppearance.swift"),
                            str(path / "Contract.swift"), "-o", str(path / "contract")],
                           env=env, check=True)
            subprocess.run([str(path / "contract")], env=env, check=True)

    def test_watch_flattening_removes_alpha_without_resizing(self):
        script = (ROOT / "scripts/flatten-storefront-image.sh").read_text()
        swift = script.split("<<'SWIFT'\n", 1)[1].split("\nSWIFT", 1)[0]

        def chunk(kind, data):
            return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))

        # Transparent and opaque pixels, encoded losslessly without third-party tools.
        png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 2, 2, 8, 6, 0, 0, 0))
        png += chunk(b"IDAT", zlib.compress(
            b"\0\xff\0\0\0\0\xff\0\xff\0\0\0\xff\x80\xff\xff\xff\xff"))
        png += chunk(b"IEND", b"")
        env = dict(os.environ, DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer")
        with tempfile.TemporaryDirectory(prefix="codexbar-watch-png-") as directory:
            input_path, output_path = Path(directory) / "alpha.png", Path(directory) / "opaque.png"
            input_path.write_bytes(png)
            subprocess.run(["xcrun", "swift", "-", str(input_path), str(output_path)],
                           input=swift, text=True, env=env, check=True)
            output = output_path.read_bytes()
            self.assertEqual(struct.unpack(">II", output[16:24]), (2, 2))
            self.assertEqual(output[25], 2, "PNG must be RGB, not RGBA")

    def test_capture_outputs_and_toolchain_selection_remain_explicit(self):
        ios = (ROOT / "scripts/capture-app-store-screenshots.sh").read_text()
        watch = (ROOT / "scripts/capture-watch-app-store-screenshots.sh").read_text()
        self.assertIn('OS=$IOS_SIMULATOR_OS', ios)
        self.assertIn('IOS_SIMULATOR_OS="${IOS_SIMULATOR_OS:-latest}"', ios)
        for text in (ios, watch):
            self.assertIn('OUTPUT_DIR="${OUTPUT_DIR:-', text)
            self.assertIn('DERIVED_DATA="${DERIVED_DATA:-', text)
            self.assertIn('-skipPackagePluginValidation', text)
            self.assertIn('scripts/flatten-storefront-image.sh', text)
        self.assertIn('release-assets/1.4.0/screenshots', watch)
        self.assertNotIn('release-assets/1.2/screenshots', watch)
        self.assertFalse((Path(__file__).parent / "__init__.py").exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
