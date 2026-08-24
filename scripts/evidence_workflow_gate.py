#!/usr/bin/env python3
"""Narrow source contract for Clipy's manual evidence workflow.

This is intentionally not a general YAML linter. It protects only the GOV-1
failure mode observed when CI was split in af0a5a7: the two expensive evidence
workflows lost their caller, and the 1,000/5,000-row prepare phases lost their
independent liveness guards. GitHub remains the workflow syntax/runtime owner.
"""

from __future__ import annotations

import sys
from pathlib import Path


CONTRACT_PATHS = {
    "manual": Path(".github/workflows/manual-evidence.yml"),
    "correctness": Path(".github/workflows/correctness.yml"),
    "exact": Path(".github/workflows/exact-matcher.yml"),
    "scale": Path(".github/workflows/performance-admission.yml"),
}


def load_contract_files(root: Path) -> dict[str, str]:
    files: dict[str, str] = {}
    for key, relative_path in CONTRACT_PATHS.items():
        path = root / relative_path
        files[key] = path.read_text(encoding="utf-8") if path.is_file() else ""
    return files


def _indent(line: str) -> int:
    return len(line) - len(line.lstrip(" "))


def _block(text: str, header: str, indent: int) -> str:
    lines = text.splitlines()
    marker = " " * indent + header + ":"
    for index, line in enumerate(lines):
        if line.rstrip() != marker:
            continue
        body: list[str] = []
        for candidate in lines[index + 1 :]:
            if candidate.strip() and _indent(candidate) <= indent:
                break
            body.append(candidate)
        return "\n".join(body)
    return ""


def _step(job: str, name: str) -> str:
    lines = job.splitlines()
    marker = f"      - name: {name}"
    for index, line in enumerate(lines):
        if line.rstrip() != marker:
            continue
        body = [line]
        for candidate in lines[index + 1 :]:
            if candidate.strip() and _indent(candidate) <= 6:
                break
            body.append(candidate)
        return "\n".join(body)
    return ""


def _top_mapping_keys(block: str, indent: int) -> set[str]:
    keys: set[str] = set()
    prefix = " " * indent
    for line in block.splitlines():
        if not line.startswith(prefix) or _indent(line) != indent:
            continue
        stripped = line.strip()
        if ":" in stripped:
            keys.add(stripped.split(":", maxsplit=1)[0])
    return keys


