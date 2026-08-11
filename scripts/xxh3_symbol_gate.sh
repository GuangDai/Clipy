#!/usr/bin/env bash
# Prove that the package's vendored xxHash implementation exports only Clipy's
# wrapper rather than the complete upstream XXH* C ABI.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

xxh3_target_block="$(sed -n '/name: "xxh3"/,/^[[:space:]]*),/p' \
    "$REPO_ROOT/Package.swift")"
if ! grep -Fq '.define("XXH_INLINE_ALL")' <<<"$xxh3_target_block"; then
    echo "xxh3_symbol_gate: Package.swift is missing XXH_INLINE_ALL"
    exit 1
fi

if [[ "$(uname -s)" == "Darwin" ]] && command -v xcrun >/dev/null 2>&1; then
    compiler=(xcrun --sdk macosx clang)
    symbol_tool=(xcrun nm -gU)
elif command -v clang >/dev/null 2>&1 && command -v nm >/dev/null 2>&1; then
    compiler=(clang)
    symbol_tool=(nm -g --defined-only)
else
    echo "xxh3_symbol_gate: skipping object proof (clang/nm unavailable)"
    exit 0
fi

gate_tmp="$(mktemp -d "${TMPDIR:-/tmp}/clipy-xxh3-symbols.XXXXXX")"
trap 'rm -rf "$gate_tmp"' EXIT

include_flags=(
    -DXXH_INLINE_ALL
    -I "$REPO_ROOT/Sources/xxh3"
    -I "$REPO_ROOT/Sources/xxh3/include"
)
"${compiler[@]}" "${include_flags[@]}" -c \
    "$REPO_ROOT/Sources/xxh3/xxhash.c" -o "$gate_tmp/xxhash.o"
"${compiler[@]}" "${include_flags[@]}" -c \
    "$REPO_ROOT/Sources/xxh3/xxh3.c" -o "$gate_tmp/xxh3.o"

symbols="$("${symbol_tool[@]}" "$gate_tmp/xxhash.o" "$gate_tmp/xxh3.o" \
    | awk 'NF >= 2 && $(NF - 1) ~ /^[A-Za-z]$/ { print $NF }' \
    | sed 's/^_//' \
    | sort -u)"

if [[ "$symbols" != "clipy_xxh3_64bits" ]]; then
    echo "xxh3_symbol_gate: unexpected exported xxHash symbols"
    if [[ -n "$symbols" ]]; then
        echo "$symbols"
    fi
    exit 1
fi

echo "xxh3_symbol_gate: OK — only clipy_xxh3_64bits is global"
