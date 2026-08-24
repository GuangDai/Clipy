#!/usr/bin/env python3
"""Validate Card 16A's unsigned ordinary Clipy archive identity contract."""

from __future__ import annotations

import argparse
import json
import plistlib
import re
import sys
from pathlib import Path
from typing import Any

RELEASE_REF = re.compile(r"refs/tags/release/([^/]+)/([1-9][0-9]*)")
EXPECTED_BUNDLE_ID = "com.clipy.ClipyApp"
EXPECTED_EXECUTABLE = "Clipy"
EXPECTED_CATEGORY = "public.app-category.utilities"
EXPECTED_ICON = "AppIcon"
EXPECTED_DEPLOYMENT = "26.0"
EXPECTED_ENTITLEMENTS_SUFFIX = "ClipyApp/Config/ClipyApp.entitlements"


def _load_plist(path: Path, errors: list[str]) -> dict[str, Any]:
    try:
        value = plistlib.loads(path.read_bytes())
    except (OSError, plistlib.InvalidFileException) as error:
        errors.append(f"cannot read plist {path}: {error}")
        return {}
    if not isinstance(value, dict):
        errors.append(f"plist root is not a dictionary: {path}")
        return {}
    return value


def _load_settings(path: Path, errors: list[str]) -> dict[str, str]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        errors.append(f"cannot read build settings {path}: {error}")
        return {}
    if not isinstance(value, list) or len(value) != 1:
        errors.append("build settings must contain exactly one target")
        return {}
    settings = value[0].get("buildSettings")
    if not isinstance(settings, dict):
        errors.append("build settings entry lacks buildSettings dictionary")
        return {}
    return {str(key): str(item) for key, item in settings.items()}


def _expect(
    actual: object,
    expected: object,
    label: str,
    errors: list[str],
) -> None:
    if actual != expected:
        errors.append(f"{label}: expected {expected!r}, found {actual!r}")


def validate(
    archive: Path,
    settings_path: Path,
    release_ref: str,
    ref_protected: str,
) -> list[str]:
    errors: list[str] = []
    match = RELEASE_REF.fullmatch(release_ref)
    if match is None:
        errors.append("release ref must match refs/tags/release/<marketing>/<build>")
        marketing = ""
        build = ""
    else:
        marketing, build = match.groups()
    if ref_protected != "true":
        errors.append("release ref is not protected")

    app = archive / "Products" / "Applications" / "Clipy.app"
    info = _load_plist(app / "Contents" / "Info.plist", errors)
    archive_info = _load_plist(archive / "Info.plist", errors)
    settings = _load_settings(settings_path, errors)

    _expect(info.get("CFBundleIdentifier"), EXPECTED_BUNDLE_ID, "bundle ID", errors)
    _expect(info.get("CFBundleExecutable"), EXPECTED_EXECUTABLE, "executable", errors)
    _expect(info.get("CFBundleShortVersionString"), marketing, "marketing version", errors)
    _expect(info.get("CFBundleVersion"), build, "build version", errors)
    _expect(info.get("LSApplicationCategoryType"), EXPECTED_CATEGORY, "category", errors)
    _expect(info.get("LSUIElement"), True, "LSUIElement", errors)
    _expect(info.get("CFBundleIconName"), EXPECTED_ICON, "icon name", errors)

    executable = app / "Contents" / "MacOS" / EXPECTED_EXECUTABLE
    if not executable.is_file():
        errors.append(f"missing expected executable: {executable}")
    if not (app / "Contents" / "Resources" / "Assets.car").is_file():
        errors.append("archive is missing compiled Assets.car")
    if (app / "Contents" / "_CodeSignature").exists():
        errors.append("Card 16A archive must remain unsigned")

    nested_products = sorted(
        path.relative_to(archive).as_posix()
        for suffix in ("*.app", "*.xpc", "*.appex")
        for path in archive.rglob(suffix)
    )
    expected_products = ["Products/Applications/Clipy.app"]
    if nested_products != expected_products:
        errors.append(
            f"archive product set: expected {expected_products!r}, "
            f"found {nested_products!r}"
        )

    properties = archive_info.get("ApplicationProperties")
    if not isinstance(properties, dict):
        errors.append("archive Info.plist lacks ApplicationProperties")
    else:
        _expect(
            properties.get("ApplicationPath"),
            "Applications/Clipy.app",
            "archive application path",
            errors,
        )
        _expect(
            properties.get("CFBundleIdentifier"),
            EXPECTED_BUNDLE_ID,
            "archive bundle ID",
            errors,
        )
        _expect(
            properties.get("CFBundleShortVersionString"),
            marketing,
            "archive marketing version",
            errors,
        )
        _expect(
            properties.get("CFBundleVersion"),
            build,
            "archive build version",
            errors,
        )

    expected_settings = {
        "PRODUCT_BUNDLE_IDENTIFIER": EXPECTED_BUNDLE_ID,
        "MARKETING_VERSION": marketing,
        "CURRENT_PROJECT_VERSION": build,
        "EXECUTABLE_NAME": EXPECTED_EXECUTABLE,
        "WRAPPER_NAME": "Clipy.app",
        "INFOPLIST_KEY_LSApplicationCategoryType": EXPECTED_CATEGORY,
        "ASSETCATALOG_COMPILER_APPICON_NAME": EXPECTED_ICON,
        "MACOSX_DEPLOYMENT_TARGET": EXPECTED_DEPLOYMENT,
        "CODE_SIGNING_ALLOWED": "NO",
    }
    for key, expected in expected_settings.items():
        _expect(settings.get(key), expected, f"build setting {key}", errors)
    if "arm64" not in settings.get("ARCHS", "").split():
        errors.append("build setting ARCHS does not contain arm64")
    entitlements = settings.get("CODE_SIGN_ENTITLEMENTS", "")
    if not entitlements.endswith(EXPECTED_ENTITLEMENTS_SUFFIX):
        errors.append(
            "entitlements build setting does not name the approved file"
        )
    return errors


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--archive", type=Path, required=True)
    parser.add_argument("--build-settings", type=Path, required=True)
    parser.add_argument("--release-ref", required=True)
    parser.add_argument("--ref-protected", required=True)
    args = parser.parse_args()
    errors = validate(
        args.archive,
        args.build_settings,
        args.release_ref,
        args.ref_protected,
    )
    if errors:
        for error in errors:
            print(f"release_archive: error: {error}", file=sys.stderr)
        return 1
    print("release_archive: OK — protected ref and unsigned archive identity match")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
