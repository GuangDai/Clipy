#!/usr/bin/env bash
# XcodeGen generation plus hosted/UI tests, optionally one of four GUI shards.
set -euo pipefail

if [[ "$#" -lt 5 || "$#" -gt 6 ]]; then
  echo "usage: run_app_correctness.sh <log-dir> <result-dir> <derived-data> <fixture-root> <xcodegen-home> [1|2|3|4|all]" >&2
  exit 2
fi

log_dir="$1"
result_dir="$2"
derived_data="$3"
fixture_root="$4"
export XCODEGEN_HOME="$5"
project="ClipyApp/ClipyApp.xcodeproj"
shard="${6:-all}"

# Balance the existing running-app journeys by their measured elapsed time.
# Each CI shard owns a separate runner: General pasteboard, focus and windows
# cannot be shared by concurrent UI runners on the same desktop.
gui_group_1=(
  AppearanceJourneyUITests
  RetentionCountJourneyUITests
  PDFPreviewJourneyUITests
  TextPreviewTruncationJourneyUITests
)
gui_group_2=(
  ThumbnailScrollMeasurementJourneyUITests
  CaptureAccessJourneyUITests
  StoreOpenRecoveryJourneyUITests
  DetailsUnavailableImageJourneyUITests
)
gui_group_3=(
  RTLPreviewGeometryJourneyUITests
  EditorRuntimeJourneyUITests
  FileReferencePreviewJourneyUITests
  PreviewRecoveryJourneyUITests
)
test_arguments=(-parallel-testing-enabled NO)
case "$shard" in
  1) selected_classes=("${gui_group_1[@]}") ;;
  2) selected_classes=("${gui_group_2[@]}") ;;
  3) selected_classes=("${gui_group_3[@]}") ;;
  4)
    # The complement includes both app-hosted bundles (integration and
    # presentation) and every remaining/new UI
    # class. Reuse the same lists so a new test cannot fall between shards.
    for test_class in "${gui_group_1[@]}" "${gui_group_2[@]}" "${gui_group_3[@]}"; do
      test_arguments+=("-skip-testing:ClipyUITests/$test_class")
    done
    ;;
  all) ;;
  *)
    echo "unknown app test shard: $shard (expected 1, 2, 3, 4, or all)" >&2
    exit 2
    ;;
esac
if [[ "$shard" == 1 || "$shard" == 2 || "$shard" == 3 ]]; then
  for test_class in "${selected_classes[@]}"; do
    test_arguments+=("-only-testing:ClipyUITests/$test_class")
  done
fi

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
  "${test_arguments[@]}" \
  CODE_SIGNING_ALLOWED=NO \
  test 2>&1 | tee "$log_dir/app-build-test.log"
