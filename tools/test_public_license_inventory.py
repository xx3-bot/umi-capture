import json
from pathlib import Path
import re
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
USER_INSTALLED = "installed by user from source dependency manifest"
EXPECTED_COMPONENTS = [
    {
        "name": "Socket.IO-Client-Swift",
        "version": "16.1.0",
        "license": "MIT",
        "source_url": (
            "https://github.com/socketio/socket.io-client-swift/tree/v16.1.0"
        ),
        "distribution": USER_INSTALLED,
    },
    {
        "name": "Starscream",
        "version": "4.0.8",
        "license": "Apache-2.0",
        "source_url": "https://github.com/daltoniam/Starscream/tree/4.0.8",
        "distribution": USER_INSTALLED,
    },
    {
        "name": "python-socketio",
        "version": "5.11.4",
        "license": "MIT",
        "source_url": (
            "https://github.com/miguelgrinberg/python-socketio/tree/v5.11.4"
        ),
        "distribution": USER_INSTALLED,
    },
    {
        "name": "eventlet",
        "version": "0.37.0",
        "license": "MIT",
        "source_url": "https://github.com/eventlet/eventlet/tree/0.37.0",
        "distribution": USER_INSTALLED,
    },
]


def public_inventory_path(root: Path) -> Path:
    staging_inventory = root / "third_party/public-inventory.json"
    if staging_inventory.is_file():
        return staging_inventory

    public_manifest = root / "PUBLIC_SOURCE_MANIFEST.json"
    if not public_manifest.is_file():
        raise FileNotFoundError(
            "public inventory unavailable: this is neither a private "
            "preparation tree nor an exported public snapshot"
        )

    exported_inventory = root / "third_party/inventory.json"
    if not exported_inventory.is_file():
        raise FileNotFoundError(
            "exported public inventory is missing: third_party/inventory.json"
        )
    return exported_inventory


class PublicInventoryPathTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary_directory.name)
        (self.root / "third_party").mkdir()

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def test_private_preparation_tree_uses_staging_inventory(self) -> None:
        staging = self.root / "third_party/public-inventory.json"
        staging.write_text("{}", encoding="utf-8")
        (self.root / "PUBLIC_SOURCE_MANIFEST.json").write_text(
            "{}", encoding="utf-8"
        )
        (self.root / "third_party/inventory.json").write_text(
            "{}", encoding="utf-8"
        )
        self.assertEqual(public_inventory_path(self.root), staging)

    def test_exported_public_tree_uses_overlaid_inventory(self) -> None:
        exported = self.root / "third_party/inventory.json"
        exported.write_text("{}", encoding="utf-8")
        (self.root / "PUBLIC_SOURCE_MANIFEST.json").write_text(
            "{}", encoding="utf-8"
        )
        self.assertEqual(public_inventory_path(self.root), exported)

    def test_exported_public_tree_requires_overlaid_inventory(self) -> None:
        (self.root / "PUBLIC_SOURCE_MANIFEST.json").write_text(
            "{}", encoding="utf-8"
        )
        with self.assertRaisesRegex(
            FileNotFoundError, "exported public inventory is missing"
        ):
            public_inventory_path(self.root)

    def test_ordinary_checkout_never_falls_back_to_private_inventory(
        self,
    ) -> None:
        (self.root / "third_party/inventory.json").write_text(
            "not public", encoding="utf-8"
        )
        with self.assertRaisesRegex(
            FileNotFoundError, "neither a private preparation tree nor an exported"
        ):
            public_inventory_path(self.root)


class PublicLicenseInventoryTests(unittest.TestCase):
    def setUp(self) -> None:
        inventory_path = public_inventory_path(ROOT)
        payload = json.loads(inventory_path.read_text(encoding="utf-8"))
        self.components = payload["components"]

    def test_public_inventory_has_exact_component_count(self) -> None:
        self.assertEqual(len(self.components), 4)

    def test_public_inventory_has_no_duplicate_names(self) -> None:
        names = [item["name"] for item in self.components]
        self.assertEqual(len(names), len(set(names)))

    def test_public_inventory_matches_exact_dependency_records(self) -> None:
        self.assertCountEqual(self.components, EXPECTED_COMPONENTS)

    def test_public_inventory_versions_are_pinned_in_source_manifests(self) -> None:
        inventory = {
            item["name"]: item["version"] for item in self.components
        }

        podfile_lock = (ROOT / "apps/ios/Podfile.lock").read_text(encoding="utf-8")
        pod_versions = dict(
            re.findall(
                r"^  - ([^ (]+) \((\d+(?:\.\d+)+)\)(?::)?$",
                podfile_lock,
                re.MULTILINE,
            )
        )
        self.assertEqual(
            {
                name: inventory[name]
                for name in ("Socket.IO-Client-Swift", "Starscream")
            },
            {
                name: pod_versions[name]
                for name in ("Socket.IO-Client-Swift", "Starscream")
            },
        )

        requirements = (
            ROOT / "apps/macos/requirements-receiver.txt"
        ).read_text(encoding="utf-8").splitlines()
        requirement_versions = dict(
            line.split("==", 1)
            for line in requirements
            if line and not line.startswith("#")
        )
        self.assertEqual(
            {
                name: inventory[name]
                for name in ("python-socketio", "eventlet")
            },
            requirement_versions,
        )


if __name__ == "__main__":
    unittest.main()
