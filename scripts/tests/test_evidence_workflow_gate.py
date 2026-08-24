from __future__ import annotations

import unittest
from pathlib import Path

from scripts.evidence_workflow_gate import load_contract_files, validate_contract


class EvidenceWorkflowGateTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        root = Path(__file__).resolve().parents[2]
        cls.repository_files = load_contract_files(root)

    def test_current_repository_satisfies_the_manual_evidence_contract(self) -> None:
        self.assertEqual(validate_contract(self.good_files()), [])

    def test_push_trigger_is_rejected_from_the_manual_caller(self) -> None:
        files = self.good_files()
        files["manual"] = files["manual"].replace(
            "  workflow_dispatch:\n", "  workflow_dispatch:\n  push:\n"
        )
        self.assertIn("manual caller trigger must be workflow_dispatch only", validate_contract(files))

    def test_reusable_workflows_remain_workflow_call_only(self) -> None:
        files = self.good_files()
        files["exact"] = files["exact"].replace("workflow_call", "workflow_dispatch")
        self.assertIn("exact workflow trigger must be workflow_call only", validate_contract(files))

    def test_each_evidence_job_needs_same_head_correctness_admission(self) -> None:
        files = self.good_files()
        files["manual"] = files["manual"].replace(
            "    needs: correctness\n", "", 1
        )
        self.assertIn("exact-matcher job must need correctness", validate_contract(files))

    def test_correctness_is_called_locally_at_the_same_event_sha(self) -> None:
        files = self.good_files()
        files["manual"] = files["manual"].replace(
            "./.github/workflows/correctness.yml",
            "GuangDai/Clipy/.github/workflows/correctness.yml@master",
        )
        self.assertIn(
            "correctness job must call ./.github/workflows/correctness.yml",
            validate_contract(files),
        )

    def test_scale_prepare_stages_keep_their_liveness_guards(self) -> None:
        files = self.good_files()
        files["scale"] = files["scale"].replace("        timeout-minutes: 5\n", "")
        self.assertIn(
            "1,000-row prepare step must time out after 5 minutes",
            validate_contract(files),
        )

    def test_manual_evidence_cannot_cancel_an_expensive_in_progress_run(self) -> None:
        files = self.good_files()
        files["manual"] = files["manual"].replace(
            "cancel-in-progress: false", "cancel-in-progress: true"
        )
        self.assertIn(
            "manual evidence must not cancel an in-progress evidence run",
            validate_contract(files),
        )

    def test_manual_permissions_cannot_be_widened_to_write(self) -> None:
        files = self.good_files()
        files["manual"] = files["manual"].replace("contents: read", "contents: write")
        self.assertIn(
            "manual evidence permissions must be contents: read only",
            validate_contract(files),
        )

    def test_scale_artifact_allowlist_rejects_an_extra_recursive_glob(self) -> None:
        files = self.good_files()
        files["scale"] = files["scale"].replace(
            "            admission-logs/warm-open-samples/*.time\n",
            "            admission-logs/warm-open-samples/*.time\n"
            "            admission-logs/**\n",
        )
        self.assertIn(
            "scale evidence upload must always use the exact artifact allowlist",
            validate_contract(files),
        )

    def test_warm_open_completion_requires_nonempty_warmup_and_sample_timings(self) -> None:
        files = self.good_files()
        files["runner"] = files["runner"].replace(
            '  [[ -s "$samples_dir/warmup.time" ]]\n', ""
        )
        self.assertIn(
            "warm-open completion must require nonempty warmup and sample timing records",
            validate_contract(files),
        )

    def test_warm_open_completion_rejects_an_empty_sample_timing(self) -> None:
        files = self.good_files()
        files["runner"] = files["runner"].replace('    [[ -s "$time_file" ]]\n', "")
        self.assertIn(
            "warm-open completion must require nonempty warmup and sample timing records",
            validate_contract(files),
        )

    def test_long_measurement_phase_keeps_its_own_timeout(self) -> None:
        files = self.good_files()
        files["scale"] = files["scale"].replace("        timeout-minutes: 90\n", "")
        self.assertIn(
            "worst-bound exact-search step must time out after 90 minutes",
            validate_contract(files),
        )

    def good_files(self) -> dict[str, str]:
        return self.repository_files.copy()


if __name__ == "__main__":
    unittest.main()
