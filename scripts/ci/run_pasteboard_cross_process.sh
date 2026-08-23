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

swift build \
  --configuration release \
  --scratch-path "$build_dir" \
  -Xswiftc -enable-testing \
  --build-tests 2>&1 | tee "$log_dir/build.log"
swift build \
  --configuration release \
  --scratch-path "$build_dir" \
  --show-bin-path 2>&1 | tee "$log_dir/bin-path.log"
python3 scripts/diagnostic_scan.py --profile swiftdata \
  "$log_dir/build.log" "$log_dir/bin-path.log"

bin_path="$(tail -n 1 "$log_dir/bin-path.log")"
test_binary="$(find "$bin_path" -type f \
  -path '*/ClipyPackageTests.xctest/Contents/MacOS/ClipyPackageTests' \
  -print -quit)"
if [[ -z "$test_binary" || ! -x "$test_binary" ]]; then
  echo "The Release SwiftPM test host was not produced" >&2
  exit 1
fi
test_bundle="${test_binary%%/Contents/MacOS/*}"

codesign \
  --force --sign - --options runtime --timestamp=none \
  "$test_bundle" 2>&1 | tee "$log_dir/codesign.log"
codesign \
  --verify --strict --verbose=4 \
  "$test_bundle" 2>&1 | tee "$log_dir/codesign-verify.log"
codesign \
  --display --verbose=4 \
  "$test_binary" 2>&1 | tee "$log_dir/codesign-display.log"
if ! grep -Eq 'Signature=adhoc|flags=.*adhoc' \
  "$log_dir/codesign-display.log"; then
  echo "The pasteboard test host is not ad-hoc signed" >&2
  exit 1
fi
if ! grep -Eq 'flags=.*runtime' \
  "$log_dir/codesign-display.log"; then
  echo "The pasteboard test host lacks the Hardened Runtime flag" >&2
  exit 1
fi

CLIPY_GENERAL_PASTEBOARD_PROBE_PHASE=writer \
swift test \
  --configuration release \
  --scratch-path "$build_dir" \
  --skip-build \
  --filter \
  'GeneralPasteboardCrossProcessProbeTests.writerWritesSyntheticBytesThroughAdapter' \
  >"$log_dir/writer.log" 2>&1

# The first test host has fully terminated before a fresh host reads `.general`.
CLIPY_GENERAL_PASTEBOARD_PROBE_PHASE=reader \
swift test \
  --configuration release \
  --scratch-path "$build_dir" \
  --skip-build \
  --filter \
  'GeneralPasteboardCrossProcessProbeTests.nativeReaderByteComparesAfterWriterExit' \
  >"$log_dir/reader.log" 2>&1

python3 scripts/diagnostic_scan.py --profile swiftdata \
  "$log_dir/writer.log" "$log_dir/reader.log"

{
  printf '%s\n' "writer=PasteboardAdapter.write(.general)"
  printf '%s\n' "reader=NSPasteboard.general.data(forType:)"
  printf '%s\n' "processes=2 independent short-lived ad-hoc test hosts"
  printf '%s\n' "comparison=byte-exact synthetic custom type"
  printf '%s\n' "outputs=content-free"
  printf '%s\n' "evidence_ceiling=cross-process General pasteboard visibility in this login session only"
  printf '%s\n' "non_claims=AppIntents,TCC,target-app paste,atomicity,WindowServer"
} | tee "$log_dir/summary.log"

echo "pasteboard cross-process evidence: exact synthetic bytes remained visible after writer exit"
