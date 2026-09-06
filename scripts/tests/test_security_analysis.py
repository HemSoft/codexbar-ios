"""Security gate failure cases. Actual analyzer reach is verified separately in CI."""

import copy
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


SPEC = importlib.util.spec_from_file_location(
    "security_gate", Path(__file__).resolve().parents[1] / "security-analysis/gate.py"
)
GATE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(GATE)


class SecurityGateTests(unittest.TestCase):
    def setUp(self):
        self.sarif = {"version": "2.1.0", "runs": [{
            "tool": {"driver": {"name": "CodeQL", "rules": [{
                "id": "swift/insecure-tls", "properties": {"security-severity": "7.5"}
            }]}},
            "invocations": [{"executionSuccessful": True}], "results": []
        }]}

    def finding(self):
        return {"ruleId": "swift/insecure-tls", "message": {"text": "Fixture"}, "locations": [{
            "physicalLocation": {"artifactLocation": {"uri": "fixture.swift"}, "region": {"startLine": 4}}
        }]}

    def test_completed_clean_analysis(self):
        self.assertEqual(GATE.check_findings(self.sarif)["blocking_findings"], [])

    def test_high_finding_blocks_even_when_suppressed(self):
        finding = self.finding()
        finding["suppressions"] = [{"kind": "inSource", "status": "accepted"}]
        self.sarif["runs"][0]["results"] = [finding]
        self.assertEqual(len(GATE.check_findings(self.sarif)["blocking_findings"]), 1)

    def test_action_grouped_pack_metadata_blocks_high_finding(self):
        tool = self.sarif["runs"][0]["tool"]
        tool["extensions"] = [{"name": "codeql/swift-queries", "rules": tool["driver"].pop("rules")}]
        finding = self.finding()
        finding["rule"] = {"id": finding["ruleId"], "index": 0, "toolComponent": {"index": 0}}
        self.sarif["runs"][0]["results"] = [finding]
        self.assertEqual(len(GATE.check_findings(self.sarif)["blocking_findings"]), 1)

    def test_missing_or_bad_component_reference_is_not_clean(self):
        tool = self.sarif["runs"][0]["tool"]
        tool["extensions"] = [{"name": "codeql/swift-queries", "rules": tool["driver"].pop("rules")}]
        for reference in ({}, {"toolComponent": {}}, {"toolComponent": {"index": -1}},
                          {"toolComponent": {"index": 1}}, {"toolComponent": {"index": 0, "name": "wrong"}}):
            with self.subTest(reference=reference):
                finding = self.finding()
                finding["rule"] = reference
                self.sarif["runs"][0]["results"] = [finding]
                with self.assertRaises(ValueError):
                    GATE.check_findings(self.sarif)

    def test_conflicting_rule_id_or_index_is_not_clean(self):
        for reference in ({"id": "swift/other"}, {"index": 1}):
            with self.subTest(reference=reference):
                finding = self.finding()
                finding["rule"] = reference
                self.sarif["runs"][0]["results"] = [finding]
                with self.assertRaises(ValueError):
                    GATE.check_findings(self.sarif)

    def test_duplicate_rule_ids_fail_closed(self):
        tool = self.sarif["runs"][0]["tool"]
        tool["extensions"] = [{"rules": copy.deepcopy(tool["driver"]["rules"])}]
        with self.assertRaises(ValueError):
            GATE.check_findings(self.sarif)

    def test_medium_is_published_without_blocking(self):
        self.sarif["runs"][0]["tool"]["driver"]["rules"][0]["properties"]["security-severity"] = "6.9"
        self.sarif["runs"][0]["results"] = [self.finding()]
        result = GATE.check_findings(self.sarif)
        self.assertEqual(len(result["findings"]), 1)
        self.assertEqual(result["blocking_findings"], [])

    def test_missing_failed_or_error_analysis_is_not_clean(self):
        cases = [[], [{"executionSuccessful": False}], [{"executionSuccessful": True,
                  "toolExecutionNotifications": [{"level": "error"}]}]]
        for invocations in cases:
            with self.subTest(invocations=invocations):
                self.sarif["runs"][0]["invocations"] = invocations
                with self.assertRaises(ValueError):
                    GATE.check_findings(self.sarif)

    def test_malformed_score_is_not_clean(self):
        for score in ("NaN", "Infinity", "-1", "11", "invalid"):
            with self.subTest(score=score):
                sarif = copy.deepcopy(self.sarif)
                sarif["runs"][0]["tool"]["driver"]["rules"][0]["properties"]["security-severity"] = score
                sarif["runs"][0]["results"] = [self.finding()]
                with self.assertRaises(ValueError):
                    GATE.check_findings(sarif)

    def test_swift_extraction_diagnostic_blocks_even_at_level_none(self):
        self.sarif["runs"][0]["invocations"][0]["toolExecutionNotifications"] = [{
            "descriptor": {"id": "swift/diagnostics/extraction-errors"}, "level": "none",
            "message": {"text": "SDK module was built by a different compiler"}
        }]
        with self.assertRaisesRegex(ValueError, "Swift extraction errors"):
            GATE.check_findings(self.sarif)

    def test_malformed_score_without_findings_is_not_clean(self):
        for score in ("NaN", "Infinity", "-1", "11", "invalid", True, None):
            with self.subTest(score=score):
                sarif = copy.deepcopy(self.sarif)
                sarif["runs"][0]["tool"]["driver"]["rules"][0]["properties"]["security-severity"] = score
                with self.assertRaises(ValueError):
                    GATE.check_findings(sarif)

    def test_missing_security_score_without_findings_is_not_clean(self):
        self.sarif["runs"][0]["tool"]["driver"]["rules"][0]["properties"] = {"tags": ["security"]}
        with self.assertRaises(ValueError):
            GATE.check_findings(self.sarif)

    def test_empty_security_suite_is_not_clean(self):
        self.sarif["runs"][0]["tool"]["driver"]["rules"] = []
        with self.assertRaises(ValueError):
            GATE.check_findings(self.sarif)

    def test_unbuilt_or_empty_ast_production_source_blocks(self):
        expected = {"CodexBarIOS/A.swift", "CodexBarWatch/B.swift"}
        for rows in ([['CodexBarIOS/A.swift', '10', '0']], [['CodexBarIOS/A.swift', '0', '0']]):
            with self.subTest(rows=rows):
                self.assertTrue(GATE.check_reach(rows, expected)["errors"])

    def test_partial_extraction_with_compiler_error_blocks(self):
        result = GATE.check_reach([["CodexBarIOS/A.swift", "10", "1"]], {"CodexBarIOS/A.swift"})
        self.assertTrue(result["errors"])

    def test_all_production_files_need_syntax(self):
        result = GATE.check_reach([["CodexBarIOS/A.swift", "10", "0"]], {"CodexBarIOS/A.swift"})
        self.assertEqual(result["extracted_files"], 1)
        self.assertEqual(result["errors"], [])

    def test_empty_scope_is_not_clean(self):
        with self.assertRaises(ValueError):
            GATE.check_reach([], set())


