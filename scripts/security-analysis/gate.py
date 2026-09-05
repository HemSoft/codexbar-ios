#!/usr/bin/env python3
"""Fail closed on incomplete CodeQL evidence or high-severity Swift findings."""

import argparse
import csv
import json
import math
from pathlib import Path
import subprocess
import sys


PRODUCTION_ROOTS = ("CodexBarIOS/", "CodexBarIOSWidget/", "CodexBarWatch/", "CodexBarWatchWidget/")


def production_sources(root):
    paths = subprocess.check_output(
        ["git", "ls-files", "-z", "--", "*.swift"], cwd=root
    ).decode().split("\0")
    return {path for path in paths if path.startswith(PRODUCTION_ROOTS)}


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


def check_findings(sarif):
    if sarif.get("version") != "2.1.0" or len(sarif.get("runs", [])) != 1:
        raise ValueError("Expected one complete CodeQL SARIF 2.1.0 run")
    run = sarif["runs"][0]
    driver = run["tool"]["driver"]
    if driver["name"] != "CodeQL" or not driver.get("rules"):
        raise ValueError("Missing CodeQL rule metadata")
    invocations = run.get("invocations", [])
    if not invocations or any(item.get("executionSuccessful") is not True for item in invocations):
        raise ValueError("CodeQL did not report successful analysis")
    for invocation in invocations:
        for key in ("toolExecutionNotifications", "toolConfigurationNotifications"):
            if any(item.get("level") == "error" for item in invocation.get(key, [])):
                raise ValueError("CodeQL reported an analysis error; inspect SARIF diagnostics")
    rules = {rule["id"]: rule for rule in driver["rules"]}
    if not any("security-severity" in rule.get("properties", {}) for rule in rules.values()):
        raise ValueError("No security queries were reported")
    findings = []
    for result in run["results"]:
        rule = rules[result["ruleId"]]
        properties = rule.get("properties", {})
        severity = properties.get("security-severity")
        if severity is None:
            if "security" in properties.get("tags", []):
                raise ValueError(f"Missing security severity: {rule['id']}")
            continue
        score = float(severity)
        if not math.isfinite(score) or not 0 <= score <= 10:
            raise ValueError(f"Invalid security severity: {rule['id']}")
        locations = result.get("locations", [])
        if not locations:
            raise ValueError(f"Missing finding location: {rule['id']}")
        location = locations[0]["physicalLocation"]
        findings.append({"rule": rule["id"], "severity": score,
                         "path": location["artifactLocation"]["uri"],
                         "line": location.get("region", {}).get("startLine"),
                         "message": result["message"]["text"]})
    # No accepted high-severity baseline or suppression exists. A dismissed or
    # suppressed alert still fails until a reviewed fix removes the finding.
    return {"findings": findings, "blocking_findings": [item for item in findings if item["severity"] >= 7]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sarif", required=True, type=Path)
    parser.add_argument("--reach", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    report = {}
    try:
        with args.reach.open(newline="") as source:
            rows = csv.reader(source)
            next(rows)  # CodeQL's CSV column headings.
            root = Path(__file__).resolve().parents[2]
            report["reach"] = check_reach(rows, production_sources(root))
        report.update(check_findings(json.loads(args.sarif.read_text())))
        report["passed"] = not report["reach"]["errors"] and not report["blocking_findings"]
    except (OSError, ValueError, KeyError, TypeError, StopIteration, subprocess.CalledProcessError) as error:
        report.update(passed=False, error=str(error))
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    sys.exit(main())
