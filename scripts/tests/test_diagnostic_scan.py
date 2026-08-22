from __future__ import annotations

import unittest

from scripts.diagnostic_scan import PROFILES, scan_lines


COREDATA_CLONE_OPENER = (
    "CoreData: error: Failed to clone external data reference "
    "from /private/tmp/value.interim to /private/tmp/.LINKS/value "
    'error: Error Domain=NSCocoaErrorDomain Code=4 "value.interim missing" '
    "UserInfo={"
)


def scan(text: str, profile: str = "strict"):
    return scan_lines(
        text.splitlines(keepends=True),
        path="fixture.log",
        profile=PROFILES[profile],
    )


class DiagnosticScanTests(unittest.TestCase):
    def test_strict_profile_accepts_clean_log(self) -> None:
        self.assertEqual(scan("Build complete\nTest Suite Passed\n"), [])

    def test_strict_profile_reports_line_number_for_warning(self) -> None:
        findings = scan("clean\nsource.swift:7: warning: captured var mutated\n")

        self.assertEqual(len(findings), 1)
        self.assertEqual(findings[0].line_number, 2)
        self.assertIn("captured var mutated", findings[0].line)

    def test_complete_known_coredata_block_is_permitted(self) -> None:
        findings = scan(
            COREDATA_CLONE_OPENER
            + "\n"
            '  URL = "value.interim";\n'
            '  NSUnderlyingError = {Error Domain=NSPOSIXErrorDomain Code=2};\n'
            "}}\n"
            "tests passed\n",
            "swiftdata",
        )

        self.assertEqual(findings, [])

    def test_single_line_known_coredata_block_is_permitted(self) -> None:
        findings = scan(
            COREDATA_CLONE_OPENER + "}}\n",
            "swiftdata",
        )

        self.assertEqual(findings, [])

    def test_diagnostic_inside_known_coredata_block_is_not_hidden(self) -> None:
        findings = scan(
            COREDATA_CLONE_OPENER
            + "\n"
            "worker: error: unrelated durable write failed\n"
            "}}\n",
            "swiftdata",
        )

        self.assertEqual(len(findings), 1)
        self.assertIn("inside permitted CoreData", findings[0].message)

    def test_coredata_opener_cannot_hide_second_diagnostic(self) -> None:
        findings = scan(
            COREDATA_CLONE_OPENER
            + " worker: error: unrelated failure\n"
            "}}\n",
            "swiftdata",
        )

        self.assertEqual(len(findings), 1)
        self.assertIn("inside permitted CoreData", findings[0].message)

    def test_coredata_terminator_cannot_hide_following_diagnostic(self) -> None:
        findings = scan(
            COREDATA_CLONE_OPENER
            + "\n"
            "}} worker: error: unrelated failure\n",
            "swiftdata",
        )

        self.assertEqual(len(findings), 1)
        self.assertIn("warning/error", findings[0].message)

    def test_unterminated_coredata_block_fails_closed(self) -> None:
        findings = scan(
            COREDATA_CLONE_OPENER
            + "\n"
            '  URL = "value.interim";\n',
            "swiftdata",
        )

        self.assertEqual(len(findings), 1)
        self.assertIn("unterminated", findings[0].message)

    def test_similar_coredata_message_is_not_whitelisted(self) -> None:
        findings = scan(
            "CoreData: error: Failed to clone external data references {\n",
            "swiftdata",
        )

        self.assertEqual(len(findings), 1)
        self.assertIn("warning/error", findings[0].message)

    def test_swiftdata_missing_profile_rejects_missing_file_outside_block(self) -> None:
        findings = scan("open failed: No such file or directory\n", "swiftdata-missing")

        self.assertEqual(len(findings), 1)
        self.assertIn("missing-file", findings[0].message)


if __name__ == "__main__":
    unittest.main()
