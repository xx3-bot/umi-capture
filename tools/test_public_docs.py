#!/usr/bin/env python3
"""Release compliance gates for public documentation and iOS source defaults.

These deliberate prose/source checks enforce the approved public release scope;
they do not substitute for capture, networking, or physical-device tests.
"""

from pathlib import Path
import json
import posixpath
import re
import struct
import subprocess
import unittest
from urllib.parse import unquote, urlsplit


ROOT = Path(__file__).resolve().parents[1]


def markdown_image_names(text: str) -> list[str]:
    return [Path(target).name for target in re.findall(r"!\[[^\]]*\]\(([^)]+)\)", text)]


def png_dimensions(path: Path) -> tuple[int, int]:
    data = path.read_bytes()[:24]
    if data[:8] != b"\x89PNG\r\n\x1a\n" or data[12:16] != b"IHDR":
        raise ValueError(f"Not a PNG with an IHDR header: {path}")
    return struct.unpack(">II", data[16:24])


def public_file_sources() -> dict[str, Path]:
    """Map public destinations to current source files, including overlays."""
    manifest_path = ROOT / "public-snapshot.json"
    if not manifest_path.is_file():
        # The exported source contains no private exporter or selection manifest.
        exported_manifest = ROOT / "PUBLIC_SOURCE_MANIFEST.json"
        if exported_manifest.is_file():
            names = json.loads(exported_manifest.read_text())["files"]
        else:
            names = subprocess.check_output(
                ["git", "-C", str(ROOT), "ls-files", "-z"], text=True
            ).split("\0")
        return {name: ROOT / name for name in names if name}
    manifest = json.loads(manifest_path.read_text())
    tracked = subprocess.check_output(
        ["git", "-C", str(ROOT), "ls-files", "-z"], text=True
    ).split("\0")
    overlays = manifest.get("overlays", {})
    result = {}
    for name in filter(None, tracked):
        included = name in manifest["include_files"] or any(
            name.startswith(prefix) for prefix in manifest["include_prefixes"]
        )
        excluded = name in manifest["exclude_files"] or any(
            name.startswith(prefix) for prefix in manifest["exclude_prefixes"]
        )
        if included and not excluded and name not in overlays:
            result[name] = ROOT / name
    result.update({target: ROOT / source for source, target in overlays.items()})
    return result


