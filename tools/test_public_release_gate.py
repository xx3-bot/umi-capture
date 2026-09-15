#!/usr/bin/env python3
"""Behavioral public-tree checks using only synthetic privacy fixtures."""

from __future__ import annotations

import hashlib
import json
import subprocess
import tempfile
import unittest
import uuid
from pathlib import Path

from tools.public_release_gate import audit_public_tree


SOURCE_ROOT = Path(__file__).resolve().parents[1]
MANIFEST = "PUBLIC_SOURCE_MANIFEST.json"
SAFE_UUIDS = (
    "11111111-1111-4111-8111-111111111111",
    "22222222-2222-4222-8222-222222222222",
    "33333333-3333-4333-8333-333333333333",
)
FORBIDDEN_FIXTURES = {
    "personal path": ("notes.txt", "/Users/example/private/file"),
    "signing team": ("project.pbxproj", "DEVELOPMENT_TEAM = TESTTEAM00;"),
    "private key": ("key.txt", "-----BEGIN PRIVATE " + "KEY-----"),
    "capture archive": ("capture.zip", b"PK\x03\x04"),
    "real video": ("capture.mp4", b"video"),
    "provisioning profile": ("app.mobileprovision", b"profile"),
    "personal email": ("notes.txt", "fixture@synthetic.invalid"),
    "IP address": ("notes.txt", "10.99.88.77"),
    "UUID": ("notes.txt", str(uuid.UUID(int=42))),
    "binary artifact": ("executable", b"\x7fELF\x00\x01\x02"),
    "private asset": ("private-artifacts/notes.txt", "private"),
}


class PublicReleaseGateTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.parent = Path(self.temporary.name)
        self.root = self.parent / "snapshot"
        self.root.mkdir()

    def write(self, name, value):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(value.encode("utf-8") if isinstance(value, str) else value)
        return path

    def manifest(self):
        files = {
            path.relative_to(self.root).as_posix(): hashlib.sha256(path.read_bytes()).hexdigest()
            for path in self.root.rglob("*")
            if path.is_file() and not path.is_symlink()
            and path.name != MANIFEST and ".git" not in path.relative_to(self.root).parts
        }
        self.write(MANIFEST, json.dumps({"schema_version": 1, "source_commit": "a" * 40, "files": files}))

    def rules(self):
        return {finding.rule for finding in audit_public_tree(self.root)}

    def git(self, *args):
        return subprocess.check_output(["git", "-C", str(self.root), *args], stderr=subprocess.PIPE)

    def track(self):
        self.git("init")
        self.git("add", "--all")

    def test_each_forbidden_fixture_is_reported(self):
        for label, (name, value) in FORBIDDEN_FIXTURES.items():
            with self.subTest(label=label):
                path = self.write(name, value)
                self.manifest()
                self.assertIn(label, self.rules())
                path.unlink()

    def test_rejects_all_forbidden_suffixes_case_insensitively_and_in_parents(self):
        for suffix in ("ipa", "zip", "mov", "mp4", "raw", "pem", "p12", "mobileprovision", "xcarchive", "xcresult"):
            for name in (f"artifact.{suffix.upper()}", f"bundle.{suffix}/contents.txt"):
                with self.subTest(name=name):
                    path = self.write(name, "synthetic")
                    self.manifest()
                    self.assertTrue(audit_public_tree(self.root))
                    path.unlink()

    def test_rejects_symlinks_including_directory_and_dangling_links(self):
        self.write("safe.txt", "safe")
        for name, target in (("link", "safe.txt"), ("missing-link", "missing"), ("directory-link", ".")):
            with self.subTest(name=name):
                link = self.root / name
                link.symlink_to(target)
                self.manifest()
                self.assertIn("symlink", self.rules())
                link.unlink()

    def test_rejects_file_larger_than_five_mib(self):
        self.write("large.txt", b"x" * (5 * 1024 * 1024 + 1))
        self.manifest()
        self.assertIn("oversize file", self.rules())

    def test_accepts_five_mib_boundary(self):
        self.write("large.txt", b"x" * (5 * 1024 * 1024))
        self.manifest()
        self.assertEqual(audit_public_tree(self.root), [])

    def test_rejects_non_example_ipv4_addresses(self):
        for address in ("172.20.99.88", "192.168.99.88", "8.8.4.4", "127.0.0.2"):
            with self.subTest(address=address):
                self.write("endpoint.txt", f"http://{address}:8765/")
                self.manifest()
                self.assertIn("IP address", self.rules())

    def test_accepts_explicit_example_addresses_and_empty_signing(self):
        self.write("examples.txt", '\n'.join((
            "127.0.0.1 0.0.0.0 192.0.2.1 192.0.2.255 198.51.100.9 203.0.113.8",
            "fixture@example.com fixture@example.org fixture@example.net",
            'DEVELOPMENT_TEAM = "";',
        )))
        self.manifest()
        self.assertEqual(audit_public_tree(self.root), [])

    def test_rejects_email_with_misleading_example_suffix(self):
        self.write("notes.txt", "fixture@example.com.synthetic.invalid")
        self.manifest()
        self.assertIn("personal email", self.rules())

    def test_detects_quoted_signing_team_and_other_private_key_headers(self):
        for content in ('DEVELOPMENT_TEAM = "TESTTEAM00";', "-----BEGIN RSA PRIVATE " + "KEY-----", "-----BEGIN OPENSSH PRIVATE " + "KEY-----"):
            with self.subTest(content=content):
                self.write("settings.txt", content)
                self.manifest()
                self.assertTrue(self.rules() & {"signing team", "private key"})

    def test_only_three_synthetic_uuids_are_allowed_only_in_test_files(self):
        for name in ("tools/test_fixture.py", "apps/ios/ExampleTests/IdentityTests.swift"):
            path = self.write(name, "\n".join(SAFE_UUIDS))
            self.manifest()
            self.assertEqual(audit_public_tree(self.root), [])
            path.unlink()
        self.write("README.md", SAFE_UUIDS[0])
        self.manifest()
        self.assertIn("UUID", self.rules())

    def test_rejects_other_synthetic_uuid_even_in_test_file(self):
        self.write("tools/test_fixture.py", str(uuid.UUID(int=42)))
        self.manifest()
        self.assertIn("UUID", self.rules())

    def test_scans_relative_path_as_well_as_content(self):
        self.write("notes/fixture@synthetic.invalid.txt", "safe text")
        self.manifest()
        self.assertIn("personal email", self.rules())

    def test_accepts_known_safe_simulator_png(self):
        name = "docs/public/assets/ios-quick-start-en.png"
        self.write(name, (SOURCE_ROOT / name).read_bytes())
        self.manifest()
        self.assertEqual(audit_public_tree(self.root), [])

    def test_rejects_unknown_png_and_changed_approved_png(self):
        for name in ("capture.png", "docs/public/assets/ios-quick-start-en.png"):
            with self.subTest(name=name):
                path = self.write(name, b"\x89PNG\r\n\x1a\nsynthetic")
                self.manifest()
                self.assertIn("binary artifact", self.rules())
                path.unlink()

    def test_binary_artifact_paths_cannot_pass_by_containing_only_text(self):
        for name in ("capture.jpg", "capture.heic", "guide.pdf", "library.dylib", "archive.tar", "Application.app/Info.plist"):
            with self.subTest(name=name):
                path = self.write(name, "synthetic")
                self.manifest()
                self.assertIn("binary artifact", self.rules())
                path.unlink()

    def test_rejects_text_only_resource_bundle(self):
        self.write("Resources.bundle/Info.plist", "synthetic resource metadata")
        self.manifest()
        self.assertIn("binary artifact", self.rules())

    def test_pre_git_traversal_permission_errors_fail_closed(self):
        self.write("README.md", "safe")
        self.manifest()
        self.write("unreadable/hidden.txt", "synthetic unmanifested content")
        unreadable = self.root / "unreadable"
        unreadable.chmod(0)
        try:
            # Confirm this filesystem actually denies traversal before exercising
            # the gate; an unnoticed permission bypass must not weaken the test.
            with self.assertRaises(PermissionError):
                list(unreadable.iterdir())
            self.assertIn("tree unreadable", self.rules())
        finally:
            unreadable.chmod(0o700)

    def test_rejects_missing_manifest(self):
        self.write("README.md", "safe")
        self.assertIn("manifest missing", self.rules())

    def test_rejects_missing_manifest_entry(self):
        self.manifest()
        self.write("README.md", "safe")
        self.assertIn("manifest missing entry", self.rules())

    def test_rejects_manifest_entry_for_absent_file(self):
        self.write("README.md", "safe")
        self.manifest()
        (self.root / "README.md").unlink()
        self.assertIn("manifest unexpected entry", self.rules())

    def test_rejects_manifest_hash_mismatch(self):
        self.write("README.md", "safe")
        self.manifest()
        self.write("README.md", "changed")
        self.assertIn("manifest hash mismatch", self.rules())

    def test_rejects_malformed_manifest_and_unsafe_names(self):
        for content in ("not json", "[]", '{"files": []}', '{"schema_version": 1, "files": {"../outside": "' + "a" * 64 + '"}}', '{"schema_version": 1, "files": {"file": "wrong"}}'):
            with self.subTest(content=content):
                self.write(MANIFEST, content)
                self.assertIn("manifest invalid", self.rules())

    def test_rejects_duplicate_manifest_keys(self):
        self.write(MANIFEST, '{"schema_version": 1, "files": {}, "files": {}}')
        self.assertIn("manifest invalid", self.rules())

    def test_manifest_content_is_scanned(self):
        self.manifest()
        payload = json.loads((self.root / MANIFEST).read_text())
        payload["note"] = "fixture@synthetic.invalid"
        self.write(MANIFEST, json.dumps(payload))
        self.assertIn("personal email", self.rules())

    def test_only_gate_and_gate_test_have_content_exemptions_but_are_hashed(self):
        for name in ("tools/public_release_gate.py", "tools/test_public_release_gate.py"):
            self.write(name, "fixture@synthetic.invalid")
        self.manifest()
        self.assertEqual(audit_public_tree(self.root), [])
        self.write("tools/public_release_gate.py", "changed")
        self.assertIn("manifest hash mismatch", self.rules())
        self.write("tools/test_other.py", "fixture@synthetic.invalid")
        self.manifest()
        self.assertIn("personal email", self.rules())

    def test_git_mode_ignores_administration_and_untracked_build_output(self):
        self.write("README.md", "safe")
        self.write(".gitignore", "build/\nnode_modules/\n")
        self.manifest()
        self.track()
        self.write("build/capture.mp4", b"video")
        self.write("node_modules/private.key", "fixture@synthetic.invalid")
        self.write(".git/private-note", "fixture@synthetic.invalid")
        self.assertEqual(audit_public_tree(self.root), [])

    def test_pre_git_mode_does_not_hide_ignored_build_artifacts(self):
        self.write(".gitignore", "build/\n")
        self.write("build/capture.mp4", b"video")
        self.manifest()
        self.assertIn("real video", self.rules())

    def test_rejects_unexpected_tracked_file(self):
        self.write("README.md", "safe")
        self.manifest()
        self.track()
        self.write("unexpected.txt", "safe")
        self.git("add", "unexpected.txt")
        self.assertIn("manifest missing entry", self.rules())

    def test_rejects_missing_tracked_file(self):
        self.write("README.md", "safe")
        self.manifest()
        self.track()
        (self.root / "README.md").unlink()
        self.assertIn("missing file", self.rules())

    def test_tracked_clean_clone_passes(self):
        self.write("README.md", "safe")
        self.manifest()
        self.track()
        self.git("-c", "user.name=Fixture", "-c", "user.email=fixture@example.com", "commit", "-m", "synthetic snapshot")
        clone = self.parent / "clone"
        self.git("clone", "--quiet", str(self.root), str(clone))
        self.assertEqual(audit_public_tree(clone), [])

    def test_cli_exits_nonzero_on_findings_and_zero_on_clean_tree(self):
        self.write("README.md", "safe")
        self.manifest()
        command = ["python3", str(SOURCE_ROOT / "tools/public_release_gate.py"), "--root", str(self.root)]
        self.assertEqual(subprocess.run(command, capture_output=True).returncode, 0)
        self.write("README.md", "changed")
        result = subprocess.run(command, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("manifest hash mismatch", result.stdout)


if __name__ == "__main__":
    unittest.main()
