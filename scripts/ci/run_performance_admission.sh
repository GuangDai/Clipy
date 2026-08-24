#!/usr/bin/env bash
# Run one explicit phase of the manual real-scale admission suite. GitHub
# Actions owns per-phase liveness; `all` remains the local sequential entry.
set -euo pipefail

log_dir="${1:?usage: run_performance_admission.sh <log-dir> <scratch-root> [phase]}"
scratch_root="${2:?usage: run_performance_admission.sh <log-dir> <scratch-root> [phase]}"
phase="${3:-all}"
store_url="$scratch_root/full/store.sqlite"
smoke_store_url="$scratch_root/smoke/store.sqlite"
release_build="$scratch_root/release-build"
debug_build="$scratch_root/debug-build"
samples_dir="$log_dir/warm-open-samples"
mkdir -p "$log_dir" "$(dirname "$store_url")" "$(dirname "$smoke_store_url")"

release_runner_path() {
  local runner
  runner="$(tail -n 1 "$log_dir/bin-path.log")/HistoryPerfRunner"
  [[ -x "$runner" ]]
  printf '%s\n' "$runner"
}

debug_runner_path() {
  local runner
  runner="$(tail -n 1 "$log_dir/debug-bin-path.log")/HistoryPerfRunner"
  [[ -x "$runner" ]]
  printf '%s\n' "$runner"
}

build_runners() {
  {
    sysctl -n hw.model
    sysctl -n machdep.cpu.brand_string
    sysctl -n hw.memsize
  } 2>&1 | tee -a "$log_dir/diagnostics.log"

  swift build -c release --scratch-path "$release_build" \
    --product HistoryPerfRunner 2>&1 | tee "$log_dir/build.log"
  swift build -c release --scratch-path "$release_build" \
    --show-bin-path 2>&1 | tee "$log_dir/bin-path.log"
  release_runner_path >/dev/null

  swift build -c debug --scratch-path "$debug_build" \
    --product HistoryPerfRunner 2>&1 | tee "$log_dir/debug-build.log"
  swift build -c debug --scratch-path "$debug_build" \
    --show-bin-path 2>&1 | tee "$log_dir/debug-bin-path.log"
  debug_runner_path >/dev/null

  python3 scripts/diagnostic_scan.py --profile strict \
    "$log_dir/build.log" "$log_dir/bin-path.log" \
    "$log_dir/debug-build.log" "$log_dir/debug-bin-path.log"
}

prepare_smoke() {
  local release_runner
  release_runner="$(release_runner_path)"
  /usr/bin/time -l -o "$log_dir/seed-smoke.time" \
    "$release_runner" --admission seed-smoke \
    "$smoke_store_url" "$log_dir/prepare-smoke.json" \
    2>&1 | tee "$log_dir/seed-smoke.log"
  /usr/bin/time -l -o "$log_dir/prepare-smoke.time" \
    "$release_runner" --admission prepare-smoke \
    "$smoke_store_url" "$log_dir/prepare-smoke.json" \
    2>&1 | tee "$log_dir/prepare-smoke.log"
}

validate_smoke() {
  python3 scripts/diagnostic_scan.py --profile swiftdata-missing \
    "$log_dir/seed-smoke.log" "$log_dir/prepare-smoke.log"
  jq -e '
    .mode == "prepare-smoke"
    and .corpusRows == 1000
    and .bodyBytesPerRow == 262144
    and .validation.seededRows == "999"
    and .validation.publicValidationCaptures == "2"
    and .validation.seedBatchSize == "64"
    and .validation.seedTransactions == "16"
    and .validation.seedPosition == "16"
    and .validation.position == "18"
  ' "$log_dir/prepare-smoke.json" >/dev/null
}

prepare_full() {
  local release_runner
  release_runner="$(release_runner_path)"
  /usr/bin/time -l -o "$log_dir/seed.time" \
    "$release_runner" --admission seed \
    "$store_url" "$log_dir/prepare.json" \
    2>&1 | tee "$log_dir/seed.log"
  /usr/bin/time -l -o "$log_dir/prepare.time" \
    "$release_runner" --admission prepare \
    "$store_url" "$log_dir/prepare.json" \
    2>&1 | tee "$log_dir/prepare.log"
}

