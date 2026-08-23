#!/usr/bin/env bash
# Build and inspect one ordinary Release Clipy.app for the finite Card 5D
# forbidden-symbol inventory. This proves only absence from this exact ad-hoc
# signed artifact; it is not a complete instrumentation or distribution audit.
set -euo pipefail

if [[ "$#" -ne 3 ]]; then
  echo "usage: run_release_surface.sh <log-dir> <derived-data> <xcodegen-home>" >&2
  exit 2
fi

log_dir="$1"
derived_data="$2"
export XCODEGEN_HOME="$3"
project="ClipyApp/ClipyApp.xcodeproj"
app="$derived_data/Build/Products/Release/Clipy.app"
executable="$app/Contents/MacOS/Clipy"
info_plist="$app/Contents/Info.plist"
inventory="scripts/ci/release-forbidden-symbols.txt"
symbol_work="$(mktemp -d)"

cleanup() {
  rm -rf -- "$symbol_work"
}
trap cleanup EXIT

mkdir -p "$log_dir" "$derived_data"

bash scripts/generate-xcodeproj.sh \
  2>&1 | tee "$log_dir/xcodegen.log"
python3 scripts/diagnostic_scan.py \
  --profile app "$log_dir/xcodegen.log"

# The normal ClipyApp scheme excludes the F0 client target. Clearing active
# compilation conditions also prevents the proof-only listener from entering
# this artifact even if a caller environment happens to define the flag.
xcodebuild \
  -project "$project" -scheme ClipyApp \
  -configuration Release -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$derived_data" \
  CODE_SIGNING_ALLOWED=NO \
  SWIFT_ACTIVE_COMPILATION_CONDITIONS= \
  build 2>&1 | tee "$log_dir/release-build.log"
python3 scripts/diagnostic_scan.py \
  --profile app "$log_dir/release-build.log"

if [[ ! -x "$executable" || ! -f "$info_plist" ]]; then
  echo "Ordinary Release Clipy.app was not produced at $app" >&2
  exit 1
fi
if [[ ! -s "$inventory" ]]; then
  echo "Release forbidden-symbol inventory is missing or empty" >&2
  exit 1
fi
if find "$app" -name ClipyUDSF0Client -print -quit | grep -q .; then
  echo "Ordinary Release artifact unexpectedly contains the F0 client" >&2
  exit 1
fi

bundle_identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info_plist")"
bundle_executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$info_plist")"
bundle_package_type="$(/usr/libexec/PlistBuddy -c 'Print :CFBundlePackageType' "$info_plist")"
bundle_is_agent="$(/usr/libexec/PlistBuddy -c 'Print :LSUIElement' "$info_plist")"
if [[ "$bundle_identifier" != "com.clipy.ClipyApp" ||
      "$bundle_executable" != "Clipy" ||
      "$bundle_package_type" != "APPL" ||
      "$bundle_is_agent" != "true" ]]; then
  echo "Release artifact identity does not match the ClipyApp contract" >&2
  exit 1
fi

# Give this exact ordinary artifact a local ad-hoc Hardened Runtime signature.
# This does not establish Developer ID identity, timestamping, notarization,
# stapling, Gatekeeper acceptance, or any interactive runtime behavior.
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
  echo "Release surface artifact is not ad-hoc signed" >&2
  exit 1
fi
if ! grep -Eq 'flags=.*runtime' "$log_dir/codesign-display.log"; then
  echo "Release surface artifact lacks the Hardened Runtime flag" >&2
  exit 1
fi

raw_symbols="$symbol_work/raw-symbols.txt"
demangled_symbols="$symbol_work/demangled-symbols.txt"
nm_stderr="$symbol_work/nm.stderr"
demangle_stderr="$symbol_work/swift-demangle.stderr"
: > "$raw_symbols"
: > "$nm_stderr"
: > "$log_dir/mach-o-files.log"

mach_o_count=0
while IFS= read -r -d '' candidate; do
  if [[ "$(file -b "$candidate")" != *Mach-O* ]]; then
    continue
  fi
  relative_path="${candidate#"$app"/}"
  printf '%s\n' "$relative_path" >> "$log_dir/mach-o-files.log"
  xcrun nm -jU "$candidate" >> "$raw_symbols" 2>> "$nm_stderr"
  mach_o_count=$((mach_o_count + 1))
done < <(find "$app/Contents" -type f -print0)

if [[ "$mach_o_count" -eq 0 || ! -s "$raw_symbols" ]]; then
  echo "No inspectable defined symbols were found in the Release app" >&2
  exit 1
fi
if [[ -s "$nm_stderr" ]]; then
  echo "nm emitted diagnostics while inspecting the Release app" >&2
  exit 1
fi

xcrun swift-demangle \
  < "$raw_symbols" > "$demangled_symbols" 2> "$demangle_stderr"
if [[ -s "$demangle_stderr" ]]; then
  echo "swift-demangle emitted diagnostics while inspecting the Release app" >&2
  exit 1
fi

match_report="$log_dir/forbidden-symbol-matches.log"
: > "$match_report"
inventory_count=0
while IFS= read -r forbidden || [[ -n "$forbidden" ]]; do
  if [[ -z "$forbidden" || "$forbidden" == \#* ]]; then
    continue
  fi
  inventory_count=$((inventory_count + 1))
  grep -F "$forbidden" "$demangled_symbols" >> "$match_report" || true
done < "$inventory"

if [[ "$inventory_count" -eq 0 ]]; then
  echo "Release forbidden-symbol inventory contains no reviewed entries" >&2
  exit 1
fi
if [[ -s "$match_report" ]]; then
  echo "The ordinary Release app contains a reviewed DEBUG/test-hook symbol" >&2
  exit 1
fi

{
  printf 'artifact=%s\n' "Clipy.app"
  printf 'bundle_identifier=%s\n' "$bundle_identifier"
  printf 'configuration=%s\n' "Release"
  printf 'signature=%s\n' "ad-hoc hardened runtime"
  printf 'mach_o_files=%s\n' "$mach_o_count"
  printf 'reviewed_forbidden_literals=%s\n' "$inventory_count"
  printf 'matches=%s\n' "0"
  printf '%s\n' "evidence_ceiling=Card 5D signed Release symbol subleaf only"
} | tee "$log_dir/release-surface-summary.log"

echo "release surface evidence: reviewed forbidden symbols are absent from the exact ordinary ad-hoc Release app"
