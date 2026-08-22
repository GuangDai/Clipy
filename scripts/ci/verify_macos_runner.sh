#!/usr/bin/env bash
# Shared macOS 26/arm64 runner contract for every GitHub Actions job.
set -euo pipefail

diagnostics_log="${1:-}"
product_version="$(sw_vers -productVersion)"
machine_arch="$(uname -m)"

if [[ "$product_version" != 26.* ]]; then
  echo "Expected macOS 26.x, got $product_version" >&2
  exit 1
fi
if [[ "$machine_arch" != arm64 ]]; then
  echo "Expected arm64 runner, got $machine_arch" >&2
  exit 1
fi

if [[ -n "$diagnostics_log" ]]; then
  mkdir -p "$(dirname "$diagnostics_log")"
  {
    echo "== Date =="
    date -u
    echo
    echo "== Runner =="
    echo "RUNNER_OS=${RUNNER_OS:-}"
    echo "RUNNER_ARCH=${RUNNER_ARCH:-}"
    echo "ImageOS=${ImageOS:-}"
    echo "ImageVersion=${ImageVersion:-}"
    echo
    echo "== macOS =="
    sw_vers
    echo
    echo "== Kernel and CPU =="
    uname -a
    uname -m
    echo
    echo "== Xcode =="
    xcode-select -p
    xcodebuild -version
    xcrun --sdk macosx --show-sdk-version
    echo
    echo "== Swift =="
    swift --version
  } 2>&1 | tee "$diagnostics_log"
fi

echo "runner contract: macOS $product_version / $machine_arch"
