#!/usr/bin/env python3
"""Import-confinement gate for the Clipy target graph (docs/01-architecture.md Part I §8).

Scans ``Sources/<Target>/**/*.swift`` for ``import X`` lines and rejects imports
that violate the target's confinement rules:

  HistoryCore        allowlist: Foundation (incl. submodules, e.g. FoundationNetworking)
  HistoryDomain      allowlist: Foundation, HistoryCore
  HistoryStorage     blocklist: AppKit, SwiftUI, PasteboardAdapter, PresentationUI
                     (SwiftData / ImageIO / xxh3 / Fuse / HistoryCore / HistoryDomain
                     allowed; Fuse was pinned at roadmap step 3 and is confined to
                     HistoryStorage by the global rule below)
  PasteboardAdapter  blocklist: HistoryDomain, HistoryStorage, SwiftUI, SwiftData,
                     and other adapters (PasteboardAdapter is the only adapter target
                     today, so that set is currently empty; AppKit is allowed)
  PresentationUI     blocklist: HistoryDomain, HistoryStorage, AppKit, SwiftData
                     (SwiftUI is allowed)
  HistoryPerfRunner  allowlist: Foundation, HistoryCore

Global rules: ``import xxh3`` and ``import Fuse`` are forbidden outside
HistoryStorage.

ClipyApp (XcodeGen app target / composition root) and the C target xxh3 itself
are not governed by this gate. Matching is line-based: ``import`` statements at
line start inside block comments or string literals would also be seen — Swift
style keeps imports at line start, so this is acceptable for a scaffold gate.

Usage:
  import_gate.py [--root REPO]   scan the repo (default: repo containing this script)
  import_gate.py --self-test     run fixture-based assertions, then exit

Exit codes: 0 = no violations, 1 = violations found, 2 = usage/internal error.
A missing Sources/ tree (or a missing per-target directory) is scanned as zero
files — the scaffold targets may not all exist yet.
"""
from __future__ import annotations

import argparse
import re
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path

FOUNDATION = "Foundation"
XXH3_MODULE = "xxh3"
XXH3_OWNER = "HistoryStorage"
FUSE_MODULE = "Fuse"
FUSE_OWNER = "HistoryStorage"

# Allowlist targets: every import must be in this set (Foundation prefix matches
# submodules wherever Foundation is listed).
ALLOWLIST: dict[str, frozenset[str]] = {
    "HistoryCore": frozenset({FOUNDATION}),
    "HistoryDomain": frozenset({FOUNDATION, "HistoryCore"}),
    "HistoryPerfRunner": frozenset({FOUNDATION, "HistoryCore"}),
}

# Blocklist targets: these specific imports are forbidden, anything else passes.
BLOCKLIST: dict[str, frozenset[str]] = {
    "HistoryStorage": frozenset({"AppKit", "SwiftUI", "PasteboardAdapter", "PresentationUI"}),
    "PasteboardAdapter": frozenset({"HistoryDomain", "HistoryStorage", "SwiftUI", "SwiftData"}),
    "PresentationUI": frozenset({"HistoryDomain", "HistoryStorage", "AppKit", "SwiftData"}),
}

# Matches `import Foo`, `@_exported import Foo`, `import struct Foo.Bar`, etc.
# Captures the top-level module name only.
IMPORT_RE = re.compile(
    r"^\s*(?:@_\w+\s+)*import\s+"
    r"(?:(?:struct|class|enum|protocol|func|typealias|var|let)\s+)?"
    r"([A-Za-z_][A-Za-z0-9_]*)"
)


@dataclass(frozen=True)
class Violation:
    path: Path
    line: int
    target: str
    module: str
    message: str

    def render(self, root: Path) -> str:
        try:
            shown: Path | str = self.path.relative_to(root)
        except ValueError:
            shown = self.path
        return f"{shown}:{self.line}: error: {self.message}"


