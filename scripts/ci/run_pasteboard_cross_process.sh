#!/usr/bin/env bash
# Build and ad-hoc sign the existing PasteboardAdapterTests host, then launch
# it twice in one login session: adapter writer first, native reader second.
# This is content-free evidence for that exact cross-process visibility leaf,
# not App Intents, TCC, target-app paste, atomicity, or WindowServer evidence.
set -euo pipefail

if [[ "$#" -ne 2 ]]; then
  echo "usage: run_pasteboard_cross_process.sh <log-dir> <build-dir>" >&2
  exit 2
fi

log_dir="$1"
build_dir="$2"
mkdir -p "$log_dir" "$build_dir"

probe_log="$log_dir/probe-phases.log"
current_phase="setup"
marker_dir="$(mktemp -d "$log_dir/phase-markers.XXXXXX")"

probe() {
  printf '[CLIPY_PB_XPROC] %s\n' "$*" | tee -a "$probe_log"
}

finish() {
  local status="$?"
  trap - EXIT
  probe "boundary=script-exit phase=$current_phase exit_status=$status"
  exit "$status"
}
trap finish EXIT

run_logged_phase() {
  local phase="$1"
  local output="$2"
  shift 2
  current_phase="$phase"
  probe "boundary=phase phase=$phase event=start"
  set +e
  "$@" 2>&1 | tee "$output"
  local pipeline_statuses=("${PIPESTATUS[@]}")
  local command_status="${pipeline_statuses[0]}"
  local tee_status="${pipeline_statuses[1]}"
  local status="$command_status"
  if [[ "$status" -eq 0 && "$tee_status" -ne 0 ]]; then
    status="$tee_status"
  fi
  set -e
  probe "boundary=phase phase=$phase event=end exit_status=$status command_exit_status=$command_status tee_exit_status=$tee_status"
  return "$status"
}

session_id="$(ps -o sess= -p "$$" | tr -d '[:space:]')"
probe "boundary=script-process pid=$$ ppid=$PPID session_id=${session_id:-unknown} uid=$(id -u)"
probe "boundary=configuration swift_configuration=debug evidence_host=test-only"

# This proof needs a non-shipping test host, not Release product semantics.
# Debug also preserves repository-owned DEBUG-only test probes that the
# aggregate SwiftPM test target references (observed in run 32621668622).
run_logged_phase build "$log_dir/build.log" swift build \
  --configuration debug \
  --scratch-path "$build_dir" \
  --build-tests
run_logged_phase bin-path "$log_dir/bin-path.log" swift build \
  --configuration debug \
  --scratch-path "$build_dir" \
  --show-bin-path
run_logged_phase build-diagnostic-scan \
  "$log_dir/build-diagnostic-scan.log" \
  python3 scripts/diagnostic_scan.py --profile swiftdata \
  "$log_dir/build.log" "$log_dir/bin-path.log"

bin_path="$(tail -n 1 "$log_dir/bin-path.log")"
test_binary="$(find "$bin_path" -type f \
  -path '*/ClipyPackageTests.xctest/Contents/MacOS/ClipyPackageTests' \
  -print -quit)"
if [[ -z "$test_binary" || ! -x "$test_binary" ]]; then
  probe "boundary=test-host-inventory result=missing bin_path=$bin_path"
  echo "The Debug SwiftPM test host was not produced" >&2
  exit 1
fi
test_bundle="${test_binary%%/Contents/MacOS/*}"
probe "boundary=test-host-inventory result=found binary=$test_binary bundle=$test_bundle"
info_plist="$test_bundle/Contents/Info.plist"

test_host_inventory() {
  set -e
  printf 'bin_path=%s\n' "$bin_path"
  printf 'test_bundle=%s\n' "$test_bundle"
  printf 'test_binary=%s\n' "$test_binary"
  file "$test_binary"
  stat -f 'binary_mode=%Sp binary_size=%z binary_owner=%Su binary_group=%Sg' \
    "$test_binary"
  if [[ -f "$info_plist" ]]; then
    probe "boundary=test-host-inventory info_plist=present"
    plutil -p "$info_plist"
  else
    # SwiftPM's command-line `.xctest` bundle need not contain an Info.plist.
    # Run 32623507717 observed exactly that bundle shape; inventory records it
    # without aborting before discovery, signing, writer, or reader execution.
    probe "boundary=test-host-inventory info_plist=absent expected_for_swiftpm=true"
  fi
  otool -L "$test_binary"
}

run_logged_phase test-host-inventory "$log_dir/test-host-inventory.log" \
  test_host_inventory

