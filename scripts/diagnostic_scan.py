#!/usr/bin/env python3
"""Fail closed on warning/error diagnostics emitted by Clipy's CI lanes.

The workflow used to carry several subtly different awk/grep pipelines.  This
module keeps the policy in one tested place while retaining a small, closed
interface: callers choose the lane profile and provide one or more log files.
"""

from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, Sequence


DIAGNOSTIC_PATTERN = re.compile(
    r"(^|[^A-Za-z])(warning:|error:)([^A-Za-z]|$)",
    re.IGNORECASE,
)
MISSING_FILE_PATTERN = re.compile(r"No such file or directory", re.IGNORECASE)
COREDATA_CLONE_START = re.compile(
    r"^CoreData: error: Failed to clone external data reference "
    r"from .+?\.interim to .+? error: "
    r"Error Domain=NSCocoaErrorDomain Code=4 .*?UserInfo=\{"
)
COREDATA_CLONE_END = re.compile(r"\}\}")
APPINTENTS_METADATA_WARNING = re.compile(
    r"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d+ "
    r"appintentsmetadataprocessor\[\d+:\d+\] warning: "
    r"Metadata extraction skipped\. No AppIntents\.framework dependency found\.$"
)
@dataclass(frozen=True)
class ScanProfile:
    permits_coredata_clone_block: bool = False
    detects_missing_file: bool = False
    permits_appintents_metadata_warning: bool = False


PROFILES = {
    "strict": ScanProfile(),
    "app": ScanProfile(permits_appintents_metadata_warning=True),
    "swiftdata": ScanProfile(permits_coredata_clone_block=True),
    "swiftdata-missing": ScanProfile(
        permits_coredata_clone_block=True,
        detects_missing_file=True,
    ),
}


@dataclass(frozen=True)
class Finding:
    path: str
    line_number: int
    message: str
    line: str

    def render(self) -> str:
        suffix = f": {self.line}" if self.line else ""
        return f"{self.path}:{self.line_number}: {self.message}{suffix}"


def scan_lines(
    lines: Iterable[str],
    *,
    path: str,
    profile: ScanProfile,
) -> list[Finding]:
    findings: list[Finding] = []
    clone_block_start_line: int | None = None

    for line_number, raw_line in enumerate(lines, start=1):
        line = raw_line.rstrip("\r\n")

        if clone_block_start_line is not None:
            end_match = COREDATA_CLONE_END.search(line)
            block_fragment = line if end_match is None else line[: end_match.start()]
            if DIAGNOSTIC_PATTERN.search(block_fragment):
                findings.append(
                    Finding(
                        path,
                        line_number,
                        "unexpected diagnostic inside permitted CoreData clone block",
                        line,
                    )
                )

            if end_match is not None:
                clone_block_start_line = None
                line = line[end_match.end() :]
                if not line:
                    continue
            else:
                continue

        start_match = (
            COREDATA_CLONE_START.search(line)
            if profile.permits_coredata_clone_block
            else None
        )
        if start_match is not None:
            remainder = line[start_match.end() :]
            end_match = COREDATA_CLONE_END.search(remainder)
            block_fragment = (
                remainder if end_match is None else remainder[: end_match.start()]
            )
            if DIAGNOSTIC_PATTERN.search(block_fragment):
                findings.append(
                    Finding(
                        path,
                        line_number,
                        "unexpected diagnostic inside permitted CoreData clone block",
                        line,
                    )
                )

            if end_match is None:
                clone_block_start_line = line_number
                continue
            line = remainder[end_match.end() :]
            if not line:
                continue

        if (
            profile.permits_appintents_metadata_warning
            and APPINTENTS_METADATA_WARNING.fullmatch(line)
        ):
            continue

        if DIAGNOSTIC_PATTERN.search(line):
            findings.append(Finding(path, line_number, "warning/error diagnostic", line))
            continue

        if profile.detects_missing_file and MISSING_FILE_PATTERN.search(line):
            findings.append(Finding(path, line_number, "missing-file diagnostic", line))

    if clone_block_start_line is not None:
        findings.append(
            Finding(
                path,
                clone_block_start_line,
                "unterminated permitted CoreData clone block",
                "",
            )
        )

    return findings


def scan_paths(paths: Sequence[Path], profile: ScanProfile) -> list[Finding]:
    findings: list[Finding] = []
    for path in paths:
        with path.open("r", encoding="utf-8") as handle:
            findings.extend(scan_lines(handle, path=str(path), profile=profile))
    return findings


def parse_args(argv: Sequence[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile", choices=sorted(PROFILES), default="strict")
    parser.add_argument("logs", nargs="+", type=Path)
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    try:
        findings = scan_paths(args.logs, PROFILES[args.profile])
    except (OSError, UnicodeError) as error:
        print(f"diagnostic_scan: unable to read log: {error}", file=sys.stderr)
        return 2

    if findings:
        for finding in findings:
            print(finding.render())
        print(
            f"diagnostic_scan: FAILED — {len(findings)} finding(s) "
            f"across {len(args.logs)} log(s)",
            file=sys.stderr,
        )
        return 1

    print(
        f"diagnostic_scan: OK — {len(args.logs)} log(s), profile={args.profile}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
