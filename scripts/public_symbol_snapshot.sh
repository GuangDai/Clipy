#!/usr/bin/env bash
# public_symbol_snapshot.sh — HistoryCore public-symbol surface snapshot
# (docs/01-architecture.md Part I §9 item 4; docs/06-cross-cutting.md §6).
#
# Builds HistoryCore, dumps its symbol graph with
# `xcrun swift symbolgraph-extract`, extracts the public symbol titles, and
# diffs them against Tests/HistoryCoreTests/SymbolSurface/HistoryCore.symbols.txt.
#
#   --update   regenerate the expected snapshot instead of checking it
#
# Requirements: macOS with Xcode (xcrun), a Swift toolchain, and python3 or jq.
# On any other platform the script exits 2 with a clear error — this is why
# scripts/run_gates.sh only invokes it on macOS with xcrun present.
#
# Exit codes: 0 = snapshot matches (or was updated), 1 = snapshot mismatch,
#             2 = wrong environment / tooling failure.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXPECTED="$REPO_ROOT/Tests/HistoryCoreTests/SymbolSurface/HistoryCore.symbols.txt"
HEADER='# HistoryCore public symbol snapshot — populated at roadmap step 1'

UPDATE=0
case "${1:-}" in
    "") ;;
    --update) UPDATE=1 ;;
    *)
        echo "usage: $0 [--update]" >&2
        exit 2
        ;;
esac

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "public_symbol_snapshot: error: requires macOS (xcrun swift symbolgraph-extract);" >&2
    echo "  detected platform '$(uname -s)'. This gate runs on the macOS runner only." >&2
    exit 2
fi
if ! command -v xcrun >/dev/null 2>&1; then
    echo "public_symbol_snapshot: error: 'xcrun' not found — install Xcode or the Command Line Tools." >&2
    exit 2
fi

EXTRACTOR=""
if command -v python3 >/dev/null 2>&1; then
    EXTRACTOR="python3"
elif command -v jq >/dev/null 2>&1; then
    EXTRACTOR="jq"
else
    echo "public_symbol_snapshot: error: need python3 or jq to parse the symbol graph JSON." >&2
    exit 2
fi

cd "$REPO_ROOT"

echo "public_symbol_snapshot: building HistoryCore..."
swift build --target HistoryCore

MODULE_DIR=""
while IFS= read -r candidate; do
    MODULE_DIR="$(dirname "$candidate")"
    break
done < <(find .build -name 'HistoryCore.swiftmodule' 2>/dev/null)
if [[ -z "$MODULE_DIR" ]]; then
    echo "public_symbol_snapshot: error: HistoryCore.swiftmodule not found under .build/." >&2
    echo "  Did 'swift build --target HistoryCore' succeed?" >&2
    exit 2
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if [[ "$EXTRACTOR" == "python3" ]]; then
    TARGET_TRIPLE="$(xcrun swift -print-target-info \
        | python3 -c 'import json,sys; print(json.load(sys.stdin)["target"]["triple"])')"
else
    TARGET_TRIPLE="$(xcrun swift -print-target-info | jq -r '.target.triple')"
fi

echo "public_symbol_snapshot: extracting symbol graph (target $TARGET_TRIPLE)..."
mkdir -p "$WORK/symbolgraph"
xcrun swift symbolgraph-extract \
    -module-name HistoryCore \
    -target "$TARGET_TRIPLE" \
    -I "$MODULE_DIR" \
    -output-dir "$WORK/symbolgraph"

# The primary file holds symbols declared in HistoryCore itself; the
# `HistoryCore@<Other>.symbols.json` extension files are not part of the
# module's own public surface and are ignored.
SYMBOL_JSON="$WORK/symbolgraph/HistoryCore.symbols.json"
if [[ ! -f "$SYMBOL_JSON" ]]; then
    echo "public_symbol_snapshot: error: expected output $SYMBOL_JSON was not produced." >&2
    exit 2
fi

if [[ "$EXTRACTOR" == "python3" ]]; then
    python3 -c '
import json, sys
with open(sys.argv[1], encoding="utf-8") as fh:
    graph = json.load(fh)
names = sorted({
    symbol["names"]["title"]
    for symbol in graph.get("symbols", [])
    if symbol.get("accessLevel") == "public"
})
if names:
    print("\n".join(names))
' "$SYMBOL_JSON" > "$WORK/public-symbols.txt"
else
    jq -r '[.symbols[] | select(.accessLevel == "public") | .names.title] | unique | .[]' \
        "$SYMBOL_JSON" > "$WORK/public-symbols.txt"
fi

{ printf '%s\n' "$HEADER"; cat "$WORK/public-symbols.txt"; } > "$WORK/generated.txt"

if [[ "$UPDATE" == 1 ]]; then
    cp "$WORK/generated.txt" "$EXPECTED"
    echo "public_symbol_snapshot: updated snapshot at $EXPECTED"
    exit 0
fi

if [[ ! -f "$EXPECTED" ]]; then
    echo "public_symbol_snapshot: error: snapshot file missing: $EXPECTED" >&2
    echo "  Run '$0 --update' on macOS to create it." >&2
    exit 2
fi

if diff -u "$EXPECTED" "$WORK/generated.txt"; then
    echo "public_symbol_snapshot: OK — HistoryCore public symbol surface matches the snapshot"
    exit 0
else
    echo "public_symbol_snapshot: FAILED — HistoryCore public symbol surface drifted." >&2
    echo "  If the change is intentional, regenerate with: $0 --update" >&2
    exit 1
fi