validate_full() {
  python3 scripts/diagnostic_scan.py --profile swiftdata-missing \
    "$log_dir/seed.log" "$log_dir/prepare.log"
  jq -e '
    .mode == "prepare"
    and .corpusRows == 5000
    and .bodyBytesPerRow == 262144
    and .validation.seededRows == "4999"
    and .validation.publicValidationCaptures == "2"
    and .validation.seedBatchSize == "64"
    and .validation.seedTransactions == "79"
    and .validation.seedPosition == "79"
    and .validation.position == "81"
  ' "$log_dir/prepare.json" >/dev/null
}

measure_browse_ties() {
  local release_runner
  release_runner="$(release_runner_path)"
  /usr/bin/time -l -o "$log_dir/browse-ties.time" \
    "$release_runner" --admission browse-ties \
    "$store_url" "$log_dir/browse-ties.json" \
    2>&1 | tee "$log_dir/browse-ties.log"
}

run_exact_search_probe() {
  local debug_runner
  debug_runner="$(debug_runner_path)"
  CLIPY_SEARCH_TRACE=1 CLIPY_STORAGE_TRACE=1 \
    /usr/bin/time -l -o "$log_dir/exact-search-probe.time" \
    "$debug_runner" --admission exact-search-probe \
    "$store_url" "$log_dir/exact-search-probe.json" \
    2>&1 | tee "$log_dir/exact-search-probe.log"
}

validate_exact_search_probe() {
  jq -e '
    .schemaVersion == 1
    and .mode == "exact-search-probe"
    and .evidenceClass == "debug-diagnostic"
    and .buildConfiguration == "debug"
    and .traceEnvironmentEnabled == true
    and .canonicalPercentileEvidence == false
    and .publicRequestCount == 1
    and .corpusRows == 5000
    and .bodyBytesPerRow == 262144
    and .elapsedMs > 0
    and .position > 0
    and .matchedRows == 0
    and .hasNextPage == false
    and .completionMarker == "single-public-exact-search-completed"
    and (has("rawSamplesMs") | not)
    and (has("percentiles") | not)
  ' "$log_dir/exact-search-probe.json" >/dev/null
  local marker
  for marker in \
    '"event":"clipy.storage.lifecycle".*"phase":"startup.fetch.begin"' \
    '"event":"clipy.storage.lifecycle".*"phase":"startup.fetch.complete"' \
    '"event":"clipy.search.trace".*"phase":"entry"' \
    '"event":"clipy.search.trace".*"phase":"complete"'
  do
    grep -E "$marker" "$log_dir/exact-search-probe.log" >/dev/null
  done
}

measure_exact_search() {
  local release_runner
  release_runner="$(release_runner_path)"
  /usr/bin/time -l -o "$log_dir/exact-search.time" \
    "$release_runner" --admission exact-search \
    "$store_url" "$log_dir/exact-search.json" \
    2>&1 | tee "$log_dir/exact-search.log"
}

measure_warm_open() {
  local release_runner
  release_runner="$(release_runner_path)"
  mkdir -p "$samples_dir"
  {
    /usr/bin/time -l -o "$samples_dir/warmup.time" \
      "$release_runner" --admission open-once-and-validate \
      "$store_url" "$samples_dir/000-warmup.json"
    local index sample
    for ((index = 1; index <= 101; index++)); do
      printf -v sample '%03d' "$index"
      /usr/bin/time -l -o "$samples_dir/$sample.time" \
        "$release_runner" --admission open-once \
        "$store_url" "$samples_dir/$sample.json"
    done
    "$release_runner" --admission warm-open \
      "$store_url" "$samples_dir" "$log_dir/warm-open.json"
  } 2>&1 | tee "$log_dir/warm-open.log"
}