def validate_contract(files: dict[str, str]) -> list[str]:
    violations: list[str] = []
    manual = files.get("manual", "")
    correctness = files.get("correctness", "")
    exact = files.get("exact", "")
    scale = files.get("scale", "")

    if _top_mapping_keys(_block(manual, "on", 0), 2) != {"workflow_dispatch"}:
        violations.append("manual caller trigger must be workflow_dispatch only")
    if _top_mapping_keys(_block(exact, "on", 0), 2) != {"workflow_call"}:
        violations.append("exact workflow trigger must be workflow_call only")
    if _top_mapping_keys(_block(scale, "on", 0), 2) != {"workflow_call"}:
        violations.append("scale workflow trigger must be workflow_call only")
    if "inputs:" in _block(manual, "workflow_dispatch", 2):
        violations.append("manual evidence caller must not expose dispatch inputs")
    if _top_mapping_keys(_block(manual, "permissions", 0), 2) != {"contents"}:
        violations.append("manual evidence permissions must be contents: read only")
    concurrency = _block(manual, "concurrency", 0)
    if "group: manual-exact-scale-evidence-${{ github.ref }}" not in concurrency:
        violations.append("manual evidence must use its dedicated ref concurrency group")
    if "cancel-in-progress: false" not in concurrency:
        violations.append("manual evidence must preserve in-progress evidence")
    correctness_triggers = _top_mapping_keys(_block(correctness, "on", 0), 2)
    if correctness_triggers != {
        "push",
        "pull_request",
        "workflow_dispatch",
        "workflow_call",
    }:
        violations.append("correctness workflow must retain push/PR/manual and workflow_call triggers")

    correctness_job = _block(manual, "correctness", 2)
    if "uses: ./.github/workflows/correctness.yml" not in correctness_job:
        violations.append("correctness job must call ./.github/workflows/correctness.yml")
    if "with:" in correctness_job or "secrets:" in correctness_job:
        violations.append("correctness call must not add inputs or inherited secrets")

    evidence_jobs = (
        ("exact-matcher", "./.github/workflows/exact-matcher.yml"),
        ("scale-admission", "./.github/workflows/performance-admission.yml"),
    )
    for job_name, reusable_path in evidence_jobs:
        job = _block(manual, job_name, 2)
        if "needs: correctness" not in job:
            violations.append(f"{job_name} job must need correctness")
        if f"uses: {reusable_path}" not in job:
            violations.append(f"{job_name} job must call {reusable_path}")
        if "with:" in job or "secrets:" in job:
            violations.append(f"{job_name} call must not add inputs or inherited secrets")

    smoke = _step(
        _block(scale, "performance-admission", 2),
        "Prepare 1,000-row smoke corpus",
    )
    if "timeout-minutes: 5" not in smoke:
        violations.append("1,000-row prepare step must time out after 5 minutes")
    full = _step(
        _block(scale, "performance-admission", 2),
        "Prepare 5,000-row corpus",
    )
    if "timeout-minutes: 10" not in full:
        violations.append("5,000-row prepare step must time out after 10 minutes")

    scale_job = _block(scale, "performance-admission", 2)
    timed_steps = (
        ("Measure tie-heavy browse-page latency", 45, "tie-heavy browse step"),
        ("Run one Debug exact-search diagnostic probe", 15, "Debug exact-search probe step"),
        ("Measure worst-bound exact search", 90, "worst-bound exact-search step"),
        (
            "Measure independent-process warm persistent open",
            45,
            "warm-open step",
        ),
    )
    for step_name, timeout, label in timed_steps:
        if f"timeout-minutes: {timeout}" not in _step(scale_job, step_name):
            violations.append(f"{label} must time out after {timeout} minutes")

    smoke_gate = _step(scale_job, "Require clean 1,000-row smoke corpus")
    if "if: always()" not in smoke_gate or "validate-smoke" not in smoke_gate:
        violations.append("1,000-row gate must always validate the real smoke phase")
    full_gate = _step(scale_job, "Require clean 5,000-row corpus")
    if (
        "steps.prepare_smoke_gate.outcome == 'success'" not in full_gate
        or "validate-prepare" not in full_gate
    ):
        violations.append("5,000-row gate must require the clean smoke gate")
    probe = _step(scale_job, "Run one Debug exact-search diagnostic probe")
    if (
        "steps.prepare.outcome == 'success'" not in probe
        or "prepare_cleanliness" in probe
    ):
        violations.append("Debug probe must depend on raw prepare completion")
    for step_name in (
        "Measure worst-bound exact search",
        "Measure independent-process warm persistent open",
    ):
        step = _step(scale_job, step_name)
        if (
            "steps.prepare_cleanliness.outcome == 'success'" not in step
            or "steps.exact_search_probe_gate.outcome == 'success'" not in step
        ):
            violations.append(f"{step_name} must require clean prepare and probe gates")

    upload = _step(scale_job, "Upload admission evidence")
    artifact_patterns = (
        "admission-logs/*.json",
        "admission-logs/*.log",
        "admission-logs/*.time",
        "admission-logs/warm-open-samples/*.json",
        "admission-logs/warm-open-samples/*.time",
    )
    if "if: always()" not in upload or not all(
        pattern in upload for pattern in artifact_patterns
    ):
        violations.append("scale evidence upload must always use the explicit artifact allowlist")
    if "path: admission-logs\n" in upload:
        violations.append("scale evidence upload must not recurse over the log root")

    final_gate = _step(scale_job, "Require every scale admission mode")
    required_outcomes = (
        "prepare-smoke",
        "prepare",
        "prepare-cleanliness",
        "exact-search-probe",
        "exact-search-probe-gate",
        "browse-ties",
        "exact-search",
        "warm-open",
        "finalize",
    )
    if "if: always()" not in final_gate or not all(
        outcome in final_gate for outcome in required_outcomes
    ):
        violations.append("final scale gate must require every mode and fixture cardinality")

    if "cancel-in-progress: true" in manual:
        violations.append("manual evidence must not cancel an in-progress evidence run")
    return violations


def main() -> int:
    root = Path(__file__).resolve().parents[1]
    violations = validate_contract(load_contract_files(root))
    if violations:
        for violation in violations:
            print(f"evidence_workflow_gate: error: {violation}", file=sys.stderr)
        return 1
    print("evidence_workflow_gate: OK — manual caller and reusable liveness contract")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
