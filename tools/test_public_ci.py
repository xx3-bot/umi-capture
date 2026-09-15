"""Release compliance gates for public CI and its local entrypoint."""

from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[1]


class PublicCITests(unittest.TestCase):
    def setUp(self):
        self.workflow = (ROOT / ".github/workflows/ci.yml").read_text()

    def job(self, name):
        match = re.search(
            rf"^  {re.escape(name)}:\n(.*?)(?=^  [\w-]+:\n|\Z)",
            self.workflow, re.MULTILINE | re.DOTALL,
        )
        self.assertIsNotNone(match, f"Missing public CI job: {name}")
        return match.group(1)

    def test_ci_uses_only_public_build_paths(self):
        for token in (
            "name: Public source CI", "tools/verify_public_source.sh",
            "generic/platform=iOS Simulator",
            "CODE_SIGNING_ALLOWED=NO", "gitleaks/gitleaks-action",
        ):
            self.assertIn(token, self.workflow)
        for forbidden in (
            "website", "npm ", "RuntimePayload.tar.xz",
            "verify_private_candidate.sh", "DEVELOPMENT_TEAM",
            "requirements-dev.txt", "apps/macos/Scripts/", "setup-node",
            "upload-artifact", "deploy-pages", "publish", "release upload",
        ):
            self.assertNotIn(forbidden, self.workflow)

    def test_ci_has_only_first_release_jobs(self):
        jobs = self.workflow.split("jobs:\n", 1)[-1]
        self.assertCountEqual(
            re.findall(r"^  ([\w-]+):$", jobs, re.MULTILINE),
            ["source-tests", "ios-build", "public-boundary"],
        )

    def test_macos_source_job_owns_first_release_receiver_verification(self):
        self.assertNotIn("receiver-smoke:", self.workflow)
        job = self.job("source-tests")
        self.assertIn("runs-on: macos-15", job)
        self.assertIn("actions/setup-python@v5", job)
        self.assertIn("python-version: '3.12'", job)
        self.assertIn("pip install -r apps/macos/requirements-receiver.txt", job)
        self.assertIn("- run: tools/verify_public_source.sh", job)

        boundary_job = self.job("public-boundary")
        self.assertNotIn("requirements-receiver.txt", boundary_job)
        self.assertNotIn("source_receiver_smoke.py", boundary_job)

    def test_ios_build_installs_pods_before_unsigned_simulator_build(self):
        job = self.job("ios-build")
        self.assertIn("runs-on: macos-15", job)
        self.assertLess(job.index("pod install --project-directory=apps/ios"), job.index("xcodebuild build"))
        for token in (
            "-workspace apps/ios/UMICapture.xcworkspace", "-scheme UMICapture",
            "generic/platform=iOS Simulator", "CODE_SIGNING_ALLOWED=NO",
        ):
            self.assertIn(token, job)

    def test_history_scan_has_read_only_permissions_and_full_checkout(self):
        self.assertRegex(self.workflow, r"(?m)^permissions:\n  contents: read\n")
        self.assertNotRegex(self.workflow, r":\s*write(?:-all)?\b")
        job = self.job("public-boundary")
        self.assertRegex(
            job,
            r"(?m)^    permissions:\n      contents: read\n      pull-requests: read\n",
        )
        self.assertIn("actions/checkout@v4", job)
        self.assertIn("fetch-depth: 0", job)
        self.assertIn("gitleaks/gitleaks-action@v2", job)

    def test_verifier_is_executable_and_runs_public_checks_in_order(self):
        path = ROOT / "tools/verify_public_source.sh"
        self.assertTrue(path.is_file(), "Canonical public verifier is missing")
        self.assertTrue(path.stat().st_mode & 0o111, "Verifier must retain executable mode")
        script = path.read_text()
        self.assertIn('PYTHON_BIN="${PYTHON:-python3}"', script)
        self.assertIn("set -euo pipefail", script)
        self.assertIn("export PYTHONDONTWRITEBYTECODE=1", script)
        checks = (
            "tools/test_ios_product_boundary.py", "tools/test_public_docs.py",
            "tools/test_public_license_inventory.py", "tools/test_public_release_gate.py",
            "tools/test_public_ci.py", "env PYTHONPATH=apps/macos/Resources/Receiver",
            "apps/macos/Tests/test_capture_upload.py", "apps/macos/Tests/test_dual_capture.py",
            "apps/macos/Tests/test_receiver_web.py", '"$PYTHON_BIN" tools/source_receiver_smoke.py',
            '"$PYTHON_BIN" tools/public_release_gate.py --root .', "git diff --check",
        )
        positions = []
        for check in checks:
            self.assertIn(check, script)
            positions.append(script.index(check))
        self.assertEqual(positions, sorted(positions))
        for forbidden in (
            "pip install", "pod install", "npm", "website", "RuntimePayload",
            "git add", "git commit", "git init", "git reset", "git checkout",
        ):
            self.assertNotIn(forbidden, script)


if __name__ == "__main__":
    unittest.main()
