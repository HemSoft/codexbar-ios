import re
import unittest
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
CI_WORKFLOW = REPOSITORY_ROOT / ".github" / "workflows" / "ci.yml"
PACKAGE_MANIFEST = REPOSITORY_ROOT / "Package.swift"
SWIFTLINT_CONFIGURATION = REPOSITORY_ROOT / ".swiftlint.yml"
UI_RUNNER = REPOSITORY_ROOT / "scripts" / "run-ui-tests.sh"


def job_block(workflow: str, job_id: str) -> str:
    pattern = re.compile(
        rf"^  {re.escape(job_id)}:\n.*?(?=^  [A-Za-z0-9_-]+:\n|\Z)",
        re.MULTILINE | re.DOTALL,
    )
    match = pattern.search(workflow)
    if match is None:
        raise AssertionError(f"Missing workflow job: {job_id}")
    return match.group(0)


class CITriggerPolicyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.workflow = CI_WORKFLOW.read_text(encoding="utf-8")
        cls.package_manifest = PACKAGE_MANIFEST.read_text(encoding="utf-8")
        cls.swiftlint_configuration = SWIFTLINT_CONFIGURATION.read_text(encoding="utf-8")
        cls.ui_runner = UI_RUNNER.read_text(encoding="utf-8")

    def test_ci_supports_automatic_and_manual_runs(self) -> None:
        triggers = self.workflow.split("permissions:", maxsplit=1)[0]
        self.assertIn("  pull_request:\n", triggers)
        self.assertIn("  push:\n", triggers)
        self.assertIn("  workflow_dispatch:\n", triggers)

    def test_automatic_ios_job_stops_after_unit_and_risk_checks(self) -> None:
        ios_job = job_block(self.workflow, "ios-tests")
        self.assertIn("    name: iOS tests\n", ios_job)
        self.assertIn("    timeout-minutes: 30\n", ios_job)
        self.assertIn("Run iOS unit tests", ios_job)
        self.assertIn("Enforce iOS function risk baseline", ios_job)
        self.assertNotIn("UI journeys", ios_job)
        self.assertNotIn("run-ui-tests.sh", ios_job)

    def test_ui_job_runs_only_after_a_successful_manual_gate(self) -> None:
        ui_job = job_block(self.workflow, "ios-ui-tests")
        self.assertIn("    name: Full iOS UI validation\n", ui_job)
        self.assertIn(
            "    if: ${{ github.event_name == 'workflow_dispatch' && success() }}\n",
            ui_job,
        )
        for required_job in (
            "swiftlint",
            "strict-concurrency",
            "ios-tests",
            "watch-tests",
            "smoke-tests",
        ):
            self.assertIn(f"      - {required_job}\n", ui_job)

        expected_steps = (
            "Run iPhone UI journeys",
            "Run iPad UI journeys",
            "Require both UI destinations",
            "Preserve UI test results and failure screenshots",
        )
        positions = [ui_job.index(step) for step in expected_steps]
        self.assertEqual(positions, sorted(positions))
        self.assertIn("run: ./scripts/run-ui-tests.sh iphone", ui_job)
        self.assertIn("run: ./scripts/run-ui-tests.sh ipad", ui_job)
        self.assertIn("if: ${{ always() }}", ui_job)
        self.assertIn("retention-days: 14", ui_job)

    def test_github_billing_fixtures_are_manual_only(self) -> None:
        for automatic_job in (
            "swiftlint",
            "strict-concurrency",
            "ios-tests",
            "watch-tests",
            "smoke-tests",
        ):
            self.assertNotIn("GitHubBillingFixtureTests", job_block(self.workflow, automatic_job))
        swiftlint_job = job_block(self.workflow, "swiftlint")
        self.assertIn("SWIFTLINT_EXCLUDED_GITHUB_BILLING", swiftlint_job)
        self.assertIn(
            "  - ${SWIFTLINT_EXCLUDED_GITHUB_BILLING}\n",
            self.swiftlint_configuration,
        )
        fixture_target = self.package_manifest.rsplit(
            'name: "GitHubBillingFixtureTests"', maxsplit=1
        )[1].split("        ),", maxsplit=1)[0]
        self.assertIn("SwiftLintBuildToolPlugin", fixture_target)

        ui_job = job_block(self.workflow, "ios-ui-tests")
        self.assertIn("Run GitHub Billing API fixtures", ui_job)
        self.assertIn("xcrun swift run GitHubBillingFixtureTests", ui_job)

    def test_ui_runner_requires_all_five_journeys(self) -> None:
        for assertion in (
            ".totalTestCount == 5",
            ".passedTests == 5",
            ".failedTests == 0",
            ".skippedTests == 0",
            ".expectedFailures == 0",
        ):
            self.assertIn(assertion, self.ui_runner)


if __name__ == "__main__":
    unittest.main()
