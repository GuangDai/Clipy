#!/usr/bin/env bash
# Build, ad-hoc sign, and execute two independent short-lived processes in the
# same login session. The writer crosses PasteboardAdapter.write(.general); only
# after it exits does the native reader byte-compare one synthetic custom type.
# This is content-free evidence, not an App Intent, TCC, target-app paste,
# atomicity, or WindowServer claim.
set -euo pipefail

if [[ "$#" -ne 2 ]]; then
  echo "usage: run_pasteboard_cross_process.sh <log-dir> <build-dir>" >&2
  exit 2
fi

log_dir="$1"
build_dir="$2"
probe_package="Probes/PasteboardCrossProcess"

mkdir -p "$log_dir" "$build_dir"

swift build \
  --package-path "$probe_package" \
  --configuration release \
  --scratch-path "$build_dir" \
  2>&1 | tee "$log_dir/build.log"
python3 scripts/diagnostic_scan.py --profile swiftdata "$log_dir/build.log"

bin_path="$(swift build \
  --package-path "$probe_package" \
  --configuration release \
  --scratch-path "$build_dir" \
  --show-bin-path)"
writer="$bin_path/ClipyPasteboardWriter"
reader="$bin_path/ClipyPasteboardReader"

for executable in "$writer" "$reader"; do
  if [[ ! -x "$executable" ]]; then
    echo "Pasteboard probe executable was not produced" >&2
    exit 1
  fi

  name="$(basename "$executable")"
  codesign \
    --force --sign - --options runtime --timestamp=none \
    "$executable" 2>&1 | tee "$log_dir/codesign-$name.log"
  codesign \
    --verify --strict --verbose=4 \
    "$executable" 2>&1 | tee "$log_dir/codesign-$name-verify.log"
  codesign \
    --display --verbose=4 \
    "$executable" 2>&1 | tee "$log_dir/codesign-$name-display.log"

  if ! grep -Eq 'Signature=adhoc|flags=.*adhoc' \
    "$log_dir/codesign-$name-display.log"; then
    echo "A pasteboard probe executable is not ad-hoc signed" >&2
    exit 1
  fi
  if ! grep -Eq 'flags=.*runtime' \
    "$log_dir/codesign-$name-display.log"; then
    echo "A pasteboard probe executable lacks the Hardened Runtime flag" >&2
    exit 1
  fi
done

"$writer" >"$log_dir/writer.stdout" 2>"$log_dir/writer.stderr"
if [[ -s "$log_dir/writer.stderr" ]] || \
   ! cmp -s "$log_dir/writer.stdout" <(printf '%s\n' "WRITER_OK"); then
  echo "The pasteboard writer did not produce its content-free success result" >&2
  exit 1
fi

# The writer has fully terminated before this separate executable starts.
"$reader" >"$log_dir/reader.stdout" 2>"$log_dir/reader.stderr"
if [[ -s "$log_dir/reader.stderr" ]] || \
   ! cmp -s "$log_dir/reader.stdout" <(printf '%s\n' "READER_OK"); then
  echo "The pasteboard reader did not produce its content-free success result" >&2
  exit 1
fi

{
  printf '%s\n' "writer=PasteboardAdapter.write(.general)"
  printf '%s\n' "reader=NSPasteboard.general.data(forType:)"
  printf '%s\n' "processes=2 independent short-lived ad-hoc executables"
  printf '%s\n' "comparison=byte-exact synthetic custom type"
  printf '%s\n' "outputs=content-free"
  printf '%s\n' "evidence_ceiling=cross-process General pasteboard visibility in this login session only"
  printf '%s\n' "non_claims=AppIntents,TCC,target-app paste,atomicity,WindowServer"
} | tee "$log_dir/summary.log"

echo "pasteboard cross-process evidence: exact synthetic bytes were visible after the adapter writer exited"
