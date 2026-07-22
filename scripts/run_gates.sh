#!/usr/bin/env bash
# run_gates.sh — run all Clipy scaffold gates (docs/01-architecture.md Part I §9).
#
#   1. scripts/import_gate.py          — per-target import confinement (Part I §8)
#   2. scripts/escape_hatch_scan.py    — no @unchecked Sendable / nonisolated(unsafe)
#                                        / service-locator spellings (Part I §8)
#   3. scripts/public_symbol_snapshot.sh — HistoryCore public symbol surface
#                                        (Part VI §6); macOS + xcrun only, skipped
#                                        elsewhere.
#
# All gates always run (no early exit) so one invocation reports every failure.
# Exit code: 0 = all gates passed (or were platform-skipped), 1 = a gate failed.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
status=0

echo "== gate 1/3: import confinement =="
if ! python3 "$REPO_ROOT/scripts/import_gate.py"; then
    status=1
fi

echo "== gate 2/3: escape-hatch / service-locator scan =="
if ! python3 "$REPO_ROOT/scripts/escape_hatch_scan.py"; then
    status=1
fi

echo "== gate 3/3: HistoryCore public symbol snapshot =="
if [[ "$(uname -s)" == "Darwin" ]] && command -v xcrun >/dev/null 2>&1; then
    if ! "$REPO_ROOT/scripts/public_symbol_snapshot.sh"; then
        status=1
    fi
else
    echo "run_gates: skipping public_symbol_snapshot.sh (requires macOS with xcrun)"
fi

if [[ "$status" -eq 0 ]]; then
    echo "run_gates: all gates passed"
else
    echo "run_gates: FAILED — one or more gates failed" >&2
fi
exit "$status"
