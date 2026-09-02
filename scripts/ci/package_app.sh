#!/usr/bin/env bash
# Build one unsigned Release Clipy.app and zip it as a downloadable artifact
# (manual packaging lane). Unsigned by repo policy: CODE_SIGNING_ALLOWED=NO,
# matching run_release_archive.sh — no certificate/signing/notarization
# machinery. A downloaded copy is ad-hoc treated by Gatekeeper: first launch
# via right-click → Open.
set -euo pipefail

if [[ "$#" -ne 4 ]]; then
  echo "usage: package_app.sh <log-dir> <derived-data> <xcodegen-home> <artifacts-dir>" >&2
  exit 2
fi

log_dir="$1"
derived_data="$2"
export XCODEGEN_HOME="$3"
artifacts_dir="$4"
project="ClipyApp/ClipyApp.xcodeproj"
app="$derived_data/Build/Products/Release/Clipy.app"
zip="$artifacts_dir/Clipy-unsigned.zip"

mkdir -p "$log_dir" "$derived_data" "$artifacts_dir"
bash scripts/generate-xcodeproj.sh 2>&1 | tee "$log_dir/xcodegen.log"

# Plain Release build of the ClipyApp scheme: the scheme's build target list
# carries the app alone (test bundles are test-action only), so this produces
# exactly one Clipy.app under the Release products directory.
xcodebuild \
  -project "$project" -scheme ClipyApp \
  -configuration Release -destination 'generic/platform=macOS' \
  -derivedDataPath "$derived_data" \
  CODE_SIGNING_ALLOWED=NO ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
  build 2>&1 | tee "$log_dir/build.log"
python3 scripts/diagnostic_scan.py --profile app "$log_dir/build.log"

if [[ ! -d "$app" ]]; then
  echo "expected app bundle missing: $app" >&2
  exit 1
fi

# ditto's zip keeps the bundle's structure (symlinks, permissions) intact;
# --keepParent stores Clipy.app as the archive's single top-level entry.
ditto -c -k --keepParent "$app" "$zip"
echo "Packaged $zip"
