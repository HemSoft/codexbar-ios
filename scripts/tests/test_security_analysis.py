"""Security gate failure cases. Actual analyzer reach is verified separately in CI."""

import copy
import importlib.util
from pathlib import Path
import unittest


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


if __name__ == "__main__":
    unittest.main()
