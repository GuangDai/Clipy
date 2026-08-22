#!/usr/bin/env bash
# Portable/source correctness plus macOS SwiftLint and symbol evidence.
set -euo pipefail

log_dir="${1:?usage: run_source_gates.sh <log-dir>}"
mkdir -p "$log_dir"

bash scripts/run_gates.sh --source-only 2>&1 | tee "$log_dir/source-gates.log"

if ! command -v swiftlint >/dev/null 2>&1; then
  brew install swiftlint
fi
swiftlint version
swiftlint lint --quiet --strict --no-cache \
  2>&1 | tee "$log_dir/swiftlint.log"
python3 scripts/diagnostic_scan.py --profile strict \
  "$log_dir/swiftlint.log"
