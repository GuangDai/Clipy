#!/usr/bin/env bash
# Build one Release app, apply local ad-hoc hardened-runtime signatures, and
# exercise the compile-time-only Unix-domain-socket F0 discriminator. This lane
# deliberately proves no Developer ID, sandbox, credential, Gateway, History,
# or clipyctl product behavior.
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
client_build="$derived_data/Build/Products/Release/ClipyUDSF0Client"
client="$app/Contents/Helpers/ClipyUDSF0Client"
endpoint_dir=""
endpoint=""
app_pid=""

cleanup() {
  if [[ -n "$app_pid" ]] && kill -0 "$app_pid" 2>/dev/null; then
    if [[ -x "$client" && -n "$endpoint" ]]; then
      "$client" "$endpoint" --terminate "$app_pid" >/dev/null 2>&1 || \
        kill -TERM "$app_pid" 2>/dev/null || true
    else
      kill -TERM "$app_pid" 2>/dev/null || true
    fi
  fi
  if [[ -n "$endpoint_dir" && "$endpoint_dir" == /tmp/clipy-f0.* ]]; then
    rm -rf -- "$endpoint_dir"
  fi
}
trap cleanup EXIT

require_empty_file() {
  local path="$1"
  if [[ -s "$path" ]]; then
    echo "Expected content-free successful probe stderr at $path" >&2
    exit 1
  fi
}

require_literal_line() {
  local path="$1"
  local expected="$2"
  if ! cmp -s "$path" <(printf '%s\n' "$expected"); then
    echo "Probe output at $path did not match the bounded F0 grammar" >&2
    exit 1
  fi
}

