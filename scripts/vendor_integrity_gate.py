#!/usr/bin/env python3
"""Verify byte identity of the pinned vendored xxHash sources.

The hashes are independently recorded in ``Sources/xxh3/VENDORED.md``. This
gate makes an accidental source edit or unreviewed dependency replacement a
CI failure before durable fingerprint behavior can drift.

Usage:
  vendor_integrity_gate.py [--root REPO]

Exit codes: 0 = every file matches, 1 = missing/mismatched file, 2 = usage
error.
"""
from __future__ import annotations

import argparse
import hashlib
from pathlib import Path


EXPECTED_SHA256 = {
    Path("Sources/xxh3/xxhash.h"): (
        "17973c0dc49d9854ca26caa191f0e12f7a424b68858d9a78de3860d959d85e4b"
    ),
    Path("Sources/xxh3/xxhash.c"): (
        "5c3591fe6e6c86a619eb26760e9520e37a6fd5152882ab5ad93f912e2a855966"
    ),
}


def digest(path: Path) -> str:
    hasher = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            hasher.update(chunk)
    return hasher.hexdigest()


def check(root: Path) -> list[str]:
    failures: list[str] = []
    for relative_path, expected in EXPECTED_SHA256.items():
        path = root / relative_path
        if not path.is_file():
            failures.append(f"{relative_path}: missing pinned vendor file")
            continue
        actual = digest(path)
        if actual != expected:
            failures.append(
                f"{relative_path}: sha256 mismatch "
                f"(expected {expected}, found {actual})"
            )
    return failures


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--root",
        type=Path,
        default=Path(__file__).resolve().parent.parent,
        help="repository root (defaults to the parent of scripts/)",
    )
    args = parser.parse_args()
    root = args.root.resolve()
    failures = check(root)
    if failures:
        for failure in failures:
            print(f"vendor_integrity_gate: {failure}")
        print(f"vendor_integrity_gate: FAILED — {len(failures)} violation(s)")
        return 1
    print(
        "vendor_integrity_gate: OK — "
        f"{len(EXPECTED_SHA256)} pinned source files match"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
