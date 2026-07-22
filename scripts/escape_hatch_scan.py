#!/usr/bin/env python3
"""Escape-hatch and service-locator scan for Clipy (docs/01-architecture.md Part I §8).

Scans all Swift files under ``Sources/`` and ``Tests/`` and rejects:

  - ``@unchecked Sendable``
  - ``nonisolated(unsafe)``
  - service-locator spellings: ``static let shared``, ``static var shared``,
    ``static let current``, ``static var current``

Matching is line-based; occurrences inside comments or string literals are also
flagged (keep such text out of the tree rather than weakening the gate).

Usage:
  escape_hatch_scan.py [--root REPO]   scan the repo (default: repo containing this script)
  escape_hatch_scan.py --self-test     run fixture-based assertions, then exit

Exit codes: 0 = clean, 1 = violations found, 2 = usage/internal error.
Missing Sources/ or Tests/ directories are scanned as zero files.
"""
from __future__ import annotations

import argparse
import re
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path

SCAN_DIRS = ("Sources", "Tests")

PATTERNS: list[tuple[str, re.Pattern[str], str]] = [
    (
        "no-unchecked-sendable",
        re.compile(r"@unchecked\s+Sendable"),
        "'@unchecked Sendable' is banned in the greenfield targets (Part I §8)",
    ),
    (
        "no-nonisolated-unsafe",
        re.compile(r"nonisolated\s*\(\s*unsafe\s*\)"),
        "'nonisolated(unsafe)' is banned in the greenfield targets (Part I §8)",
    ),
    (
        "no-service-locator",
        re.compile(r"\bstatic\s+(?:let|var)\s+(?:shared|current)\b"),
        "service-locator spelling 'static let/var shared|current' is banned (Part I §8); "
        "pass dependencies through initializers instead",
    ),
]


@dataclass(frozen=True)
class Violation:
    path: Path
    line: int
    rule: str
    message: str

    def render(self, root: Path) -> str:
        try:
            shown: Path | str = self.path.relative_to(root)
        except ValueError:
            shown = self.path
        return f"{shown}:{self.line}: error: [{self.rule}] {self.message}"


def scan_file(path: Path) -> list[Violation]:
    violations: list[Violation] = []
    text = path.read_text(encoding="utf-8")
    for lineno, line in enumerate(text.splitlines(), start=1):
        for rule, pattern, message in PATTERNS:
            if pattern.search(line):
                violations.append(Violation(path, lineno, rule, message))
    return violations


def scan(root: Path) -> tuple[list[Violation], int]:
    """Scan root/{Sources,Tests}/**/*.swift. Returns (violations, files scanned).

    Missing scan directories are not an error — they scan as zero files.
    """
    violations: list[Violation] = []
    file_count = 0
    for scan_dir in SCAN_DIRS:
        base = root / scan_dir
        if not base.is_dir():
            continue
        for swift_file in sorted(base.rglob("*.swift")):
            file_count += 1
            violations.extend(scan_file(swift_file))
    return violations, file_count


# ---------------------------------------------------------------- self-test

BAD_FIXTURES: dict[str, tuple[str, str]] = {
    # relative path -> (content, rule expected to fire)
    "Sources/HistoryCore/UnsafeSendable.swift": (
        "public final class Sneaky: @unchecked Sendable {}\n",
        "no-unchecked-sendable",
    ),
    "Sources/HistoryStorage/UnsafeGlobal.swift": (
        "nonisolated(unsafe) var cachedCount = 0\n",
        "no-nonisolated-unsafe",
    ),
    "Sources/PresentationUI/SharedLocator.swift": (
        "enum Environment {\n    static let shared = Environment()\n}\n",
        "no-service-locator",
    ),
    "Tests/HistoryCoreTests/CurrentLocator.swift": (
        "struct Fixture { static var current: Fixture? }\n",
        "no-service-locator",
    ),
}

GOOD_FIXTURES: dict[str, str] = {
    "Sources/HistoryCore/Good.swift": (
        "public struct Fine: Sendable {\n"
        "    static let allCases: [Fine] = []\n"      # not a locator spelling
        "    static var sharedPrefix: String { \"\" }\n"  # `shared` without word boundary
        "    func make() {\n"
        "        let shared = 1\n"                     # non-static local: fine
        "        _ = shared\n"
        "    }\n"
        "    nonisolated var description: String { \"\" }\n"  # nonisolated without (unsafe)
        "}\n"
    ),
    "Tests/HistoryCoreTests/Good.swift": "import Foundation\nfinal class GoodTests {}\n",
}


def _write(root: Path, rel: str, content: str) -> None:
    path = root / rel
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")


def _require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(f"escape_hatch_scan: self-test FAILED: {message}")


def self_test() -> int:
    # 1) Every deliberate violation is flagged with the expected rule, and
    #    nothing else is.
    with tempfile.TemporaryDirectory(prefix="escape-hatch-selftest-bad-") as tmp:
        root = Path(tmp)
        for rel, (content, _) in BAD_FIXTURES.items():
            _write(root, rel, content)
        for rel, content in GOOD_FIXTURES.items():
            _write(root, rel, content)
        violations, file_count = scan(root)
        _require(
            file_count == len(BAD_FIXTURES) + len(GOOD_FIXTURES),
            f"expected {len(BAD_FIXTURES) + len(GOOD_FIXTURES)} files scanned, got {file_count}",
        )
        got = {(v.path.name, v.rule) for v in violations}
        expected = {(Path(rel).name, rule) for rel, (_, rule) in BAD_FIXTURES.items()}
        _require(
            got == expected,
            f"violation set mismatch\n  missing: {sorted(expected - got)}\n  unexpected: {sorted(got - expected)}",
        )

    # 2) A clean fixture tree passes.
    with tempfile.TemporaryDirectory(prefix="escape-hatch-selftest-good-") as tmp:
        root = Path(tmp)
        for rel, content in GOOD_FIXTURES.items():
            _write(root, rel, content)
        violations, _ = scan(root)
        _require(
            not violations,
            f"clean fixture was flagged: {[v.render(root) for v in violations]}",
        )

    # 3) Missing Sources/ and Tests/ trees are tolerated.
    with tempfile.TemporaryDirectory(prefix="escape-hatch-selftest-empty-") as tmp:
        violations, file_count = scan(Path(tmp))
        _require(not violations and file_count == 0, "empty tree should scan as zero files, zero violations")

    print(
        "escape_hatch_scan: self-test OK — "
        f"{len(BAD_FIXTURES)} deliberate violations flagged, "
        "clean fixture passes, missing Sources/ and Tests/ tolerated"
    )
    return 0


# -------------------------------------------------------------------- main

def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Clipy escape-hatch / service-locator scan (docs/01-architecture.md Part I §8)."
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
        violations, file_count = scan(root)
    except OSError as exc:
        print(f"escape_hatch_scan: error while scanning: {exc}", file=sys.stderr)
        return 2

    if violations:
        for violation in violations:
            print(violation.render(root), file=sys.stderr)
        print(
            f"escape_hatch_scan: FAILED — {len(violations)} banned construct(s) "
            "(docs/01-architecture.md Part I §8)",
            file=sys.stderr,
        )
        return 1

    print(f"escape_hatch_scan: OK — {file_count} Swift file(s) scanned, no banned constructs")
    return 0


if __name__ == "__main__":
    sys.exit(main())
