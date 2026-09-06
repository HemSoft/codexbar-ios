"""Exercise the performance gate's failure policy without timing unit tests."""
import copy
import importlib.util
import json
from pathlib import Path
import sys
import unittest
import tempfile
from unittest import mock

SCRIPT = Path(__file__).resolve().parents[1] / "usage-history-performance/run.py"
SPEC = importlib.util.spec_from_file_location("history_performance", SCRIPT)
GATE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(GATE)
POLICY = json.loads(SCRIPT.with_name("baseline.json").read_text())
REPLAY_SPEC = importlib.util.spec_from_file_location("history_replay", SCRIPT.with_name("replay.py"))
REPLAY = importlib.util.module_from_spec(REPLAY_SPEC)
with mock.patch.dict(sys.modules, {"run": GATE}):
    REPLAY_SPEC.loader.exec_module(REPLAY)


def report():
    return dict(configuration="release", fixtureVersion=1, timeZone="UTC", warmupBatches=2,
                measuredBatches=5, seriesIterationsPerBatch=5,
                scenarios=[dict(accounts=accounts, recordMilliseconds=[100, 100, 10, 10, 10, 10, 10],
                                seriesMilliseconds=[100, 100, 2, 2, 2, 2, 2], seriesPointCount=accounts * 329 * 35,
                                retainedStates=[dict(snapshots=accounts * 240, dailySnapshots=accounts * 180,
                                                     serializedBytes=accounts * 220000) for _ in range(47)])
                           for accounts in (1, 10, 25)])


class PerformanceGateTests(unittest.TestCase):
    def setUp(self):
        self.runs = [dict(reference=report(), candidate=report()) for _ in range(3)]

    def test_existing_results_cannot_masquerade_as_a_new_run(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "run"
            GATE.prepare_output(output)
            (output / "result.json").write_text('{"passed": false, "findings": ["REGRESSION"]}')
            with self.assertRaises(ValueError):
                GATE.prepare_output(output)
            self.assertTrue((output / "result.json").exists())

    def test_committed_recordings_expand_and_replay(self):
        for name, expected_pass in (("calibration", True), ("slowdown-proof", False)):
            with self.subTest(name=name):
                recording = json.loads(SCRIPT.with_name(f"{name}.json").read_text())
                original = copy.deepcopy(recording)
                expanded = REPLAY.expand_runs(recording)
                self.assertEqual(recording, original)
                states = expanded[0]["candidate"]["scenarios"][0]["retainedStates"]
                self.assertEqual(len(states), 47)
                self.assertEqual(states[0], states[-1])
                self.assertIsNot(states[0], states[-1])
                result = GATE.evaluate(expanded, POLICY)
                self.assertEqual(result["passed"], expected_pass)
                self.assertFalse(any("INCONCLUSIVE" in item for item in result["findings"]))
                if not expected_pass:
                    for accounts in (1, 10, 25):
                        self.assertTrue(any(f"REGRESSION {accounts} accounts recordMilliseconds" in item for item in result["findings"]))

    def test_invalid_compressed_recording_is_rejected(self):
        recording = json.loads(SCRIPT.with_name("calibration.json").read_text())
        recording["runs"][0]["candidate"]["scenarios"][0]["retainedObservationCount"] = 46
        with self.assertRaises(ValueError):
            REPLAY.expand_runs(recording)
        recording["recordingFormat"] = "unknown"
        with self.assertRaises(ValueError):
            REPLAY.expand_runs(recording)

    def test_equal_workloads_pass_and_warmups_are_excluded(self):
        for pair in self.runs:
            pair["candidate"]["scenarios"][0]["recordMilliseconds"] = [10000, 10000, 6, 8, 10, 12, 14]
        result = GATE.evaluate(self.runs, POLICY)
        self.assertTrue(result["passed"])
        self.assertEqual(result["timings"][0]["candidateMedians"], [10, 10, 10])

    def test_record_and_series_regressions_fail_independently(self):
        for metric in ("recordMilliseconds", "seriesMilliseconds"):
            with self.subTest(metric=metric):
                runs = copy.deepcopy(self.runs)
                for pair in runs:
                    pair["candidate"]["scenarios"][2][metric] = [100] * 7
                result = GATE.evaluate(runs, POLICY)
                self.assertFalse(result["passed"])
                self.assertTrue(any(f"REGRESSION 25 accounts {metric}" in item for item in result["findings"]))

    def test_noisy_reference_is_inconclusive_and_fails(self):
        self.runs[0]["reference"]["scenarios"][0]["recordMilliseconds"] = [100] * 7
        result = GATE.evaluate(self.runs, POLICY)
        self.assertFalse(result["passed"])
        self.assertTrue(any("INCONCLUSIVE" in item for item in result["findings"]))

    def test_serialized_expansion_fails_without_steady_growth(self):
        for state in self.runs[0]["candidate"]["scenarios"][0]["retainedStates"]:
            state["serializedBytes"] *= 2
        result = GATE.evaluate(self.runs, POLICY)
        self.assertEqual(result["findings"], ["REGRESSION 1 accounts: serialized size"])

    def test_steady_growth_fails_without_serialized_expansion(self):
        states = self.runs[0]["candidate"]["scenarios"][0]["retainedStates"]
        # Remain below the unchanged reference maximum while the steady tail grows.
        for state in states[3:]:
            state["serializedBytes"] -= POLICY["maximumGrowthBytesPerAccount"] + 1
        states[-1]["serializedBytes"] += POLICY["maximumGrowthBytesPerAccount"] + 1
        result = GATE.evaluate(self.runs, POLICY)
        self.assertEqual(result["findings"], ["REGRESSION 1 accounts: retained serialized growth"])

    def test_malformed_measurements_never_pass(self):
        mutations = [
            lambda value: value.update(configuration="debug"),
            lambda value: value.update(timeZone="America/New_York"),
            lambda value: value["scenarios"].clear(),
            lambda value: value["scenarios"][0].update(seriesPointCount=0),
            lambda value: value["scenarios"][0].update(recordMilliseconds=[1] * 6),
            lambda value: value["scenarios"][0].update(recordMilliseconds=[float("nan")] * 7),
            lambda value: value["scenarios"][0].update(seriesMilliseconds=[float("inf")] * 7),
            lambda value: value["scenarios"][0]["retainedStates"].pop(),
            lambda value: value["scenarios"][0]["retainedStates"][0].update(dailySnapshots=179),
            lambda value: value["scenarios"][0]["retainedStates"][0].update(serializedBytes=float("nan")),
            lambda value: value["scenarios"][0]["retainedStates"][0].update(serializedBytes=True),
        ]
        for index, mutate in enumerate(mutations):
            with self.subTest(index=index):
                invalid = report()
                mutate(invalid)
                with self.assertRaises(ValueError):
                    GATE.validate(invalid)
        with self.assertRaises(ValueError):
            GATE.evaluate(self.runs[:2], POLICY)


if __name__ == "__main__":
    unittest.main()
