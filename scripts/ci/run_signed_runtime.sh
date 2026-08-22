#!/usr/bin/env bash
# Build one Release app, apply a local ad-hoc hardened-runtime signature, and
# exercise only the process lifecycle that a hosted macOS runner can observe.
set -euo pipefail

if [[ "$#" -ne 3 ]]; then
  echo "usage: run_signed_runtime.sh <log-dir> <derived-data> <xcodegen-home>" >&2
  exit 2
fi

log_dir="$1"
derived_data="$2"
export XCODEGEN_HOME="$3"
project="ClipyApp/ClipyApp.xcodeproj"
app="$derived_data/Build/Products/Release/Clipy.app"
executable="$app/Contents/MacOS/Clipy"
app_pid=""

cleanup() {
  if [[ -n "$app_pid" ]] && kill -0 "$app_pid" 2>/dev/null; then
    kill -TERM "$app_pid"
    wait "$app_pid" 2>/dev/null || true
  fi
}
trap cleanup EXIT

mkdir -p "$log_dir" "$derived_data"
bash scripts/generate-xcodeproj.sh 2>&1 | tee "$log_dir/xcodegen.log"

xcodebuild \
  -project "$project" -scheme ClipyApp \
  -configuration Release -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$derived_data" \
  CODE_SIGNING_ALLOWED=NO \
  build 2>&1 | tee "$log_dir/release-build.log"
python3 scripts/diagnostic_scan.py \
  --profile app "$log_dir/release-build.log"

if [[ ! -x "$executable" ]]; then
  echo "Release application executable was not produced at $executable" >&2
  exit 1
fi

# This intentionally proves only a local ad-hoc signature and the Hardened
# Runtime code-directory flag. It is not Developer ID signing, timestamping,
# notarization, stapling, or Gatekeeper acceptance (review Card 16B).
codesign \
  --force --sign - --options runtime --timestamp=none \
  "$app" 2>&1 | tee "$log_dir/codesign.log"
codesign \
  --verify --deep --strict --verbose=4 \
  "$app" 2>&1 | tee "$log_dir/codesign-verify.log"
codesign \
  --display --verbose=4 \
  "$app" 2>&1 | tee "$log_dir/codesign-display.log"

if ! grep -Eq 'Signature=adhoc|flags=.*adhoc' "$log_dir/codesign-display.log"; then
  echo "The Release app is not ad-hoc signed as this evidence lane requires" >&2
  exit 1
fi
if ! grep -Eq 'flags=.*runtime' "$log_dir/codesign-display.log"; then
  echo "The Release app signature does not carry the Hardened Runtime flag" >&2
  exit 1
fi

codesign \
  --display --entitlements :- \
  "$app" 2>&1 | tee "$log_dir/signed-entitlements.log"
if grep -Eq 'com\.apple\.developer\.(icloud|ubiquity)' \
  "$log_dir/signed-entitlements.log"; then
  echo "The signed app unexpectedly carries an iCloud or ubiquity entitlement" >&2
  exit 1
fi

# Direct execution avoids claiming LaunchServices, login-item, TCC, status-item,
# Carbon hotkey, Space, or WindowServer behavior. Remaining alive for this short
# interval proves only that the signed Release process launches and stays alive.
"$executable" >"$log_dir/launch.log" 2>&1 &
app_pid="$!"
sleep 3
if ! kill -0 "$app_pid" 2>/dev/null; then
  set +e
  wait "$app_pid"
  launch_status="$?"
  set -e
  app_pid=""
  echo "Signed Release process exited before the lifecycle checkpoint (status $launch_status)" >&2
  exit 1
fi

kill -TERM "$app_pid"
set +e
wait "$app_pid"
launch_status="$?"
set -e
app_pid=""
if [[ "$launch_status" -ne 0 && "$launch_status" -ne 143 ]]; then
  echo "Signed Release process ended with unexpected status $launch_status" >&2
  exit 1
fi

echo "signed runtime evidence: ad-hoc Release signature, runtime flag, entitlement gate, and process-alive lifecycle passed"
