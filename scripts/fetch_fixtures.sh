#!/bin/bash
# Fetches the pinned Clipy test-fixture release (real-scale 4K images,
# 100KB–5MB texts, rich docs — see scripts/generate_fixtures.py), verifies
# the tarball sha256, and unpacks it into the given directory, producing
# <dir>/clipy-fixtures-v1/. Used by CI (both test jobs) and by developers who
# want the fixture-gated stress/smoke suites locally (they are skipped via
# .enabled(if: FixtureCatalog.available) when the tree is absent).
set -euo pipefail

DEST="${1:?usage: fetch_fixtures.sh <destination-dir>}"
RELEASE_TAG="fixtures-v1"
TARBALL="clipy-fixtures-v1.tar.gz"
EXPECTED_SHA256="ca1a5e11a68a6adf712d04be5f0113db9e31f0d1f44f3beb73302bbeeeee8a2c"
URL="https://github.com/GuangDai/Clipy/releases/download/${RELEASE_TAG}/${TARBALL}"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

curl -fL --retry 3 --no-progress-meter "$URL" -o "$tmp/$TARBALL"

if command -v sha256sum >/dev/null 2>&1; then
  actual="$(sha256sum "$tmp/$TARBALL" | cut -d' ' -f1)"
else
  actual="$(shasum -a 256 "$tmp/$TARBALL" | cut -d' ' -f1)"
fi
if [[ "$actual" != "$EXPECTED_SHA256" ]]; then
  echo "fixture tarball sha256 mismatch: expected $EXPECTED_SHA256, got $actual" >&2
  exit 1
fi

mkdir -p "$DEST"
tar -xzf "$tmp/$TARBALL" -C "$DEST"
[[ -f "$DEST/clipy-fixtures-v1/manifest.json" ]]
echo "fixtures ready at $DEST/clipy-fixtures-v1"
