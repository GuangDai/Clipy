#!/usr/bin/env bash
# One functional SwiftPM test build, followed by the incremental API snapshot.
set -euo pipefail

log_dir="${1:?usage: run_spm_correctness.sh <log-dir> <fixture-root>}"
fixture_root="${2:?usage: run_spm_correctness.sh <log-dir> <fixture-root>}"
mkdir -p "$log_dir" "$fixture_root"

bash scripts/fetch_fixtures.sh "$fixture_root"
export CLIPY_FIXTURES_DIR="$fixture_root/clipy-fixtures-v1"

swift test --skip 'HistoryPerfTests\.' \
  2>&1 | tee "$log_dir/spm-test.log"
bash scripts/public_symbol_snapshot.sh \
  2>&1 | tee "$log_dir/public-symbol-snapshot.log"

python3 scripts/diagnostic_scan.py --profile swiftdata \
  "$log_dir/spm-test.log"
python3 scripts/diagnostic_scan.py --profile strict \
  "$log_dir/public-symbol-snapshot.log"