ready_pid=""
ready_euid=""
ready_egid=""
ready_generation=""
parse_ready() {
  local path="$1"
  local line=""
  IFS= read -r line < "$path" || true
  if ! cmp -s "$path" <(printf '%s\n' "$line"); then
    echo "READY output at $path was not exactly one newline-terminated line" >&2
    exit 1
  fi
  if [[ ! "$line" =~ ^READY[[:space:]]pid=([0-9]+)[[:space:]]euid=([0-9]+)[[:space:]]egid=([0-9]+)[[:space:]]generation=([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$ ]]; then
    echo "READY output at $path did not match the bounded F0 grammar" >&2
    exit 1
  fi
  ready_pid="${BASH_REMATCH[1]}"
  ready_euid="${BASH_REMATCH[2]}"
  ready_egid="${BASH_REMATCH[3]}"
  ready_generation="${BASH_REMATCH[4]}"
}

mkdir -p "$log_dir" "$derived_data"
bash scripts/generate-xcodeproj.sh 2>&1 | tee "$log_dir/xcodegen.log"

# CLIPY_UDS_F0 keeps both the listener and diagnostic client out of ordinary
# Release artifacts. The one build invocation produces the app and tool used
# by this evidence run.
xcodebuild \
  -project "$project" -scheme ClipyUDSF0Evidence \
  -configuration Release -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$derived_data" \
  CODE_SIGNING_ALLOWED=NO \
  'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) CLIPY_UDS_F0' \
  build 2>&1 | tee "$log_dir/release-build.log"
python3 scripts/diagnostic_scan.py \
  --profile app "$log_dir/release-build.log"

if [[ ! -x "$executable" ]]; then
  echo "Release application executable was not produced at $executable" >&2
  exit 1
fi
if [[ ! -x "$client_build" ]]; then
  echo "Release F0 client was not produced at $client_build" >&2
  exit 1
fi

mkdir -p "$app/Contents/Helpers"
cp "$client_build" "$client"
chmod 755 "$client"

# Sign the nested diagnostic tool first, then the outer app. Signing deliberately
# avoids --deep; verification may inspect the full nested bundle.
codesign \
  --force --sign - --options runtime --timestamp=none \
  "$client" 2>&1 | tee "$log_dir/codesign-client.log"
codesign \
  --force --sign - --options runtime --timestamp=none \
  "$app" 2>&1 | tee "$log_dir/codesign-app.log"
codesign \
  --verify --strict --verbose=4 \
  "$client" 2>&1 | tee "$log_dir/codesign-client-verify.log"
codesign \
  --verify --deep --strict --verbose=4 \
  "$app" 2>&1 | tee "$log_dir/codesign-verify.log"
codesign \
  --display --verbose=4 \
  "$client" 2>&1 | tee "$log_dir/codesign-client-display.log"
codesign \
  --display --verbose=4 \
  "$app" 2>&1 | tee "$log_dir/codesign-app-display.log"

for display_log in \
  "$log_dir/codesign-client-display.log" \
  "$log_dir/codesign-app-display.log"; do
  if ! grep -Eq 'Signature=adhoc|flags=.*adhoc' "$display_log"; then
    echo "An F0 evidence executable is not ad-hoc signed as required" >&2
    exit 1
  fi
  if ! grep -Eq 'flags=.*runtime' "$display_log"; then
    echo "An F0 evidence executable lacks the Hardened Runtime flag" >&2
    exit 1
  fi
done

codesign \
  --display --entitlements :- \
  "$app" 2>&1 | tee "$log_dir/signed-entitlements.log"
if grep -Eq 'com\.apple\.developer\.(icloud|ubiquity)' \
  "$log_dir/signed-entitlements.log"; then
  echo "The signed app unexpectedly carries an iCloud or ubiquity entitlement" >&2
  exit 1
fi

endpoint_dir="$(mktemp -d /tmp/clipy-f0.XXXXXX)"
endpoint="$endpoint_dir/s"
if [[ "${#endpoint}" -gt 103 ]]; then
  echo "F0 endpoint exceeds the macOS sockaddr_un pathname bound" >&2
  exit 1
fi

if pgrep -x Clipy >/dev/null 2>&1; then
  echo "A Clipy process was already running before the cold-start proof" >&2
  exit 1
fi

# Cold: the client owns LaunchServices startup and bounded reconnect. No shell
# sleep or polling participates in readiness.
"$client" "$endpoint" \
  >"$log_dir/cold-ready.log" 2>"$log_dir/cold-stderr.log"
require_empty_file "$log_dir/cold-stderr.log"
parse_ready "$log_dir/cold-ready.log"
cold_pid="$ready_pid"
cold_euid="$ready_euid"
cold_egid="$ready_egid"
cold_generation="$ready_generation"
app_pid="$cold_pid"
if [[ "$cold_euid" != "$(id -u)" || "$cold_egid" != "$(id -g)" ]]; then
  echo "Cold F0 reply did not report the invoking runner's effective identity" >&2
  exit 1
fi

# Warm: a second diagnostic connection must reach the same process generation.
"$client" "$endpoint" --connect-only \
  >"$log_dir/warm-ready.log" 2>"$log_dir/warm-stderr.log"
require_empty_file "$log_dir/warm-stderr.log"
parse_ready "$log_dir/warm-ready.log"
if [[ "$ready_pid" != "$cold_pid" ||
      "$ready_euid" != "$cold_euid" ||
      "$ready_egid" != "$cold_egid" ||
      "$ready_generation" != "$cold_generation" ]]; then
  echo "Warm F0 connection did not reach the cold-started server generation" >&2
  exit 1
fi

# A deliberately incomplete fixed frame must be closed within the listener's
# deadline without poisoning the sequential accept loop.
"$client" "$endpoint" --half-frame \
  >"$log_dir/half-frame.log" 2>"$log_dir/half-frame-stderr.log"
require_empty_file "$log_dir/half-frame-stderr.log"
require_literal_line "$log_dir/half-frame.log" "HALF_FRAME_CLOSED"
"$client" "$endpoint" --connect-only \
  >"$log_dir/post-half-frame-ready.log" \
  2>"$log_dir/post-half-frame-stderr.log"
require_empty_file "$log_dir/post-half-frame-stderr.log"
parse_ready "$log_dir/post-half-frame-ready.log"
if [[ "$ready_pid" != "$cold_pid" ||
      "$ready_generation" != "$cold_generation" ]]; then
  echo "Listener generation changed after the incomplete-frame discriminator" >&2
  exit 1
fi

# The client sends SIGKILL to the exact server PID, owns the bounded exit wait,
# and succeeds only while the stale socket node is still present.
"$client" "$endpoint" --kill "$cold_pid" \
  >"$log_dir/kill.log" 2>"$log_dir/kill-stderr.log"
require_empty_file "$log_dir/kill-stderr.log"
require_literal_line "$log_dir/kill.log" "KILLED_STALE"
app_pid=""
if [[ ! -S "$endpoint" ]]; then
  echo "SIGKILL did not leave the stale socket required by the recovery proof" >&2
  exit 1
fi

# Cold again: launch must recover the stale endpoint and publish a new process
# generation, after which warm connection remains stable.
"$client" "$endpoint" \
  >"$log_dir/recovery-ready.log" 2>"$log_dir/recovery-stderr.log"
require_empty_file "$log_dir/recovery-stderr.log"
parse_ready "$log_dir/recovery-ready.log"
recovery_pid="$ready_pid"
recovery_generation="$ready_generation"
app_pid="$recovery_pid"
if [[ "$recovery_pid" == "$cold_pid" ||
      "$recovery_generation" == "$cold_generation" ]]; then
  echo "Stale recovery reused the killed process identity or generation" >&2
  exit 1
fi

"$client" "$endpoint" --connect-only \
  >"$log_dir/recovery-warm-ready.log" \
  2>"$log_dir/recovery-warm-stderr.log"
require_empty_file "$log_dir/recovery-warm-stderr.log"
parse_ready "$log_dir/recovery-warm-ready.log"
if [[ "$ready_pid" != "$recovery_pid" ||
      "$ready_generation" != "$recovery_generation" ]]; then
  echo "Recovered listener did not remain stable for a warm connection" >&2
  exit 1
fi

# Normal application termination must remove its exact bound endpoint. The
# client owns the bounded process-exit and pathname-removal waits.
"$client" "$endpoint" --terminate "$recovery_pid" \
  >"$log_dir/terminate.log" 2>"$log_dir/terminate-stderr.log"
require_empty_file "$log_dir/terminate-stderr.log"
require_literal_line "$log_dir/terminate.log" "TERMINATED"
app_pid=""
if [[ -e "$endpoint" ]]; then
  echo "Normal termination left the F0 socket endpoint behind" >&2
  exit 1
fi

echo "signed runtime evidence: ad-hoc nested/outer Hardened Runtime signatures and bounded same-EUID UDS cold/warm/stale-recovery mechanics passed"
