#!/usr/bin/env bash
# Regenerate ClipyApp.xcodegen project deterministically with a pinned XcodeGen.
# The library target graph stays SwiftPM-owned (Package.swift); XcodeGen owns
# only the application/composition target (docs/01-architecture.md §9 item 6).
set -euo pipefail

XCODEGEN_VERSION="2.45.4"
XCODEGEN_HOME="${XCODEGEN_HOME:-${TMPDIR:-/tmp}/xcodegen-$XCODEGEN_VERSION}"
PROJECT_ROOT="${PROJECT_ROOT:-$PWD}"
SPEC="$PROJECT_ROOT/ClipyApp/project.yml"

if [[ ! -x "$XCODEGEN_HOME/bin/xcodegen" ]]; then
  mkdir -p "$XCODEGEN_HOME"
  archive="$XCODEGEN_HOME/xcodegen.zip"
  curl -fsSL \
    "https://github.com/yonaskolb/XcodeGen/releases/download/$XCODEGEN_VERSION/xcodegen.zip" \
    -o "$archive"
  ditto -x -k "$archive" "$XCODEGEN_HOME"
fi

cd "$PROJECT_ROOT"
"$XCODEGEN_HOME/bin/xcodegen" generate --spec "$SPEC"
echo "Generated ClipyApp/ClipyApp.xcodeproj with XcodeGen $XCODEGEN_VERSION"
