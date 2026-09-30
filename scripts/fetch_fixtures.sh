#!/bin/bash
# Fetches the pinned Clipy test-fixture release (real-scale 4K images,
# 100KB–5MB texts, rich docs — see scripts/generate_fixtures.py), and
# unpacks it into the given directory, producing
# <dir>/clipy-fixtures-v1/. Used by CI (both test jobs) and by developers who
# want the fixture-gated stress/smoke suites locally (they are skipped via
# .enabled(if: FixtureCatalog.available) when the tree is absent).
set -euo pipefail

DEST="${1:?usage: fetch_fixtures.sh <destination-dir>}"
RELEASE_TAG="fixtures-v1"
TARBALL="clipy-fixtures-v1.tar.gz"
URL="https://github.com/GuangDai/Clipy/releases/download/${RELEASE_TAG}/${TARBALL}"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

curl -fL --retry 3 --no-progress-meter "$URL" -o "$tmp/$TARBALL"

mkdir -p "$DEST"
tar -xzf "$tmp/$TARBALL" -C "$DEST"
[[ -f "$DEST/clipy-fixtures-v1/manifest.json" ]]
echo "fixtures ready at $DEST/clipy-fixtures-v1"