def check_import(target: str, module: str) -> str | None:
    """Return a violation message for `target` importing `module`, or None if allowed."""
    if module == XXH3_MODULE and target != XXH3_OWNER:
        return (
            f"target '{target}' must not import '{XXH3_MODULE}' "
            f"({XXH3_MODULE} is confined to {XXH3_OWNER}; Part I §8)"
        )
    if module == FUSE_MODULE and target != FUSE_OWNER:
        return (
            f"target '{target}' must not import '{FUSE_MODULE}' "
            f"({FUSE_MODULE} is confined to {FUSE_OWNER}; Part I §8)"
        )
    if target in ALLOWLIST:
        allowed = ALLOWLIST[target]
        if module in allowed:
            return None
        if FOUNDATION in allowed and module.startswith(FOUNDATION):
            return None  # Foundation submodule, e.g. FoundationNetworking
        allowed_desc = ", ".join(sorted(allowed)) + " (+ Foundation submodules)"
        return (
            f"target '{target}' may import only {allowed_desc} — "
            f"found 'import {module}' (Part I §8)"
        )
    if module in BLOCKLIST.get(target, frozenset()):
        return f"target '{target}' must not import '{module}' (Part I §8)"
    return None


def scan_file(path: Path, target: str) -> list[Violation]:
    violations: list[Violation] = []
    text = path.read_text(encoding="utf-8")
    for lineno, line in enumerate(text.splitlines(), start=1):
        match = IMPORT_RE.match(line)
        if not match:
            continue
        message = check_import(target, match.group(1))
        if message:
            violations.append(Violation(path, lineno, target, match.group(1), message))
    return violations


def scan(root: Path) -> tuple[list[Violation], dict[str, int]]:
    """Scan root/Sources/<Target>/**/*.swift.

    Returns (violations, files-scanned-per-target). A missing Sources/ tree or
    missing per-target directory is not an error — it scans as zero files.
    Unknown targets (no entry in ALLOWLIST/BLOCKLIST) are checked against the
    global xxh3/Fuse rules only.
    """
    violations: list[Violation] = []
    counts: dict[str, int] = {}
    sources = root / "Sources"
    if not sources.is_dir():
        return violations, counts
    for target_dir in sorted(p for p in sources.iterdir() if p.is_dir()):
        files = sorted(target_dir.rglob("*.swift"))
        counts[target_dir.name] = len(files)
        for swift_file in files:
            violations.extend(scan_file(swift_file, target_dir.name))
    return violations, counts


# ---------------------------------------------------------------- self-test

GOOD_FIXTURES: dict[str, str] = {
    "Sources/HistoryCore/Good.swift": (
        "import Foundation\n"
        "import FoundationNetworking\n"          # Foundation submodule: allowed
        "import struct Foundation.Date\n"        # kind-import form: allowed
        "@_exported import Foundation\n"
    ),
    "Sources/HistoryDomain/Good.swift": "import Foundation\nimport HistoryCore\n",
    "Sources/HistoryStorage/Good.swift": (
        "import Foundation\n"
        "import HistoryCore\n"
        "import HistoryDomain\n"
        "import SwiftData\n"
        "import ImageIO\n"
        "import xxh3\n"                          # xxh3 allowed in its owner target
        "import Fuse\n"                          # Fuse allowed in its owner target
    ),
    "Sources/PasteboardAdapter/Good.swift": "import Foundation\nimport HistoryCore\nimport AppKit\n",
    "Sources/PresentationUI/Good.swift": "import Foundation\nimport HistoryCore\nimport SwiftUI\n",
    "Sources/HistoryPerfRunner/Good.swift": "import Foundation\nimport HistoryCore\n",
}

BAD_FIXTURES: dict[str, str] = {
    "Sources/HistoryCore/Bad.swift": "import AppKit\n",
    "Sources/HistoryCore/BadFuse.swift": "import Fuse\n",  # global Fuse rule
    "Sources/HistoryDomain/Bad.swift": "import HistoryStorage\n",
    "Sources/HistoryStorage/BadSwiftUI.swift": "import SwiftUI\n",
    "Sources/HistoryStorage/BadAdapter.swift": "import PasteboardAdapter\n",
    "Sources/PasteboardAdapter/BadDomain.swift": "import HistoryDomain\n",
    "Sources/PasteboardAdapter/BadSwiftData.swift": "import SwiftData\n",
    "Sources/PresentationUI/Bad.swift": "import AppKit\n",
    "Sources/PresentationUI/BadXxh3.swift": "import xxh3\n",  # global xxh3 rule
    "Sources/PresentationUI/BadFuse.swift": "import Fuse\n",  # global Fuse rule
    "Sources/HistoryPerfRunner/Bad.swift": "import SwiftData\n",
}

