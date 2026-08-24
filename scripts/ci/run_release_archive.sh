#!/usr/bin/env bash
# Build and validate one unsigned ordinary Clipy.xcarchive (Card 16A only).
set -euo pipefail

if [[ "$#" -ne 6 ]]; then
  echo "usage: run_release_archive.sh <log-dir> <archive> <derived-data> <xcodegen-home> <release-ref> <ref-protected>" >&2
  exit 2
fi

log_dir="$1"
archive="$2"
derived_data="$3"
export XCODEGEN_HOME="$4"
release_ref="$5"
ref_protected="$6"
project="ClipyApp/ClipyApp.xcodeproj"
settings="$log_dir/build-settings.json"

mkdir -p "$log_dir" "$derived_data"
bash scripts/generate-xcodeproj.sh 2>&1 | tee "$log_dir/xcodegen.log"

xcodebuild \
  -project "$project" -scheme ClipyApp \
  -configuration Release -destination 'generic/platform=macOS' \
  -archivePath "$archive" -derivedDataPath "$derived_data" \
  CODE_SIGNING_ALLOWED=NO ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
  archive 2>&1 | tee "$log_dir/archive.log"
python3 scripts/diagnostic_scan.py --profile app "$log_dir/archive.log"

xcodebuild \
  -project "$project" -target ClipyApp \
  -configuration Release -destination 'generic/platform=macOS' \
  CODE_SIGNING_ALLOWED=NO ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
  -showBuildSettings -json > "$settings"

python3 scripts/ci/validate_release_archive.py \
  --archive "$archive" \
  --build-settings "$settings" \
  --release-ref "$release_ref" \
  --ref-protected "$ref_protected" \
  2>&1 | tee "$log_dir/archive-validation.log"
