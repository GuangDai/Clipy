from __future__ import annotations

import json
import plistlib
import tempfile
import unittest
from pathlib import Path

from scripts.ci.validate_release_archive import validate


class ReleaseArchiveValidationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.archive = self.root / "Clipy.xcarchive"
        self.app = self.archive / "Products" / "Applications" / "Clipy.app"
        (self.app / "Contents" / "MacOS").mkdir(parents=True)
        (self.app / "Contents" / "Resources").mkdir(parents=True)
        (self.app / "Contents" / "MacOS" / "Clipy").touch()
        (self.app / "Contents" / "Resources" / "Assets.car").touch()
        self.settings_path = self.root / "build-settings.json"
        self._write_plists()
        self._write_settings()

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def _write_plists(self, **overrides: object) -> None:
        info = {
            "CFBundleIdentifier": "com.clipy.ClipyApp",
            "CFBundleExecutable": "Clipy",
            "CFBundleShortVersionString": "0.1.0",
            "CFBundleVersion": "1",
            "LSApplicationCategoryType": "public.app-category.utilities",
            "LSUIElement": True,
            "CFBundleIconName": "AppIcon",
        }
        info.update(overrides)
        (self.app / "Contents" / "Info.plist").write_bytes(
            plistlib.dumps(info)
        )
        archive_info = {
            "ApplicationProperties": {
                "ApplicationPath": "Applications/Clipy.app",
                "CFBundleIdentifier": "com.clipy.ClipyApp",
                "CFBundleShortVersionString": "0.1.0",
                "CFBundleVersion": "1",
            }
        }
        self.archive.mkdir(exist_ok=True)
        (self.archive / "Info.plist").write_bytes(plistlib.dumps(archive_info))

    def _write_settings(self, **overrides: str) -> None:
        settings = {
            "PRODUCT_BUNDLE_IDENTIFIER": "com.clipy.ClipyApp",
            "MARKETING_VERSION": "0.1.0",
            "CURRENT_PROJECT_VERSION": "1",
            "EXECUTABLE_NAME": "Clipy",
            "WRAPPER_NAME": "Clipy.app",
            "INFOPLIST_KEY_LSApplicationCategoryType": "public.app-category.utilities",
            "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
            "MACOSX_DEPLOYMENT_TARGET": "26.0",
            "ARCHS": "arm64",
            "CODE_SIGN_ENTITLEMENTS": "ClipyApp/Config/ClipyApp.entitlements",
        }
        settings.update(overrides)
        self.settings_path.write_text(
            json.dumps([{"target": "ClipyApp", "buildSettings": settings}]),
            encoding="utf-8",
        )

    def _errors(
        self,
        release_ref: str = "refs/tags/release/0.1.0/1",
        protected: str = "true",
    ) -> list[str]:
        return validate(
            self.archive,
            self.settings_path,
            release_ref,
            protected,
        )

    def test_complete_fixture_passes(self) -> None:
        self.assertEqual(self._errors(), [])

    def test_ref_shape_and_protection_fail_closed(self) -> None:
        self.assertTrue(self._errors("refs/heads/master"))
        self.assertIn("release ref is not protected", self._errors(protected="false"))

    def test_tag_versions_must_match_archive_and_settings(self) -> None:
        errors = self._errors("refs/tags/release/0.2.0/9")
        self.assertTrue(any("marketing version" in error for error in errors))
        self.assertTrue(any("build version" in error for error in errors))

    def test_bundle_executable_category_icon_and_entitlements_are_required(self) -> None:
        self._write_plists(
            CFBundleIdentifier="wrong.bundle",
            CFBundleExecutable="Wrong",
            LSApplicationCategoryType="wrong.category",
            CFBundleIconName="WrongIcon",
        )
        self._write_settings(CODE_SIGN_ENTITLEMENTS="")
        errors = self._errors()
        for label in ("bundle ID", "executable", "category", "icon name", "entitlements"):
            self.assertTrue(any(label in error for error in errors), label)

    def test_arm64_assets_and_ordinary_product_set_are_required(self) -> None:
        (self.app / "Contents" / "Resources" / "Assets.car").unlink()
        self._write_settings(ARCHS="x86_64")
        helper = self.archive / "Products" / "Applications" / "Helper.app"
        helper.mkdir()
        errors = self._errors()
        self.assertTrue(any("Assets.car" in error for error in errors))
        self.assertTrue(any("ARCHS" in error for error in errors))
        self.assertTrue(any("product set" in error for error in errors))


class ReleaseArchiveWorkflowContractTests(unittest.TestCase):
    def test_manual_protected_same_sha_contract_is_present(self) -> None:
        root = Path(__file__).resolve().parents[2]
        workflow = (root / ".github/workflows/release-archive.yml").read_text(
            encoding="utf-8"
        )
        self.assertIn("workflow_dispatch:", workflow)
        self.assertNotIn("pull_request:", workflow)
        self.assertNotIn("push:", workflow)
        self.assertIn("uses: ./.github/workflows/correctness.yml", workflow)
        self.assertIn("needs: correctness", workflow)
        self.assertIn("ref: ${{ github.sha }}", workflow)
        self.assertIn('GITHUB_REF_PROTECTED', workflow)
        self.assertEqual(workflow.count("uses: actions/checkout@v6"), 1)
        self.assertNotIn("sha256", workflow.lower())
        self.assertNotIn("checksum", workflow.lower())


if __name__ == "__main__":
    unittest.main()
