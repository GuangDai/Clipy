#!/usr/bin/env bash
# XcodeGen generation plus hosted application correctness tests.
set -euo pipefail

if [[ "$#" -ne 5 ]]; then
  echo "usage: run_app_correctness.sh <log-dir> <result-dir> <derived-data> <fixture-root> <xcodegen-home>" >&2
  exit 2
fi

log_dir="$1"
result_dir="$2"
derived_data="$3"
fixture_root="$4"
export XCODEGEN_HOME="$5"
project="ClipyApp/ClipyApp.xcodeproj"

mkdir -p "$log_dir" "$result_dir" "$fixture_root"

bash scripts/generate-xcodeproj.sh \
  2>&1 | tee "$log_dir/xcodegen.log"

bash scripts/fetch_fixtures.sh "$fixture_root"
export CLIPY_FIXTURES_DIR="$fixture_root/clipy-fixtures-v1"
xcodebuild -list -json -project "$project" > "$log_dir/project-list.json"

set -o pipefail
xcodebuild \
  -project "$project" -scheme ClipyApp \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$derived_data" \
  -resultBundlePath "$result_dir/app.xcresult" \
  CODE_SIGNING_ALLOWED=NO \
  test 2>&1 | tee "$log_dir/app-build-test.log"
