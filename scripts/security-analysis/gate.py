#!/usr/bin/env python3
"""Fail closed on incomplete CodeQL evidence or unreviewed high-severity findings."""

import argparse
import csv
import hashlib
import json
import math
import re
from pathlib import Path
import subprocess
import sys


PRODUCTION_ROOTS = ("CodexBarIOS/", "CodexBarIOSWidget/", "CodexBarWatch/", "CodexBarWatchWidget/")


def production_sources(root):
    paths = subprocess.check_output(
        ["git", "ls-files", "-z", "--", "*.swift"], cwd=root
    ).decode().split("\0")
    return {path for path in paths if path.startswith(PRODUCTION_ROOTS)}


def source_snapshot(root):
    """Bind review to all production sources, including their names and consumers."""
    sources = [{"path": path, "sha256": hashlib.sha256((root / path).read_bytes()).hexdigest()}
               for path in sorted(production_sources(root))]
    if not sources:
        raise ValueError("No production source snapshot")
    return hashlib.sha256(json.dumps(sources, sort_keys=True).encode()).hexdigest()


def diagnostic_digest(result):
    """Retain complete diagnostic/data-flow identity without SARIF table offsets."""
    def normalize(value):
        if isinstance(value, list):
            return [normalize(item) for item in value]
        if isinstance(value, dict):
            normalized = {key: normalize(item) for key, item in value.items()}
            if "artifactLocation" in normalized:
                normalized["artifactLocation"].pop("index", None)
            return normalized
        return value

    diagnostic = normalize(result)
    # Rule references index the run's metadata, already validated by result_rule.
    diagnostic.pop("rule", None)
    diagnostic.pop("ruleIndex", None)
    return hashlib.sha256(json.dumps(diagnostic, sort_keys=True).encode()).hexdigest()


def apply_reviewed_baseline(sarif, findings, baseline, root):
    """Accept only exact, still-reviewed false positives; never refresh implicitly."""
    if (not isinstance(baseline, dict)
            or set(baseline) != {"schema", "reviewed_commit", "source_snapshot_sha256",
                                 "codeql_version", "query_pack_version", "findings"}
            or type(baseline["schema"]) is not int or baseline["schema"] != 1):
        raise ValueError("Invalid reviewed baseline schema")
    if (not isinstance(baseline["reviewed_commit"], str)
            or not re.fullmatch(r"[0-9a-f]{40}", baseline["reviewed_commit"])):
        raise ValueError("Invalid baseline review commit")
    if (not isinstance(baseline["source_snapshot_sha256"], str)
            or not re.fullmatch(r"[0-9a-f]{64}", baseline["source_snapshot_sha256"])):
        raise ValueError("Invalid baseline source snapshot")
    if any(not isinstance(baseline[key], str) or not baseline[key].strip()
           for key in ("codeql_version", "query_pack_version")):
        raise ValueError("Invalid baseline analyzer version")
    if baseline["source_snapshot_sha256"] != source_snapshot(root):
        raise ValueError("Production sources changed; re-review the non-actionable baseline")
    tool = sarif["runs"][0]["tool"]
    packs = [item for item in tool.get("extensions", []) if item.get("name") == "codeql/swift-queries"]
    if (tool["driver"].get("semanticVersion") != baseline["codeql_version"]
            or len(packs) != 1
            or packs[0].get("semanticVersion") != baseline["query_pack_version"]):
        raise ValueError("Analyzer changed; re-review the non-actionable baseline")
    entries = baseline["findings"]
    if not isinstance(entries, list) or not entries:
        raise ValueError("Reviewed baseline must contain explicit findings")
    accepted = []
    seen = set()
    for entry in entries:
        if (not isinstance(entry, dict)
                or set(entry) != {"finding", "alert", "rationale"}
                or not isinstance(entry["rationale"], str) or not entry["rationale"].strip()
                or not isinstance(entry["alert"], str)
                or not re.fullmatch(r"https://github.com/HemSoft/codexbar-ios/security/code-scanning/[0-9]+",
                                    entry["alert"])):
            raise ValueError("Invalid reviewed baseline entry")
        expected = entry["finding"]
        if (not isinstance(expected, dict)
                or set(expected) != {"rule", "severity", "path", "line", "message", "diagnostic_sha256"}
                or any(not isinstance(expected[key], str) or not expected[key]
                       for key in ("rule", "path", "message", "diagnostic_sha256"))
                or type(expected["line"]) is not int or expected["line"] <= 0
                or type(expected["severity"]) not in (int, float)
                or not re.fullmatch(r"[0-9a-f]{64}", expected["diagnostic_sha256"])
                or not 7 <= expected["severity"] <= 10):
            raise ValueError("Invalid reviewed finding identity")
        identity = expected["diagnostic_sha256"]
        if identity in seen:
            raise ValueError("Duplicate reviewed baseline finding")
        seen.add(identity)
        matches = [finding for finding in findings if finding == expected]
        if len(matches) != 1:
            raise ValueError("Reviewed finding missing, changed, or duplicated; re-review the baseline")
        accepted.append({**expected, "alert": entry["alert"], "rationale": entry["rationale"]})
    return accepted


def check_reach(rows, expected):
    if not expected:
        raise ValueError("No tracked production Swift files were found")
    extracted = {}
    errors = []
    for row in rows:
        if len(row) != 3:
            raise ValueError("Malformed source reach row")
        path, nodes, compiler_errors = row
        nodes, compiler_errors = int(nodes), int(compiler_errors)
        if path in extracted or nodes < 0 or compiler_errors < 0:
            raise ValueError("Invalid or duplicate source reach row")
        extracted[path] = nodes
        if compiler_errors:
            errors.append(f"{path}: {compiler_errors} extraction compiler errors")
    missing = sorted(path for path in expected if extracted.get(path, 0) == 0)
    errors.extend(f"No extracted Swift syntax: {path}" for path in missing)
    return {"expected_files": len(expected), "extracted_files": len(expected) - len(missing),
            "production_files": sorted(expected), "errors": errors}


