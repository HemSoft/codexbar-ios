#!/usr/bin/env python3
"""Re-evaluate the committed, losslessly compressed measurement records."""
import copy
import hashlib
import json
import math
from pathlib import Path

from run import evaluate, validate

SUMMARY_ROUNDOFF = 1e-12
STUDY_MANIFEST = json.loads(Path(__file__).with_name("repeatability-manifest.json").read_text())
# Keep the complete study manifest outside its mutable measurement recording.
STUDY_EXPERIMENT_NAMES = (
    "usage-history-performance-34046485812-1",
    "usage-history-performance-34046485812-2",
    "usage-history-performance-34051802297-1",
    "usage-history-performance-34054447047-1",
    "unchanged-1", "unchanged-2", "unchanged-3", "slowdown",
    "quiet-1", "quiet-2", "quiet-3", "quiet-slowdown",
)


def same_timing_summary(stored, computed):
    """Allow only floating-point roundoff in derived summaries, never raw samples or verdicts."""
    if type(computed) is float:
        return type(stored) in (int, float) and math.isclose(
            stored, computed, rel_tol=SUMMARY_ROUNDOFF, abs_tol=SUMMARY_ROUNDOFF)
    if isinstance(computed, dict):
        return (isinstance(stored, dict) and stored.keys() == computed.keys()
                and all(same_timing_summary(stored[key], value) for key, value in computed.items()))
    if isinstance(computed, list):
        return (isinstance(stored, list) and len(stored) == len(computed)
                and all(same_timing_summary(old, new) for old, new in zip(stored, computed)))
    return type(stored) is type(computed) and stored == computed


def expand_runs(recording):
    if recording["recordingFormat"] != "uniform-retained-state-v1":
        raise ValueError("unsupported committed recording format")
    runs = copy.deepcopy(recording["runs"])
    for pair in runs:
        for side in ("reference", "candidate"):
            for scenario in pair[side]["scenarios"]:
                count = scenario.pop("retainedObservationCount")
                state = scenario.pop("retainedState")
                if type(count) is not int or count != 47 or "retainedStates" in scenario:
                    raise ValueError("invalid uniform retained-state recording")
                scenario["retainedStates"] = [copy.deepcopy(state) for _ in range(count)]
            validate(pair[side])
    return runs


def replay_study(study, policy):
    if study["recordingFormat"] != "paired-study-v1" or study["policy"] != policy:
        raise ValueError("unsupported study format or changed study policy")
    declared = study["experimentNames"]
    names = [recording["name"] for recording in study["experiments"]]
    if (tuple(declared) != STUDY_EXPERIMENT_NAMES or names != declared
            or tuple(STUDY_MANIFEST) != STUDY_EXPERIMENT_NAMES):
        raise ValueError("missing, duplicated or reordered study experiments")
    results = []
    for recording in study["experiments"]:
        runs = expand_runs(recording)
        hashes = [{side: hashlib.sha256(json.dumps(pair[side], sort_keys=True,
                                                   separators=(",", ":"), allow_nan=False).encode()).hexdigest()
                   for side in ("reference", "candidate")} for pair in runs]
        pinned = STUDY_MANIFEST[recording["name"]]
        if hashes != pinned["reportSHA256"] or recording["reportSHA256"] != pinned["reportSHA256"]:
            raise ValueError(f"study raw report changed: {recording['name']}")
        # evaluate also requires at least three independent pairs for every experiment.
        result = evaluate(runs, policy)
        expected = recording["result"]
        if {key: expected[key] for key in ("passed", "findings")} != pinned["verdict"]:
            raise ValueError(f"study pinned verdict changed: {recording['name']}")
        if (expected.keys() != result.keys() or expected["passed"] is not result["passed"]
                or expected["findings"] != result["findings"]
                or not same_timing_summary(expected["timings"], result["timings"])):
            raise ValueError(f"study verdict or timing summary changed: {recording['name']}")
        results.append((recording["name"], result))
    return results


def main():
    directory = Path(__file__).resolve().parent
    policy = json.loads((directory / "baseline.json").read_text())
    for name in ("calibration", "slowdown-proof"):
        recording = json.loads((directory / f"{name}.json").read_text())
        result = evaluate(expand_runs(recording), policy)
        if name == "calibration":
            if not result["passed"]:
                raise ValueError(f"committed calibration no longer passes: {result['findings']}")
            print("calibration: PASS")
        else:
            findings = result["findings"]
            if result["passed"] or any("INCONCLUSIVE" in finding for finding in findings):
                raise ValueError("committed slowdown no longer proves a regression")
            for accounts in (1, 10, 25):
                if not any(f"REGRESSION {accounts} accounts recordMilliseconds" in item for item in findings):
                    raise ValueError(f"missing {accounts}-account recording regression")
            print("slowdown-proof: expected recording REGRESSION for all account counts")
    study = json.loads((directory / "repeatability-study.json").read_text())
    for name, result in replay_study(study, policy):
        outcome = "PASS" if result["passed"] else "; ".join(result["findings"])
        print(f"{name}: {outcome}")


if __name__ == "__main__":
    main()
