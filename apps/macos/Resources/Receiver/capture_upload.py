#!/usr/bin/env python3
"""Bounded, resumable and hash-verified UMI Capture upload storage."""

from __future__ import annotations

import hashlib
import json
import os
import re
import secrets
from datetime import datetime, timezone
from pathlib import Path
from typing import BinaryIO, Optional


MAX_CAPTURE_ARCHIVE_BYTES = 64 * 1024 * 1024 * 1024
MAX_CAPTURE_CHUNK_BYTES = 32 * 1024 * 1024
CAPTURE_STREAM_CHUNK_BYTES = 1024 * 1024
_SAFE_COMPONENT = re.compile(r"[^A-Za-z0-9._-]+")


class CaptureUploadError(ValueError):
    def __init__(self, message: str, status: str = "400 Bad Request"):
        super().__init__(message)
        self.status = status


class CaptureUploadStore:
    """Persist one append-only partial file and atomically commit after SHA-256."""

    def __init__(self, root: Path):
        self.root = root.expanduser().resolve()
        self.partial_root = self.root / ".partial"
        self.root.mkdir(parents=True, exist_ok=True)
        self.partial_root.mkdir(parents=True, exist_ok=True)

    @staticmethod
    def _test_only_grant(payload: dict) -> dict:
        """Focused Store tests bypass the coordinator with an explicit grant."""
        return {
            "schema_version": 1,
            "session_id": "store-test",
            "generation": 1,
            "device_id": payload["device_id"],
            "capture_role": "wrist_umi",
            "authorized_coordinator_monotonic_ns": "1",
        }

    def initialize(self, payload: dict) -> dict:
        if not isinstance(payload, dict):
            raise CaptureUploadError("Upload metadata must be a JSON object.")
        filename = self._safe_zip_filename(payload.get("filename"))
        device_id = self._safe_component(payload.get("device_id"), "device_id")
        size_bytes = payload.get("size_bytes")
        if (
            not isinstance(size_bytes, int)
            or isinstance(size_bytes, bool)
            or not 0 < size_bytes <= MAX_CAPTURE_ARCHIVE_BYTES
        ):
            raise CaptureUploadError("size_bytes is outside the allowed range.")
        sha256 = payload.get("sha256")
        if not isinstance(sha256, str) or re.fullmatch(r"[0-9a-f]{64}", sha256) is None:
            raise CaptureUploadError("sha256 must be 64 lowercase hexadecimal characters.")

        # Protocol-v1 iOS sends no upload_id. The Receiver owns a stable,
        # content-bound identifier so an equivalent initialization can resume.
        upload_id = hashlib.sha256(
            f"{device_id}\0{size_bytes}\0{sha256}".encode("utf-8")
        ).hexdigest()[:32]

        expected = {
            "schema_version": 1,
            "upload_id": upload_id,
            "filename": filename,
            "device_id": device_id,
            "platform": str(payload.get("platform", "iOS"))[:80],
            "size_bytes": size_bytes,
            "sha256": sha256,
        }
        grant = payload.get("authorization_grant")
        if grant is not None:
            if not isinstance(grant, dict) or grant.get("device_id") != device_id:
                raise CaptureUploadError("Upload authorization grant is invalid.", "403 Forbidden")
            expected["authorization_grant"] = grant
        metadata_path = self._metadata_path(upload_id)
        partial_path = self._partial_path(upload_id)
        completed_path = self._completed_path(expected)
        if completed_path.is_file() and self._file_matches(completed_path, size_bytes, sha256):
            return self._result(expected, size_bytes, True, completed_path)

        if metadata_path.is_file():
            try:
                existing = json.loads(metadata_path.read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError) as error:
                raise CaptureUploadError("Stored upload metadata is unreadable.", "409 Conflict") from error
            for key in ("filename", "device_id", "size_bytes", "sha256"):
                if existing.get(key) != expected[key]:
                    raise CaptureUploadError("Upload identifier conflicts with stored metadata.", "409 Conflict")
            if "authorization_grant" in existing:
                expected["authorization_grant"] = existing["authorization_grant"]
            elif "authorization_grant" in expected:
                raise CaptureUploadError("Stored upload has no authorization grant.", "409 Conflict")
        else:
            expected["created_at_utc"] = self._utc_now()
            self._atomic_json_write(metadata_path, expected)

        if partial_path.exists():
            current_size = partial_path.stat().st_size
        else:
            partial_path.touch(exist_ok=False)
            current_size = 0
        if current_size > size_bytes:
            raise CaptureUploadError("Stored partial upload exceeds the declared size.", "409 Conflict")
        return self._result(expected, current_size, False, None)

    def resume_authorized(self, payload: dict) -> Optional[dict]:
        """Resume only a previously persisted server-authorized identity."""

        expected = self.normalized_identity(payload)
        metadata_path = self._metadata_path(expected["upload_id"])
        if metadata_path.is_file():
            existing = self._load_metadata(expected["upload_id"])
            for key in ("filename", "device_id", "platform", "size_bytes", "sha256"):
                if existing.get(key) != expected[key]:
                    raise CaptureUploadError("Upload identifier conflicts with stored metadata.", "409 Conflict")
            if not isinstance(existing.get("authorization_grant"), dict):
                raise CaptureUploadError("Stored upload has no authorization grant.", "403 Forbidden")
            return self.initialize({**payload, "authorization_grant": existing["authorization_grant"]})

        completed_path = self._completed_path(expected)
        completed_metadata_path = self._completed_metadata_path(completed_path)
        if not completed_path.is_file() or not completed_metadata_path.is_file():
            return None
        try:
            existing = json.loads(completed_metadata_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as error:
            raise CaptureUploadError("Stored completed upload metadata is unreadable.", "409 Conflict") from error
        for key in ("upload_id", "filename", "device_id", "platform", "size_bytes", "sha256"):
            if existing.get(key) != expected[key]:
                raise CaptureUploadError("Upload identifier conflicts with stored metadata.", "409 Conflict")
        self._require_authorization_grant(existing)
        if not self._file_matches(completed_path, expected["size_bytes"], expected["sha256"]):
            raise CaptureUploadError("Stored completed upload does not match its identity.", "409 Conflict")
        return self._result(existing, expected["size_bytes"], True, completed_path)

    def append(
        self,
        upload_id: str,
        offset: int,
        content_length: int,
        input_stream: BinaryIO,
    ) -> dict:
        metadata = self._load_metadata(upload_id)
        self._require_authorization_grant(metadata)
        if content_length <= 0 or content_length > MAX_CAPTURE_CHUNK_BYTES:
            raise CaptureUploadError("Chunk size is outside the allowed range.", "413 Payload Too Large")
        expected_size = metadata["size_bytes"]
        if offset < 0 or offset + content_length > expected_size:
            raise CaptureUploadError("Chunk exceeds the declared archive size.")
        partial_path = self._partial_path(upload_id)
        try:
            actual_offset = partial_path.stat().st_size
        except FileNotFoundError as error:
            raise CaptureUploadError("Upload session is missing.", "404 Not Found") from error
        if offset != actual_offset:
            raise CaptureUploadError(
                f"Upload offset mismatch; receiver expects {actual_offset}.",
                "409 Conflict",
            )

        remaining = content_length
        try:
            with partial_path.open("ab", buffering=0) as output:
                while remaining:
                    chunk = input_stream.read(min(CAPTURE_STREAM_CHUNK_BYTES, remaining))
                    if not chunk:
                        raise CaptureUploadError("Chunk ended before Content-Length bytes were received.")
                    if len(chunk) > remaining:
                        raise CaptureUploadError("Chunk exceeded Content-Length.")
                    output.write(chunk)
                    remaining -= len(chunk)
                output.flush()
                os.fsync(output.fileno())
        except CaptureUploadError:
            self._truncate(partial_path, actual_offset)
            raise
        except OSError as error:
            self._truncate(partial_path, actual_offset)
            raise CaptureUploadError("Receiver could not persist the upload chunk.", "500 Internal Server Error") from error
        return self._result(metadata, actual_offset + content_length, False, None)

    def finish(self, upload_id: str) -> dict:
        metadata = self._load_metadata(upload_id)
        self._require_authorization_grant(metadata)
        partial_path = self._partial_path(upload_id)
        try:
            actual_size = partial_path.stat().st_size
        except FileNotFoundError as error:
            raise CaptureUploadError("Upload session is missing.", "404 Not Found") from error
        if actual_size != metadata["size_bytes"]:
            raise CaptureUploadError(
                f"Upload is incomplete; receiver has {actual_size} of {metadata['size_bytes']} bytes.",
                "409 Conflict",
            )
        actual_sha256 = self._sha256(partial_path)
        if not secrets.compare_digest(actual_sha256, metadata["sha256"]):
            self._truncate(partial_path, 0)
            raise CaptureUploadError("Capture archive checksum does not match.", "422 Unprocessable Entity")

        completed_path = self._completed_path(metadata)
        completed_path.parent.mkdir(parents=True, exist_ok=True)
        if completed_path.exists():
            if self._file_matches(completed_path, metadata["size_bytes"], metadata["sha256"]):
                partial_path.unlink(missing_ok=True)
            else:
                completed_path = completed_path.with_name(
                    f"{completed_path.stem}-{metadata['sha256'][:8]}.zip"
                )
                os.replace(partial_path, completed_path)
        else:
            os.replace(partial_path, completed_path)

        completed_metadata = dict(metadata)
        completed_metadata["completed_at_utc"] = self._utc_now()
        completed_metadata["stored_path"] = str(completed_path)
        self._atomic_json_write(self._completed_metadata_path(completed_path), completed_metadata)
        self._metadata_path(upload_id).unlink(missing_ok=True)
        return self._result(metadata, actual_size, True, completed_path)

    def snapshot(self) -> dict:
        completed = sorted(
            (path for path in self.root.glob("*/*.zip") if path.is_file()),
            key=lambda path: path.stat().st_mtime,
            reverse=True,
        )
        partial_count = sum(1 for path in self.partial_root.glob("*.part") if path.is_file())
        return {
            "enabled": True,
            "inbox": str(self.root),
            "completed_count": len(completed),
            "partial_count": partial_count,
            "latest_file": str(completed[0]) if completed else None,
        }

    def _load_metadata(self, upload_id: str) -> dict:
        if not isinstance(upload_id, str) or re.fullmatch(r"[0-9a-f]{32}", upload_id) is None:
            raise CaptureUploadError("Invalid upload identifier.")
        try:
            return json.loads(self._metadata_path(upload_id).read_text(encoding="utf-8"))
        except FileNotFoundError as error:
            raise CaptureUploadError("Upload session is missing.", "404 Not Found") from error
        except (OSError, json.JSONDecodeError) as error:
            raise CaptureUploadError("Stored upload metadata is unreadable.", "409 Conflict") from error

    def _completed_path(self, metadata: dict) -> Path:
        return self.root / metadata["device_id"] / metadata["filename"]

    @staticmethod
    def _completed_metadata_path(completed_path: Path) -> Path:
        return completed_path.with_name(completed_path.name + ".upload.json")

    def normalized_identity(self, payload: dict) -> dict:
        filename = self._safe_zip_filename(payload.get("filename"))
        device_id = self._safe_component(payload.get("device_id"), "device_id")
        size_bytes = payload.get("size_bytes")
        sha256 = payload.get("sha256")
        if not isinstance(size_bytes, int) or isinstance(size_bytes, bool) or not 0 < size_bytes <= MAX_CAPTURE_ARCHIVE_BYTES:
            raise CaptureUploadError("size_bytes is outside the allowed range.")
        if not isinstance(sha256, str) or re.fullmatch(r"[0-9a-f]{64}", sha256) is None:
            raise CaptureUploadError("sha256 must be 64 lowercase hexadecimal characters.")
        upload_id = hashlib.sha256(f"{device_id}\0{size_bytes}\0{sha256}".encode("utf-8")).hexdigest()[:32]
        return {
            "upload_id": upload_id,
            "filename": filename,
            "device_id": device_id,
            "size_bytes": size_bytes,
            "sha256": sha256,
            "platform": str(payload.get("platform", "iOS"))[:80],
        }

    @staticmethod
    def _require_authorization_grant(metadata: dict) -> None:
        grant = metadata.get("authorization_grant")
        if not isinstance(grant, dict) or grant.get("device_id") != metadata.get("device_id"):
            raise CaptureUploadError("Upload has no valid authorization grant.", "403 Forbidden")
        expected_identity = {
            key: metadata.get(key)
            for key in ("filename", "device_id", "platform", "size_bytes", "sha256")
        }
        if grant.get("file_identity") != expected_identity:
            raise CaptureUploadError("Upload authorization does not match the file identity.", "403 Forbidden")

    def _metadata_path(self, upload_id: str) -> Path:
        return self.partial_root / f"{upload_id}.json"

    def _partial_path(self, upload_id: str) -> Path:
        return self.partial_root / f"{upload_id}.part"

    @staticmethod
    def _safe_zip_filename(value: object) -> str:
        if not isinstance(value, str) or Path(value).name != value:
            raise CaptureUploadError("filename must be a plain file name.")
        safe = _SAFE_COMPONENT.sub("_", value).strip("._")
        if not safe or not safe.lower().endswith(".zip") or len(safe) > 180:
            raise CaptureUploadError("filename must identify a bounded ZIP archive.")
        return safe

    @staticmethod
    def _safe_component(value: object, label: str) -> str:
        if not isinstance(value, str):
            raise CaptureUploadError(f"{label} must be a string.")
        safe = _SAFE_COMPONENT.sub("_", value).strip("._")
        if not safe or len(safe) > 80:
            raise CaptureUploadError(f"{label} is invalid.")
        return safe

    @staticmethod
    def _result(metadata: dict, offset: int, complete: bool, path: Optional[Path]) -> dict:
        return {
            "ok": True,
            "upload_id": metadata["upload_id"],
            "next_offset": offset,
            "size_bytes": metadata["size_bytes"],
            "complete": complete,
            "stored_path": str(path) if path is not None else None,
        }

    @staticmethod
    def _sha256(path: Path) -> str:
        digest = hashlib.sha256()
        with path.open("rb") as stream:
            for chunk in iter(lambda: stream.read(CAPTURE_STREAM_CHUNK_BYTES), b""):
                digest.update(chunk)
        return digest.hexdigest()

    @classmethod
    def _file_matches(cls, path: Path, size_bytes: int, sha256: str) -> bool:
        try:
            return path.stat().st_size == size_bytes and secrets.compare_digest(
                cls._sha256(path), sha256
            )
        except OSError:
            return False

    @staticmethod
    def _atomic_json_write(path: Path, payload: dict) -> None:
        temporary = path.with_suffix(path.suffix + ".tmp")
        temporary.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        os.replace(temporary, path)

    @staticmethod
    def _truncate(path: Path, size: int) -> None:
        try:
            with path.open("r+b") as output:
                output.truncate(size)
        except OSError:
            pass

    @staticmethod
    def _utc_now() -> str:
        return datetime.now(timezone.utc).isoformat()