class ReviewedBaselineTests(unittest.TestCase):
    def setUp(self):
        SecurityGateTests.setUp(self)
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.source = self.root / "CodexBarIOS/Existing.swift"
        self.source.parent.mkdir()
        self.source.write_text("// reviewed non-sensitive context\n")
        self.sources = patch.object(GATE, "production_sources", return_value={"CodexBarIOS/Existing.swift"})
        self.sources.start()
        self.addCleanup(self.sources.stop)
        tool = self.sarif["runs"][0]["tool"]
        tool["driver"]["semanticVersion"] = "2.26.4"
        tool["extensions"] = [{"name": "codeql/swift-queries", "semanticVersion": "1.3.9"}]
        self.result = SecurityGateTests.finding(self)
        self.result["locations"][0]["physicalLocation"]["artifactLocation"]["uri"] = "CodexBarIOS/Existing.swift"
        self.sarif["runs"][0]["results"] = [self.result]
        self.baseline = {
            "schema": 1, "reviewed_commit": "a" * 40,
            "source_snapshot_sha256": GATE.source_snapshot(self.root),
            "codeql_version": "2.26.4", "query_pack_version": "1.3.9",
            "findings": [{"finding": GATE.check_findings(self.sarif)["findings"][0],
                          "alert": "https://github.com/HemSoft/codexbar-ios/security/code-scanning/2",
                          "rationale": "Reviewed synthetic parser test, no real credentials."}]
        }

    def check_baseline(self):
        return GATE.check_findings(self.sarif, self.baseline, self.root)

    def test_exact_reviewed_finding_stays_visible(self):
        report = self.check_baseline()
        self.assertEqual(len(report["findings"]), 1)
        self.assertEqual(len(report["accepted_findings"]), 1)
        self.assertEqual(report["blocking_findings"], [])

    def test_unreviewed_high_finding_in_unchanged_file_blocks(self):
        introduced = copy.deepcopy(self.result)
        introduced["locations"][0]["physicalLocation"]["region"]["startLine"] = 10
        self.sarif["runs"][0]["results"].append(introduced)
        report = self.check_baseline()
        self.assertEqual(len(report["accepted_findings"]), 1)
        self.assertEqual(len(report["blocking_findings"]), 1)

    def test_production_context_change_invalidates_review(self):
        self.source.write_text("// changed downstream persistence or auth context\n")
        with self.assertRaisesRegex(ValueError, "Production sources changed"):
            self.check_baseline()

    def test_added_production_file_invalidates_review(self):
        (self.source.parent / "NewSink.swift").write_text("// new consumer\n")
        with patch.object(GATE, "production_sources", return_value={
                "CodexBarIOS/Existing.swift", "CodexBarIOS/NewSink.swift"}):
            with self.assertRaisesRegex(ValueError, "Production sources changed"):
                self.check_baseline()

    def test_changed_message_location_flow_or_suppression_requires_review(self):
        original = copy.deepcopy(self.result)
        mutations = [lambda item: item["message"].update(text="different sensitive source"),
                     lambda item: item["locations"][0]["physicalLocation"]["region"].update(startLine=8),
                     lambda item: item.update(codeFlows=[{"threadFlows": []}]),
                     lambda item: item.update(suppressions=[{"kind": "external", "status": "accepted"}])]
        for mutation in mutations:
            with self.subTest(mutation=mutation):
                changed = copy.deepcopy(original)
                mutation(changed)
                self.sarif["runs"][0]["results"] = [changed]
                with self.assertRaisesRegex(ValueError, "missing, changed, or duplicated"):
                    self.check_baseline()

    def test_sarif_artifact_table_reordering_preserves_identity(self):
        self.result["locations"][0]["physicalLocation"]["artifactLocation"]["index"] = 42
        self.assertEqual(len(self.check_baseline()["accepted_findings"]), 1)

    def test_duplicate_result_or_baseline_never_expands_allowance(self):
        self.sarif["runs"][0]["results"].append(copy.deepcopy(self.result))
        with self.assertRaisesRegex(ValueError, "duplicated"):
            self.check_baseline()
        self.sarif["runs"][0]["results"].pop()
        self.baseline["findings"].append(copy.deepcopy(self.baseline["findings"][0]))
        with self.assertRaisesRegex(ValueError, "Duplicate reviewed"):
            self.check_baseline()

    def test_missing_reviewed_result_is_not_a_clean_scan(self):
        self.sarif["runs"][0]["results"] = []
        with self.assertRaisesRegex(ValueError, "missing, changed, or duplicated"):
            self.check_baseline()

    def test_analyzer_or_query_pack_upgrade_requires_review(self):
        for component in (self.sarif["runs"][0]["tool"]["driver"],
                          self.sarif["runs"][0]["tool"]["extensions"][0]):
            original = component["semanticVersion"]
            component["semanticVersion"] = "new"
            with self.assertRaisesRegex(ValueError, "Analyzer changed"):
                self.check_baseline()
            component["semanticVersion"] = original

    def test_malformed_baseline_does_not_accept_findings(self):
        original = copy.deepcopy(self.baseline)
        mutations = [lambda item: item.update(schema=True),
                     lambda item: item.update(reviewed_commit=""),
                     lambda item: item.update(source_snapshot_sha256=None),
                     lambda item: item.update(codeql_version=None),
                     lambda item: item.update(query_pack_version=""),
                     lambda item: item["findings"][0].update(alert=None),
                     lambda item: item["findings"][0]["finding"].update(line=True),
                     lambda item: item["findings"][0]["finding"].update(severity="7.5"),
                     lambda item: item.update(findings=[]),
                     lambda item: item["findings"][0].update(rationale=""),
                     lambda item: item["findings"][0]["finding"].pop("diagnostic_sha256"),
                     lambda item: item.update(ignored_paths=["*"])]
        for mutation in mutations:
            with self.subTest(mutation=mutation):
                self.baseline = copy.deepcopy(original)
                mutation(self.baseline)
                with self.assertRaises(ValueError):
                    self.check_baseline()


class SecurityWorkflowTests(unittest.TestCase):
    def test_pr_analysis_disables_diff_filtering_and_uses_reviewed_baseline(self):
        workflow = (Path(__file__).resolve().parents[2]
                    / ".github/workflows/security-analysis.yml").read_text()
        setting = "      CODEQL_ACTION_DIFF_INFORMED_QUERIES: 'false'"
        self.assertEqual(workflow.count("CODEQL_ACTION_DIFF_INFORMED_QUERIES"), 1)
        self.assertIn("    env:\n      DEVELOPER_DIR: /Applications/Xcode.app/Contents/Developer\n"
                      "      # The custom gate requires all findings, including unchanged PR source.\n"
                      + setting, workflow)
        self.assertIn("--baseline scripts/security-analysis/reviewed-baseline.json", workflow)


if __name__ == "__main__":
    unittest.main()