summarize_evidence() {
  [[ -n "${GITHUB_STEP_SUMMARY:-}" ]] || return 0
  {
    printf '%s\n\n' "## Performance admission"
    printf '%s\n' "Raw latency samples and machine metadata are in the artifacts."
    local mode
    for mode in seed-smoke prepare-smoke seed prepare browse-ties exact-search-probe exact-search; do
      local time_file="$log_dir/$mode.time"
      [[ -f "$time_file" ]] || continue
      local rss
      rss="$(awk '/maximum resident set size/ {print $1}' "$time_file")"
      printf -- '- %s maximum resident set size: %s bytes\n' \
        "$mode" "${rss:-unavailable}"
    done
    shopt -s nullglob
    local warm_time_files=("$samples_dir"/[0-9][0-9][0-9].time)
    local warm_rss=""
    if [[ "${#warm_time_files[@]}" -gt 0 ]]; then
      warm_rss="$(awk '
        /maximum resident set size/ {
          if ($1 > maximum) maximum = $1
        }
        END { if (maximum > 0) print maximum }
      ' "${warm_time_files[@]}")"
    fi
    printf -- '- warm-open maximum child RSS: %s bytes\n' \
      "${warm_rss:-unavailable}"
  } >> "$GITHUB_STEP_SUMMARY"
}

scan_evidence_logs() {
  shopt -s nullglob
  local logs=("$log_dir"/*.log)
  [[ "${#logs[@]}" -gt 0 ]]
  python3 scripts/diagnostic_scan.py --profile swiftdata "${logs[@]}"
}

finalize_evidence() {
  jq -e '
    .mode == "browse-ties"
    and (.rawSamplesMs | length) == 101
    and .percentiles.p50Ms > 0
    and .percentiles.p95Ms > 0
    and .percentiles.p99Ms > 0
  ' "$log_dir/browse-ties.json" >/dev/null
  jq -e '
    .mode == "exact-search"
    and (.rawSamplesMs | length) == 11
    and .percentiles.p50Ms > 0
    and .percentiles.p95Ms == null
    and .percentiles.p99Ms == null
  ' "$log_dir/exact-search.json" >/dev/null
  jq -e '
    .mode == "warm-open"
    and (.rawSamplesMs | length) == 101
    and .percentiles.p50Ms > 0
    and .percentiles.p95Ms > 0
    and .percentiles.p99Ms > 0
  ' "$log_dir/warm-open.json" >/dev/null

  local mode
  for mode in seed-smoke prepare-smoke seed prepare browse-ties exact-search-probe exact-search; do
    [[ -s "$log_dir/$mode.time" ]]
  done
  shopt -s nullglob
  local warm_time_files=("$samples_dir"/[0-9][0-9][0-9].time)
  [[ -s "$samples_dir/warmup.time" ]]
  [[ "${#warm_time_files[@]}" -eq 101 ]]
  local time_file
  for time_file in "${warm_time_files[@]}"; do
    [[ -s "$time_file" ]]
  done
}

run_all() {
  build_runners
  prepare_smoke
  validate_smoke
  prepare_full
  validate_full
  measure_browse_ties
  run_exact_search_probe
  validate_exact_search_probe
  measure_exact_search
  measure_warm_open
  summarize_evidence
  scan_evidence_logs
  finalize_evidence
}

case "$phase" in
  build) build_runners ;;
  prepare-smoke) prepare_smoke ;;
  validate-smoke) validate_smoke ;;
  prepare) prepare_full ;;
  validate-prepare) validate_full ;;
  browse-ties) measure_browse_ties ;;
  exact-search-probe) run_exact_search_probe ;;
  validate-exact-search-probe) validate_exact_search_probe ;;
  exact-search) measure_exact_search ;;
  warm-open) measure_warm_open ;;
  summarize) summarize_evidence ;;
  scan) scan_evidence_logs ;;
  finalize) finalize_evidence ;;
  all) run_all ;;
  *)
    printf '%s\n' \
      "unknown performance-admission phase: $phase" \
      "expected build|prepare-smoke|validate-smoke|prepare|validate-prepare|browse-ties|exact-search-probe|validate-exact-search-probe|exact-search|warm-open|summarize|scan|finalize|all" \
      >&2
    exit 2
    ;;
esac
