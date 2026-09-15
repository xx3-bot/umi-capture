from __future__ import annotations

import hashlib
import io
import tempfile
import unittest
from pathlib import Path

from capture_upload import CaptureUploadError, CaptureUploadStore


class CaptureUploadStoreTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.store = CaptureUploadStore(Path(self.temporary.name))

    @staticmethod
    def _metadata(payload: bytes, *, digest: str | None = None) -> dict:
        metadata = {
            "filename": "capture.zip",
            "device_id": "device-1",
            "size_bytes": len(payload),
            "sha256": digest or hashlib.sha256(payload).hexdigest(),
        }
        grant = CaptureUploadStore._test_only_grant(metadata)
        grant["file_identity"] = {
            **metadata,
            "platform": "iOS",
        }
        metadata["authorization_grant"] = grant
        return metadata

    def test_resumable_chunks_commit_only_after_size_and_hash_match(self) -> None:
        payload = b"UMICapture resumable capture payload"
        metadata = self._metadata(payload)
        initialized = self.store.initialize(metadata)
        upload_id = initialized["upload_id"]
        self.assertEqual(initialized["next_offset"], 0)
        midpoint = 11
        first = self.store.append(upload_id, 0, midpoint, io.BytesIO(payload[:midpoint]))
        self.assertEqual(first["next_offset"], midpoint)
        resumed = self.store.initialize(metadata)
        self.assertEqual(resumed["next_offset"], midpoint)
        with self.assertRaisesRegex(CaptureUploadError, "offset mismatch"):
            self.store.append(upload_id, 0, 1, io.BytesIO(b"x"))
        self.store.append(
            upload_id,
            midpoint,
            len(payload) - midpoint,
            io.BytesIO(payload[midpoint:]),
        )
        committed = self.store.finish(upload_id)
        self.assertTrue(committed["complete"])
        stored = Path(committed["stored_path"])
        self.assertEqual(stored.read_bytes(), payload)
        self.assertEqual(self.store.initialize(metadata)["stored_path"], str(stored))

    def test_checksum_failure_does_not_commit_and_resets_partial(self) -> None:
        payload = b"payload"
        metadata = self._metadata(payload, digest="0" * 64)
        upload_id = self.store.initialize(metadata)["upload_id"]
        self.store.append(upload_id, 0, len(payload), io.BytesIO(payload))
        with self.assertRaisesRegex(CaptureUploadError, "checksum"):
            self.store.finish(upload_id)
        self.assertEqual(self.store.initialize(metadata)["next_offset"], 0)
        self.assertFalse(any(Path(self.temporary.name).glob("*/*.zip")))

    def test_short_chunk_is_rolled_back(self) -> None:
        payload = b"123456"
        metadata = self._metadata(payload)
        upload_id = self.store.initialize(metadata)["upload_id"]
        with self.assertRaisesRegex(CaptureUploadError, "ended before"):
            self.store.append(upload_id, 0, len(payload), io.BytesIO(b"12"))
        self.assertEqual(self.store.initialize(metadata)["next_offset"], 0)

    def test_ios_exact_init_contract_generates_stable_server_upload_id(self) -> None:
        payload = b"iOS exact upload contract"
        metadata = {
            "filename": "hand_20260813_120000.zip",
            "device_id": "11111111-1111-4111-8111-111111111111",
            "platform": "iOS",
            "size_bytes": len(payload),
            "sha256": hashlib.sha256(payload).hexdigest(),
        }
        grant = CaptureUploadStore._test_only_grant(metadata)
        grant["file_identity"] = dict(metadata)
        metadata["authorization_grant"] = grant
        first = self.store.initialize(metadata)
        self.assertRegex(first["upload_id"], r"^[0-9a-f]{32}$")
        self.store.append(first["upload_id"], 0, 4, io.BytesIO(payload[:4]))
        retry = self.store.initialize(metadata)
        self.assertEqual(retry["upload_id"], first["upload_id"])
        self.assertEqual(retry["next_offset"], 4)

    def test_completed_sidecars_do_not_collide_for_dotted_zip_names(self) -> None:
        for filename, payload in (("capture.zip", b"first"), ("capture.upload.zip", b"second")):
            metadata = self._metadata(payload)
            metadata["filename"] = filename
            metadata["authorization_grant"]["file_identity"]["filename"] = filename
            upload_id = self.store.initialize(metadata)["upload_id"]
            self.store.append(upload_id, 0, len(payload), io.BytesIO(payload))
            self.store.finish(upload_id)
        device_root = Path(self.temporary.name) / "device-1"
        self.assertTrue((device_root / "capture.zip.upload.json").is_file())
        self.assertTrue((device_root / "capture.upload.zip.upload.json").is_file())


if __name__ == "__main__":
    unittest.main()
