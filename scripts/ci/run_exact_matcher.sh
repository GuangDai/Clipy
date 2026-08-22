#!/usr/bin/env bash
# Build and run the dormant reusable/local exact matcher evidence suite.
set -euo pipefail

log_dir="${1:?usage: run_exact_matcher.sh <log-dir> <scratch-root>}"
scratch_root="${2:?usage: run_exact_matcher.sh <log-dir> <scratch-root>}"
mkdir -p "$log_dir" "$scratch_root"

build_root="$scratch_root/build"
swift build -c release --scratch-path "$build_root" \
  --product HistoryPerfRunner 2>&1 | tee "$log_dir/build.log"
swift build -c release --scratch-path "$build_root" \
  --show-bin-path 2>&1 | tee "$log_dir/bin-path.log"
runner="$(tail -n 1 "$log_dir/bin-path.log")/HistoryPerfRunner"
[[ -x "$runner" ]]

"$runner" --admission exact-matcher-ab \
  "$scratch_root/unused-store.sqlite" \
  "$log_dir/exact-matcher-ab.json" \
  2>&1 | tee "$log_dir/exact-matcher-ab.log"

jq -e '
  .schemaVersion == 2
  and .mode == "exact-matcher-ab"
  and .evidenceClass == "release-matcher-ab-record-only"
  and .bodiesPerSample == 128
  and .bodyBytes == 262144
  and .warmupCount == 2
  and .sampleCount == 11
  and .constructionsPerSample == 256
  and (.scopeLimitations | length) == 3
  and (.cases | length) == 13
  and ([.cases[].name] | sort) == [
    "absent-needle-1",
    "absent-needle-64",
    "admission-absent-48",
    "early-hit-16",
    "high-entropy-absent-10",
    "late-cr-fallback",
    "late-hit-16",
    "late-unicode-fallback",
    "middle-hit-16",
    "repeated-prefix-4096",
    "source-absent-16",
    "source-common-hit-4",
    "unicode-needle-fallback"
  ]
  and ([.cases[].name] | unique | length) == 13
  and all(.cases[];
    (.foundationRawSamplesMs | length) == 11
    and (.compiledRawSamplesMs | length) == 11
    and (.pairedRawRatios | length) == 11
    and (.compiledConstructionRawSamplesMs | length) == 11
    and all(.foundationRawSamplesMs[]; . > 0)
    and all(.compiledRawSamplesMs[]; . > 0)
    and all(.pairedRawRatios[]; . > 0)
    and all(.compiledConstructionRawSamplesMs[]; . > 0)
    and .foundationMedianMs > 0
    and .compiledMedianMs > 0
    and .compiledToFoundationRatio > 0
    and .pairedMedianRatio > 0
    and .pairedP25Ratio > 0
    and .pairedP75Ratio > 0
    and .pairedP25Ratio <= .pairedMedianRatio
    and .pairedMedianRatio <= .pairedP75Ratio
    and .compiledConstructionMedianMs > 0
    and .maximumPairedMedianRatio > 0
    and (.passesDecisionThreshold
      == (.pairedMedianRatio <= .maximumPairedMedianRatio))
    and (((.compiledToFoundationRatio
      - (.compiledMedianMs / .foundationMedianMs)) | fabs)
      < 0.000000001)
    and .logicalBytesPerSample == (.bodiesPerSample * 262144)
    and .bodiesPerSample >= 2
    and .bodiesPerSample <= 128)
  and (.productionIntegrationEligible
    == all(.cases[]; .passesDecisionThreshold))
' "$log_dir/exact-matcher-ab.json" >/dev/null
python3 scripts/diagnostic_scan.py --profile strict "$log_dir"/*.log

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  {
    echo "## Exact matcher Release A/B"
    echo
    echo "Record-only paired compiled/Foundation ratios; lower is better."
    jq -r \
      '.cases[] | "- \(.name): \(.pairedMedianRatio)x (limit \(.maximumPairedMedianRatio), pass=\(.passesDecisionThreshold))"' \
      "$log_dir/exact-matcher-ab.json"
    echo
    jq -r \
      '"Production-integration screening result: \(.productionIntegrationEligible)"' \
      "$log_dir/exact-matcher-ab.json"
  } >> "$GITHUB_STEP_SUMMARY"
fi