def result_rule(result, tool):
    reference = result.get("rule", {})
    component = tool["driver"]
    if "toolComponent" in reference:
        component_ref = reference["toolComponent"]
        index = component_ref.get("index")
        extensions = tool.get("extensions", [])
        if type(index) is not int or not 0 <= index < len(extensions):
            raise ValueError("Invalid SARIF rule toolComponent reference")
        component = extensions[index]
        for key in ("name", "guid"):
            if key in component_ref and component_ref[key] != component.get(key):
                raise ValueError("Conflicting SARIF toolComponent reference")
    rule_id = result.get("ruleId", reference.get("id"))
    if not rule_id or reference.get("id", rule_id) != rule_id:
        raise ValueError("Missing or conflicting SARIF rule ID")
    rules = component.get("rules", [])
    matches = [rule for rule in rules if rule["id"] == rule_id]
    if len(matches) != 1:
        raise ValueError(f"Rule metadata not found in referenced component: {rule_id}")
    for index in (result.get("ruleIndex"), reference.get("index")):
        if index is not None and (type(index) is not int or not 0 <= index < len(rules)
                                  or rules[index]["id"] != rule_id):
            raise ValueError(f"Conflicting SARIF rule index: {rule_id}")
    return matches[0]


def security_severity(rule):
    properties = rule.get("properties", {})
    if "security-severity" not in properties:
        if "security" in properties.get("tags", []):
            raise ValueError(f"Missing security severity: {rule['id']}")
        return None
    severity = properties["security-severity"]
    if not isinstance(severity, (str, int, float)) or isinstance(severity, bool):
        raise ValueError(f"Invalid security severity: {rule['id']}")
    score = float(severity)
    if not math.isfinite(score) or not 0 <= score <= 10:
        raise ValueError(f"Invalid security severity: {rule['id']}")
    return score


def check_findings(sarif, baseline=None, source_root=None):
    if sarif.get("version") != "2.1.0" or len(sarif.get("runs", [])) != 1:
        raise ValueError("Expected one complete CodeQL SARIF 2.1.0 run")
    run = sarif["runs"][0]
    tool = run["tool"]
    driver = tool["driver"]
    if driver["name"] != "CodeQL":
        raise ValueError("Missing CodeQL rule metadata")
    invocations = run.get("invocations", [])
    if not invocations or any(item.get("executionSuccessful") is not True for item in invocations):
        raise ValueError("CodeQL did not report successful analysis")
    for invocation in invocations:
        for key in ("toolExecutionNotifications", "toolConfigurationNotifications"):
            notifications = invocation.get(key, [])
            if any(item.get("level") == "error" for item in notifications):
                raise ValueError("CodeQL reported an analysis error; inspect SARIF diagnostics")
            # Swift compiler failures are emitted with level=none, including
            # SDK errors that the repository-only source reach query cannot see.
            if any(item.get("descriptor", {}).get("id") == "swift/diagnostics/extraction-errors"
                   for item in notifications):
                raise ValueError("CodeQL reported Swift extraction errors; inspect SARIF diagnostics")
    # The Action uses --sarif-group-rules-by-pack; local CLI output can instead
    # keep rules in the driver. Accept both, failing on ambiguous rule IDs.
    rules = {}
    for component in [driver, *tool.get("extensions", [])]:
        for rule in component.get("rules", []):
            if rule["id"] in rules:
                raise ValueError(f"Duplicate rule metadata: {rule['id']}")
            rules[rule["id"]] = rule
    scores = {rule_id: security_severity(rule) for rule_id, rule in rules.items()}
    if not any(score is not None for score in scores.values()):
        raise ValueError("No security queries were reported")
    findings = []
    for result in run["results"]:
        rule = result_rule(result, tool)
        score = scores[rule["id"]]
        if score is None:
            continue
        locations = result.get("locations", [])
        if not locations:
            raise ValueError(f"Missing finding location: {rule['id']}")
        location = locations[0]["physicalLocation"]
        findings.append({"rule": rule["id"], "severity": score,
                         "path": location["artifactLocation"]["uri"],
                         "line": location.get("region", {}).get("startLine"),
                         "message": result["message"]["text"],
                         "diagnostic_sha256": diagnostic_digest(result)})
    accepted = apply_reviewed_baseline(sarif, findings, baseline, source_root) if baseline is not None else []
    accepted_ids = {item["diagnostic_sha256"] for item in accepted}
    return {"findings": findings, "accepted_findings": accepted,
            "blocking_findings": [item for item in findings
                                  if item["severity"] >= 7 and item["diagnostic_sha256"] not in accepted_ids]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sarif", required=True, type=Path)
    parser.add_argument("--reach", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--baseline", type=Path)
    args = parser.parse_args()
    report = {}
    try:
        with args.reach.open(newline="") as source:
            rows = csv.reader(source)
            next(rows)  # CodeQL's CSV column headings.
            root = Path(__file__).resolve().parents[2]
            report["reach"] = check_reach(rows, production_sources(root))
        baseline = json.loads(args.baseline.read_text()) if args.baseline else None
        report.update(check_findings(json.loads(args.sarif.read_text()), baseline, root))
        report["passed"] = not report["reach"]["errors"] and not report["blocking_findings"]
    except (OSError, ValueError, KeyError, TypeError, StopIteration, subprocess.CalledProcessError) as error:
        report.update(passed=False, error=str(error))
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    sys.exit(main())