run_logged_phase test-discovery "$log_dir/test-discovery.log" swift test list \
  --configuration debug \
  --scratch-path "$build_dir" \
  --skip-build
for discovered_test in \
  'GeneralPasteboardCrossProcessProbeTests/writerWritesSyntheticBytesThroughAdapter' \
  'GeneralPasteboardCrossProcessProbeTests/nativeReaderByteComparesAfterWriterExit'
do
  if ! grep -Fq "$discovered_test" "$log_dir/test-discovery.log"; then
    probe "boundary=test-discovery result=missing test=$discovered_test"
    exit 1
  fi
  probe "boundary=test-discovery result=found test=$discovered_test"
done

run_logged_phase codesign "$log_dir/codesign.log" codesign \
  --force --sign - --options runtime --timestamp=none \
  "$test_bundle"
run_logged_phase codesign-verify "$log_dir/codesign-verify.log" codesign \
  --verify --strict --verbose=4 \
  "$test_bundle"
run_logged_phase codesign-display "$log_dir/codesign-display.log" codesign \
  --display --verbose=4 \
  "$test_binary"
if ! grep -Eq 'Signature=adhoc|flags=.*adhoc' \
  "$log_dir/codesign-display.log"; then
  probe "boundary=codesign-policy result=missing-adhoc"
  echo "The pasteboard test host is not ad-hoc signed" >&2
  exit 1
fi
if ! grep -Eq 'flags=.*runtime' \
  "$log_dir/codesign-display.log"; then
  probe "boundary=codesign-policy result=missing-runtime"
  echo "The pasteboard test host lacks the Hardened Runtime flag" >&2
  exit 1
fi
probe "boundary=codesign-policy result=adhoc-hardened-runtime"

run_logged_phase writer "$log_dir/writer.log" env \
  CLIPY_GENERAL_PASTEBOARD_PROBE_PHASE=writer \
  CLIPY_GENERAL_PASTEBOARD_PROBE_MARKER_DIR="$marker_dir" swift test \
  --configuration debug \
  --scratch-path "$build_dir" \
  --skip-build \
  --filter \
  'GeneralPasteboardCrossProcessProbeTests/writerWritesSyntheticBytesThroughAdapter'
if [[ ! -f "$marker_dir/writer.passed" ]] || \
   ! grep -Fq '[CLIPY_PB_XPROC] phase=writer boundary=passed-marker result=written' \
     "$log_dir/writer.log"; then
  probe "boundary=writer-launch result=missing-passed-marker"
  exit 1
fi
probe "boundary=writer-launch result=exited-zero"

# The first test host has fully terminated before a fresh host reads `.general`.
run_logged_phase reader "$log_dir/reader.log" env \
  CLIPY_GENERAL_PASTEBOARD_PROBE_PHASE=reader \
  CLIPY_GENERAL_PASTEBOARD_PROBE_MARKER_DIR="$marker_dir" swift test \
  --configuration debug \
  --scratch-path "$build_dir" \
  --skip-build \
  --filter \
  'GeneralPasteboardCrossProcessProbeTests/nativeReaderByteComparesAfterWriterExit'
if [[ ! -f "$marker_dir/reader.passed" ]] || \
   ! grep -Fq '[CLIPY_PB_XPROC] phase=reader boundary=passed-marker result=written' \
     "$log_dir/reader.log"; then
  probe "boundary=reader-launch result=missing-passed-marker"
  exit 1
fi
probe "boundary=reader-launch result=exited-zero"

run_logged_phase probe-diagnostic-scan \
  "$log_dir/probe-diagnostic-scan.log" \
  python3 scripts/diagnostic_scan.py --profile swiftdata \
  "$log_dir/writer.log" "$log_dir/reader.log"

{
  printf '%s\n' "writer=PasteboardAdapter.write(.general)"
  printf '%s\n' "reader=NSPasteboard.general.data(forType:)"
  printf '%s\n' "configuration=Debug test-only host"
  printf '%s\n' "processes=2 independent short-lived ad-hoc test hosts"
  printf '%s\n' "execution_guard=phase-specific passed marker from each test host"
  printf '%s\n' "comparison=byte-exact synthetic custom type"
  printf '%s\n' "outputs=content-free"
  printf '%s\n' "evidence_ceiling=cross-process General pasteboard visibility in this login session only"
  printf '%s\n' "non_claims=AppIntents,TCC,target-app paste,atomicity,WindowServer"
} | tee "$log_dir/summary.log"

current_phase="complete"
echo "pasteboard cross-process evidence: exact synthetic bytes remained visible after writer exit"
