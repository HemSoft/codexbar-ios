"""Exercise the audit CLI with command doubles, without launching Xcode."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


REPOSITORY = Path(__file__).resolve().parents[2]
RUNNER = Path(".agents/skills/perfection/scripts/run-perfection.sh")
GATES = [
    "swiftlint", "strict-concurrency", "ios-build", "ios-tests",
    "swiftpm-smoke", "watch-build", "watch-tests",
]
LABELS = [
    "Repository SwiftLint", "Complete strict concurrency", "iOS simulator build",
    "iOS unit tests", "SwiftPM smoke tests", "watchOS simulator build",
    "watchOS unit tests",
]


class PerfectionRunnerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.repo = self.root / "repository"
        self.output = self.root / "audit"
        self.calls = self.root / "calls.jsonl"
        for relative in [RUNNER, Path("scripts/check-strict-concurrency.sh")]:
            target = self.repo / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(REPOSITORY / relative, target)

        commands = self.root / "bin"
        commands.mkdir()
        command_double = r'''#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys

name, args = Path(sys.argv[0]).name, sys.argv[1:]
if name == "git":
    if args[:1] == ["rev-parse"]:
        print("fixture-head")
    sys.exit(0)
if name == "jq":
    sys.exit("Simulator selection should not run with explicit destinations")
if name == "xcrun":
    if args[:3] == ["swift", "package", "plugin"]:
        assert args == ["swift", "package", "plugin",
            "--allow-writing-to-package-directory", "swiftlint", "lint",
            "--reporter", "xcode", "."], args
        gate = "swiftlint"
    else:
        assert args[:3] == ["swift", "run", "--scratch-path"], args
        assert args[-1] == "CodexBarIOSSmokeTests", args
        gate = "swiftpm-smoke"
else:
    assert name == "xcodebuild", name
    scheme = args[args.index("-scheme") + 1]
    assert "CODE_SIGNING_ALLOWED=NO" in args, args
    if "SWIFT_STRICT_CONCURRENCY=complete" in args:
        if args[-1] == "build":
            assert "SWIFT_TREAT_WARNINGS_AS_ERRORS=YES" in args, args
            assert args[-2:] == ["clean", "build"], args
            gate = "strict-build"
        else:
            assert args[-1] == "build-for-testing", args
            gate = "strict-ios-tests" if scheme == "CodexBarIOS" else "strict-watch-tests"
    else:
        assert "SWIFT_TREAT_WARNINGS_AS_ERRORS=YES" in args, args
        assert "GCC_TREAT_WARNINGS_AS_ERRORS=YES" in args, args
        prefix = "ios" if scheme == "CodexBarIOS" else "watch"
        gate = prefix + ("-tests" if args[-1] == "test" else "-build")
with open(os.environ["PERFECTION_TEST_CALLS"], "a") as output:
    output.write(json.dumps({"gate": gate, "args": args, "cwd": os.getcwd()}) + "\n")
print("command fixture: " + gate)
sys.exit(23 if os.environ.get("PERFECTION_TEST_FAIL") == gate else 0)
'''
        for command in ["xcrun", "xcodebuild", "git", "jq"]:
            path = commands / command
            path.write_text(command_double)
            path.chmod(0o755)
        self.env = {
            **os.environ,
            "PATH": str(commands) + os.pathsep + os.environ["PATH"],
            "DEVELOPER_DIR": str(self.root),
            "PERFECTION_OUTPUT_ROOT": str(self.output),
            "PERFECTION_IOS_DESTINATION": "platform=iOS Simulator,id=fixture-ios",
            "PERFECTION_WATCH_DESTINATION": "platform=watchOS Simulator,id=fixture-watch",
            "PERFECTION_TEST_CALLS": str(self.calls),
            "PERFECTION_TEST_FAIL": "",
        }

    def run_audit(self, *arguments, failure=""):
        return subprocess.run(
            ["bash", str(self.repo / RUNNER), *arguments],
            cwd=self.root,
            env={**self.env, "PERFECTION_TEST_FAIL": failure},
            capture_output=True, text=True, check=False,
        )

    def read_calls(self):
        return [json.loads(line) for line in self.calls.read_text().splitlines()]

    def assert_summary(self, result, passing, labels=LABELS):
        summary = (self.output / "latest-summary.md").read_text()
        self.assertIn(f"{passing} / {len(labels)} selected gates passing", summary)
        rows = [line for line in summary.splitlines() if " | PASS | " in line or " | FAIL | " in line]
        self.assertEqual([line.split(" | ")[0][2:] for line in rows], labels)
        for row in rows:
            log = Path(row.split("`")[1])
            self.assertTrue(log.is_file(), log)
            self.assertIn("command fixture:", log.read_text())
        self.assertIn("does not run UI journeys, function coverage/risk analysis", summary)
        self.assertIn("not counted as passing here", summary)
        self.assertIn(summary, result.stdout)
        return summary

    def test_list_and_help_expose_all_gates_without_running_tools(self):
        listed = self.run_audit("--list")
        self.assertEqual(listed.returncode, 0, listed.stderr)
        self.assertEqual(listed.stdout.splitlines(), GATES)
        help_result = self.run_audit("--help")
        self.assertEqual(help_result.returncode, 0, help_result.stderr)
        for gate in GATES:
            self.assertIn(gate, help_result.stdout)
        self.assertFalse(self.calls.exists())

    def test_default_runs_all_gates_and_status_replays_summary(self):
        result = self.run_audit()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        summary = self.assert_summary(result, 7)
        calls = self.read_calls()
        self.assertEqual([call["gate"] for call in calls], [
            "swiftlint", "strict-build", "strict-ios-tests", "strict-watch-tests",
            "ios-build", "ios-tests", "swiftpm-smoke", "watch-build", "watch-tests",
        ])
        self.assertTrue(all(call["cwd"] == str(self.repo) for call in calls))
        status = self.run_audit("--status")
        self.assertEqual(status.returncode, 0, status.stderr)
        self.assertEqual(status.stdout, summary)
        self.assertEqual(self.read_calls(), calls)

    def test_each_gate_can_run_alone(self):
        for gate, label in zip(GATES, LABELS):
            with self.subTest(gate=gate):
                self.calls.unlink(missing_ok=True)
                result = self.run_audit("--gate", gate)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assert_summary(result, 1, [label])
                expected = [gate] if gate != "strict-concurrency" else [
                    "strict-build", "strict-ios-tests", "strict-watch-tests",
                ]
                self.assertEqual([call["gate"] for call in self.read_calls()], expected)

    def test_lint_and_each_concurrency_failure_preserve_all_gate_results(self):
        for failure in ["swiftlint", "strict-build", "strict-ios-tests", "strict-watch-tests"]:
            with self.subTest(failure=failure):
                self.calls.unlink(missing_ok=True)
                result = self.run_audit(failure=failure)
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                summary = self.assert_summary(result, 6)
                failed_label = LABELS[0 if failure == "swiftlint" else 1]
                self.assertIn(f"| {failed_label} | FAIL |", summary)
                self.assertEqual(self.read_calls()[-1]["gate"], "watch-tests")

    def test_selected_lint_and_concurrency_fail_the_audit(self):
        for gate, failure, label in [
            ("swiftlint", "swiftlint", LABELS[0]),
            ("strict-concurrency", "strict-build", LABELS[1]),
        ]:
            with self.subTest(gate=gate):
                result = self.run_audit("--gate", gate, failure=failure)
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assert_summary(result, 0, [label])

    def test_invalid_selection_fails_before_running_tools(self):
        for arguments in [("--gate", "unknown"), ("--gate",), ("--unknown",)]:
            with self.subTest(arguments=arguments):
                result = self.run_audit(*arguments)
                self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertFalse(self.calls.exists())

    def test_missing_status_does_not_claim_success(self):
        result = self.run_audit("--status")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("No previous perfection audit summary", result.stderr)
        self.assertFalse(self.calls.exists())


if __name__ == "__main__":
    unittest.main()
