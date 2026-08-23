#!/usr/bin/env bash
# run_gates.sh — run all Clipy scaffold gates (docs/01-architecture.md Part I §9).
#
#   1. scripts/tests/test_diagnostic_scan.py — CI diagnostic parser fixtures
#   2. scripts/ci/test_apfs_enospc_diagnostics.sh — APFS failure evidence fixture
#   3. scripts/import_gate.py          — per-target import confinement (Part I §8)
#   4. scripts/escape_hatch_scan.py    — no @unchecked Sendable / nonisolated(unsafe)
#                                        / service-locator spellings (Part I §8)
#   5. scripts/vendor_integrity_gate.py — pinned xxHash source byte identity
#   6. scripts/xxh3_symbol_gate.sh      — vendored C symbol confinement
#   7. scripts/public_symbol_snapshot.sh — HistoryCore public symbol surface
#                                        (Part VI §6); macOS + xcrun only, skipped
#                                        elsewhere.
#
# `--source-only` skips the compiled symbol snapshot. CI uses that mode in its
# source job, then runs the snapshot after `swift test` in the SwiftPM job so
# HistoryCore is not compiled twice on separate runners.
#
# All selected gates always run (no early exit) so one invocation reports every
# failure.
# Exit code: 0 = all gates passed (or were platform-skipped), 1 = a gate failed.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
status=0
source_only=0

case "${1:-}" in
    "") ;;
    --source-only) source_only=1 ;;
    *)
        echo "usage: $0 [--source-only]" >&2
        exit 2
        ;;
esac

echo "== gate 1/7: diagnostic scanner fixtures =="
if ! PYTHONPATH="$REPO_ROOT" python3 -m unittest \
    scripts.tests.test_diagnostic_scan; then
    status=1
fi

echo "== gate 2/7: APFS failure diagnostic fixture =="
if ! "$REPO_ROOT/scripts/ci/test_apfs_enospc_diagnostics.sh"; then
    status=1
fi

echo "== gate 3/7: import confinement =="
if ! python3 "$REPO_ROOT/scripts/import_gate.py"; then
    status=1
fi

echo "== gate 4/7: escape-hatch / service-locator scan =="
if ! python3 "$REPO_ROOT/scripts/escape_hatch_scan.py"; then
    status=1
fi

echo "== gate 5/7: vendored dependency integrity =="
if ! python3 "$REPO_ROOT/scripts/vendor_integrity_gate.py"; then
    status=1
fi

echo "== gate 6/7: vendored xxh3 symbol confinement =="
if ! "$REPO_ROOT/scripts/xxh3_symbol_gate.sh"; then
    status=1
fi

echo "== gate 7/7: HistoryCore public symbol snapshot =="
if [[ "$source_only" -eq 1 ]]; then
    echo "run_gates: skipping compiled symbol snapshot (--source-only)"
elif [[ "$(uname -s)" == "Darwin" ]] && command -v xcrun >/dev/null 2>&1; then
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