EXPECTED_SELF_TEST_VIOLATIONS = {
    ("HistoryCore", "AppKit"),
    ("HistoryCore", "Fuse"),
    ("HistoryDomain", "HistoryStorage"),
    ("HistoryStorage", "SwiftUI"),
    ("HistoryStorage", "PasteboardAdapter"),
    ("PasteboardAdapter", "HistoryDomain"),
    ("PasteboardAdapter", "SwiftData"),
    ("PresentationUI", "AppKit"),
    ("PresentationUI", "xxh3"),
    ("PresentationUI", "Fuse"),
    ("HistoryPerfRunner", "SwiftData"),
}


def _write_fixtures(root: Path, fixtures: dict[str, str]) -> None:
    for rel, content in fixtures.items():
        path = root / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8")


def _require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(f"import_gate: self-test FAILED: {message}")


def self_test() -> int:
    # 1) Every deliberate violation is flagged, and nothing else is.
    with tempfile.TemporaryDirectory(prefix="import-gate-selftest-bad-") as tmp:
        root = Path(tmp)
        _write_fixtures(root, {**GOOD_FIXTURES, **BAD_FIXTURES})
        violations, _ = scan(root)
        got = {(v.target, v.module) for v in violations}
        _require(
            got == EXPECTED_SELF_TEST_VIOLATIONS,
            "violation set mismatch\n"
            f"  missing (not flagged): {sorted(EXPECTED_SELF_TEST_VIOLATIONS - got)}\n"
            f"  unexpected (flagged):  {sorted(got - EXPECTED_SELF_TEST_VIOLATIONS)}",
        )

    # 2) A clean fixture tree passes with zero violations.
    with tempfile.TemporaryDirectory(prefix="import-gate-selftest-good-") as tmp:
        root = Path(tmp)
        _write_fixtures(root, GOOD_FIXTURES)
        violations, counts = scan(root)
        _require(not violations, f"clean fixture was flagged: {[v.render(root) for v in violations]}")
        _require(
            sum(counts.values()) == len(GOOD_FIXTURES),
            f"clean fixture file count mismatch: {counts}",
        )

    # 3) A missing Sources/ tree is tolerated (scaffold targets may not exist yet).
    with tempfile.TemporaryDirectory(prefix="import-gate-selftest-empty-") as tmp:
        violations, counts = scan(Path(tmp))
        _require(not violations and not counts, "empty tree should scan as zero files, zero violations")

    print(
        "import_gate: self-test OK — "
        f"{len(EXPECTED_SELF_TEST_VIOLATIONS)} deliberate forbidden imports flagged, "
        "clean fixture passes, missing Sources/ tolerated"
    )
    return 0


# -------------------------------------------------------------------- main

def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Clipy import-confinement gate (docs/01-architecture.md Part I §8)."
    )
    parser.add_argument(
        "--root",
        type=Path,
        default=Path(__file__).resolve().parent.parent,
        help="repository root to scan (default: parent of this script's directory)",
    )
    parser.add_argument(
        "--self-test",
        action="store_true",
        help="run fixture-based assertions (deliberate violations must be flagged), then exit",
    )
    args = parser.parse_args(argv)

    if args.self_test:
        return self_test()

    root = args.root.resolve()
    try:
        violations, counts = scan(root)
    except OSError as exc:
        print(f"import_gate: error while scanning: {exc}", file=sys.stderr)
        return 2

    if violations:
        for violation in violations:
            print(violation.render(root), file=sys.stderr)
        print(
            f"import_gate: FAILED — {len(violations)} forbidden import(s) "
            "(docs/01-architecture.md Part I §8)",
            file=sys.stderr,
        )
        return 1

    total = sum(counts.values())
    if counts:
        per_target = ", ".join(f"{target}: {n} file(s)" for target, n in sorted(counts.items()))
        print(f"import_gate: OK — {total} Swift file(s) scanned, no violations ({per_target})")
    else:
        print("import_gate: OK — no Sources/ tree found, nothing to scan")
    return 0


if __name__ == "__main__":
    sys.exit(main())