class PublicDocumentationTests(unittest.TestCase):
    def test_public_markdown_links_resolve_inside_snapshot(self):
        public_files = public_file_sources()
        for name, source in sorted(public_files.items()):
            if not name.endswith(".md"):
                continue
            text = re.sub(r"(?ms)^```.*?^```[^\n]*", "", source.read_text())
            targets = re.findall(r"\[[^\]]*\]\(\s*(<[^>]+>|[^\s)]+)", text)
            targets += re.findall(r"(?m)^\s*\[[^\]]+\]:\s*(<[^>]+>|\S+)", text)
            for target in targets:
                url = urlsplit(target.strip("<>"))
                if url.scheme or url.netloc or not url.path:
                    continue
                path = unquote(url.path)
                resolved = posixpath.normpath(
                    path.lstrip("/") if path.startswith("/")
                    else posixpath.join(posixpath.dirname(name), path)
                )
                with self.subTest(document=name, target=target):
                    self.assertTrue(resolved in public_files, f"Link target is not exported: {resolved}")
                    self.assertTrue(public_files[resolved].is_file(), "Link target is missing")

    def test_contract_index_lists_only_public_contract_files(self):
        text = (ROOT / "contracts/README.md").read_text()
        entries = re.findall(r"(?m)^- (?:`([^`]+)`|\[[^\]]+\]\(([^)]+)\)):", text)
        self.assertEqual(
            {code or link for code, link in entries},
            {"README.md", "capture-package.md", "compatibility.md", "protocol-v1.md"},
        )

    def test_readme_states_release_posture_and_supported_paths(self):
        text = (ROOT / "README.md").read_text(encoding="utf-8")
        for phrase in (
            "Experimental research software",
            "Source release only",
            "Physical-device end-to-end acceptance is still in progress",
            "python3 -m venv .venv",
            "pod install --project-directory=apps/ios",
            "Shared session time; independent ARKit spatial frames",
        ):
            with self.subTest(phrase=phrase):
                self.assertIn(phrase, text)
        self.assertNotIn("private open-source candidate", text)
        self.assertNotIn("candidate IPA", text)
        self.assertEqual(
            markdown_image_names(text),
            [
                "ios-quick-start-en.png",
                "ios-tutorial-steps-4-6-en.png",
                "ios-tutorial-steps-6-7-en.png",
            ],
        )

    def test_readme_puts_public_boundaries_and_pristine_verification_first(self):
        text = (ROOT / "README.md").read_text(encoding="utf-8")
        introduction = text.split("## Supported scope", 1)[0]
        self.assertIn("Do not expose the Receiver directly to the Internet", introduction)
        self.assertIn("independent ARKit spatial frames", introduction)
        self.assertIn("No endorsement is implied", introduction)
        self.assertIn(
            "[public physical-TCP coordinate contract](docs/public/coordinate-frames.md)",
            text,
        )
        verification = text.index("## Source verification")
        ios_build = text.index("## iOS Simulator build")
        self.assertLess(verification, ios_build)
        instructions = text[verification:ios_build]
        self.assertIn("pristine checkout", instructions)
        self.assertIn("before `pod install`", instructions)
        self.assertIn("separate clean checkout", instructions)
        self.assertNotIn("refresh", instructions.casefold())

    def test_first_release_supports_only_macos_receiver_execution(self):
        readme = (ROOT / "README.md").read_text(encoding="utf-8")
        limitations = (ROOT / "docs/public/known-limitations.md").read_text(
            encoding="utf-8"
        )
        combined = f"{readme}\n{limitations}"

        self.assertIn("Receiver execution is supported on macOS", readme)
        self.assertIn(
            "Ubuntu Receiver execution is not part of the supported first-release path",
            limitations,
        )
        self.assertIn("remains unverified", limitations)
        for stale_claim in (
            "macOS or Ubuntu",
            "Receiver on macOS and Ubuntu",
            "validated by CI on macOS and Ubuntu",
        ):
            with self.subTest(stale_claim=stale_claim):
                self.assertNotIn(stale_claim, combined)

    def test_public_contracts_distinguish_transport_from_package_validation(self):
        capture = (ROOT / "contracts/capture-package.md").read_text(encoding="utf-8")
        compatibility = (ROOT / "contracts/compatibility.md").read_text(encoding="utf-8")
        protocol = (ROOT / "contracts/protocol-v1.md").read_text(encoding="utf-8")
        security = (ROOT / "SECURITY.md").read_text(encoding="utf-8")

        for text in (capture, protocol, security):
            prose = " ".join(text.split())
            self.assertIn("whole-file size", prose)
            self.assertIn("whole-file SHA-256", prose)
            self.assertIn("does not inspect", prose)
        for text in (capture, compatibility):
            self.assertIn("no historical-package importer", text.casefold())
        for text in (compatibility, protocol):
            prose = " ".join(text.split())
            self.assertIn("does not advertise a Bonjour service", prose)
            self.assertIn("manually", prose)
        self.assertNotIn("They discover each other through", compatibility)
        self.assertNotIn("The matched applications advertise and discover", protocol)

    def test_ios_notice_identifies_public_experimental_source(self):
        notice = (ROOT / "apps/ios/NOTICE").read_text(encoding="utf-8")
        self.assertIn("experimental source release", notice)
        self.assertNotIn("private candidate", notice)

    def test_public_docs_use_existing_screenshots(self):
        path = ROOT / "docs/public/quick-start.md"
        self.assertTrue(path.is_file(), "Public quick start is missing")
        quick_start = path.read_text(encoding="utf-8")
        expected = {
            "ios-quick-start-en.png",
            "ios-tutorial-steps-4-6-en.png",
            "ios-tutorial-steps-6-7-en.png",
            "ios-role-setup-en.png",
            "ios-capture-home-en.png",
        }
        self.assertEqual(set(markdown_image_names(quick_start)), expected)
        for target in re.findall(r"!\[[^\]]*\]\(([^)]+)\)", quick_start):
            self.assertTrue((path.parent / target).is_file(), target)
        self.assertEqual(
            {path.name for path in (ROOT / "docs/public/assets").iterdir()},
            expected,
        )
        limitations = (ROOT / "docs/public/known-limitations.md").read_text(
            encoding="utf-8"
        )
        self.assertIn("five English interface screenshots", limitations)

    def test_tutorial_screenshots_exclude_scroll_indicators_and_finish_button(self):
        assets = ROOT / "docs/public/assets"
        self.assertEqual(
            png_dimensions(assets / "ios-quick-start-en.png"),
            (1180, 1820),
        )
        self.assertEqual(
            png_dimensions(assets / "ios-tutorial-steps-4-6-en.png"),
            (1180, 1650),
        )
        self.assertEqual(
            png_dimensions(assets / "ios-tutorial-steps-6-7-en.png"),
            (1180, 1024),
        )

    def test_ios_source_has_public_defaults_and_no_personal_contact(self):
        swift = "\n".join(path.read_text() for path in (ROOT / "apps/ios").rglob("*.swift"))
        self.assertNotRegex(swift, r"[\w.+-]+@[\w.-]+\.[A-Za-z]{2,}")
        self.assertNotRegex(
            swift,
            r"\b(?:10(?:\.\d{1,3}){3}|"
            r"172\.(?:1[6-9]|2\d|3[01])(?:\.\d{1,3}){2}|"
            r"192\.168(?:\.\d{1,3}){2})\b",
        )
        calibration = (ROOT / "apps/ios/UMICapture/CameraCalibrationProfile.swift").read_text()
        self.assertNotRegex(
            calibration,
            r"\b[\da-fA-F]{8}(?:-[\da-fA-F]{4}){3}-[\da-fA-F]{12}\b",
        )
        self.assertIn('feedbackAddress = "https://github.com/xx3-bot/umi-capture/issues"', swift)
        self.assertIn('private var newHostIP: String = "127.0.0.1"', swift)


if __name__ == "__main__":
    unittest.main()
