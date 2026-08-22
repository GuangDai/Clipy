#!/usr/bin/env bash
# Run one dormant performance helper/proof suite when a future caller enables it.
set -euo pipefail

suite="${1:?usage: run_performance_proofs.sh <helpers|proofs> <log-dir>}"
log_dir="${2:?usage: run_performance_proofs.sh <helpers|proofs> <log-dir>}"
mkdir -p "$log_dir"

case "$suite" in
  helpers)
    swift test --filter 'HistoryPerfTests\.' \
      2>&1 | tee "$log_dir/perf-test.log"
    python3 scripts/diagnostic_scan.py --profile strict \
      "$log_dir/perf-test.log"
    ;;
  proofs)
    swift build -c release 2>&1 | tee "$log_dir/perf-build.log"
    python3 scripts/diagnostic_scan.py --profile strict \
      "$log_dir/perf-build.log"
    swift run -c release --skip-build HistoryPerfRunner \
      "$log_dir/perf-fixtures.json" \
      2>&1 | tee "$log_dir/perf-run.log"
    python3 scripts/diagnostic_scan.py --profile strict \
      "$log_dir/perf-run.log"
    ;;
  *)
    echo "unknown performance suite: $suite" >&2
    exit 2
    ;;
esac
