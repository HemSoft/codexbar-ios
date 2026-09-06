#!/usr/bin/env python3
"""Re-evaluate the committed, losslessly compressed measurement records."""
import copy
import json
from pathlib import Path

from run import evaluate, validate


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


if __name__ == "__main__":
    main()
