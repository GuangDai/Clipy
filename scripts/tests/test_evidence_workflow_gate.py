from __future__ import annotations

import unittest
from pathlib import Path

from scripts.evidence_workflow_gate import load_contract_files, validate_contract


class EvidenceWorkflowGateTests(unittest.TestCase):
    def test_current_repository_satisfies_the_manual_evidence_contract(self) -> None:
        root = Path(__file__).resolve().parents[2]
        self.assertEqual(validate_contract(load_contract_files(root)), [])

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
        self.assertIn("1,000-row prepare step must time out after 5 minutes", validate_contract(files))

    def test_manual_evidence_cannot_cancel_an_expensive_in_progress_run(self) -> None:
        files = self.good_files()
        files["manual"] = files["manual"].replace(
            "cancel-in-progress: false", "cancel-in-progress: true"
        )
        self.assertIn(
            "manual evidence must not cancel an in-progress evidence run",
            validate_contract(files),
        )

    def test_long_measurement_phase_keeps_its_own_timeout(self) -> None:
        files = self.good_files()
        files["scale"] = files["scale"].replace("        timeout-minutes: 90\n", "")
        self.assertIn(
            "worst-bound exact-search step must time out after 90 minutes",
            validate_contract(files),
        )

    @staticmethod
    def good_files() -> dict[str, str]:
        return {
            "manual": """name: Manual evidence\n\non:\n  workflow_dispatch:\n\npermissions:\n  contents: read\n\nconcurrency:\n  group: manual-exact-scale-evidence-${{ github.ref }}\n  cancel-in-progress: false\n\njobs:\n  correctness:\n    uses: ./.github/workflows/correctness.yml\n  exact-matcher:\n    needs: correctness\n    uses: ./.github/workflows/exact-matcher.yml\n  scale-admission:\n    needs: correctness\n    uses: ./.github/workflows/performance-admission.yml\n""",
            "correctness": """name: Correctness\n\non:\n  push:\n  pull_request:\n  workflow_dispatch:\n  workflow_call:\n""",
            "exact": """name: Exact\n\non:\n  workflow_call:\n\npermissions:\n  contents: read\n""",
            "scale": """name: Scale\n\non:\n  workflow_call:\n\npermissions:\n  contents: read\n\njobs:\n  performance-admission:\n    steps:\n      - name: Prepare 1,000-row smoke corpus\n        timeout-minutes: 5\n        run: prepare-smoke\n      - name: Require clean 1,000-row smoke corpus\n        if: always()\n        run: validate-smoke ${{ steps.prepare_smoke.outcome }}\n      - name: Prepare 5,000-row corpus\n        timeout-minutes: 10\n        run: prepare\n      - name: Require clean 5,000-row corpus\n        if: always() && steps.prepare_smoke_gate.outcome == 'success'\n        run: validate-prepare ${{ steps.prepare.outcome }}\n      - name: Measure tie-heavy browse-page latency\n        if: always() && steps.prepare_cleanliness.outcome == 'success'\n        timeout-minutes: 45\n      - name: Run one Debug exact-search diagnostic probe\n        if: always() && steps.prepare.outcome == 'success'\n        timeout-minutes: 15\n      - name: Require complete Debug exact-search diagnostics\n        if: always() && steps.prepare.outcome == 'success'\n        run: validate-exact-search-probe ${{ steps.exact_search_probe.outcome }}\n      - name: Measure worst-bound exact search\n        if: always() && steps.prepare_cleanliness.outcome == 'success' && steps.exact_search_probe_gate.outcome == 'success'\n        timeout-minutes: 90\n      - name: Measure independent-process warm persistent open\n        if: always() && steps.prepare_cleanliness.outcome == 'success' && steps.exact_search_probe_gate.outcome == 'success'\n        timeout-minutes: 45\n      - name: Upload admission evidence\n        if: always()\n        with:\n          path: |\n            admission-logs/*.json\n            admission-logs/*.log\n            admission-logs/*.time\n            admission-logs/warm-open-samples/*.json\n            admission-logs/warm-open-samples/*.time\n      - name: Require every scale admission mode\n        if: always()\n        run: prepare-smoke prepare prepare-cleanliness exact-search-probe exact-search-probe-gate browse-ties exact-search warm-open finalize\n""",
        }


if __name__ == "__main__":
    unittest.main()
