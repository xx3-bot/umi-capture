from __future__ import annotations

import hashlib
import io
import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from receiver import exclusive_receiver_port
from receiver_web import DashboardApplication


class ReceiverUploadAuthorizationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.dashboard = self.root / "dashboard.html"
        self.dashboard.write_text("ok", encoding="utf-8")
        self.authorized = True
        self.authorizer_calls = 0

        def authorizer(payload: dict) -> dict:
            self.authorizer_calls += 1
            if not self.authorized:
                raise PermissionError("capture upload is not authorized for this session")
            return {
                "schema_version": 1,
                "session_id": "session-1",
                "generation": 1,
                "device_id": payload["device_id"],
                "capture_role": "wrist_umi",
                "authorized_coordinator_monotonic_ns": "1",
                "file_identity": dict(payload),
            }

        self.application = DashboardApplication(
            self.dashboard,
            lambda: {},
            lambda command, payload: (202, {"ok": True}),
            self.root / "Inbox",
            authorizer,
        )

    def request(self, method: str, path: str, body: bytes = b"", headers: dict | None = None):
        environ = {
            "REQUEST_METHOD": method,
            "PATH_INFO": path,
            "CONTENT_LENGTH": str(len(body)),
            "wsgi.input": io.BytesIO(body),
        }
        environ.update(headers or {})
        captured = {}

        def start_response(status, response_headers):
            captured["status"] = status
            captured["headers"] = response_headers

        response = b"".join(self.application(environ, start_response))
        return captured["status"], json.loads(response)

    @staticmethod
    def metadata(payload: bytes) -> dict:
        return {
            "filename": "hand_20260813_120000.zip",
            "device_id": "11111111-1111-4111-8111-111111111111",
            "platform": "iOS",
            "size_bytes": len(payload),
            "sha256": hashlib.sha256(payload).hexdigest(),
        }

    def test_authorized_partial_resumes_after_live_session_becomes_invalid(self) -> None:
        payload = b"authorized-transfer"
        metadata = self.metadata(payload)
        status, initialized = self.request(
            "POST", "/api/captures/upload/init", json.dumps(metadata).encode()
        )
        self.assertEqual(status, "200 OK")
        upload_id = initialized["upload_id"]
        status, chunk = self.request(
            "PUT",
            f"/api/captures/upload/{upload_id}",
            payload[:5],
            {"HTTP_X_UPLOAD_OFFSET": "0"},
        )
        self.assertEqual(status, "200 OK")
        self.assertEqual(chunk["next_offset"], 5)
        self.authorized = False
        status, resumed = self.request(
            "POST", "/api/captures/upload/init", json.dumps(metadata).encode()
        )
        self.assertEqual(status, "200 OK")
        self.assertEqual(resumed["next_offset"], 5)
        self.assertEqual(self.authorizer_calls, 1)

    def test_session_invalid_before_first_init_is_permanently_rejected(self) -> None:
        self.authorized = False
        metadata = self.metadata(b"never-authorized")
        for _ in range(2):
            status, result = self.request(
                "POST", "/api/captures/upload/init", json.dumps(metadata).encode()
            )
            self.assertEqual(status, "403 Forbidden")
            self.assertFalse(result["ok"])

    def test_completed_upload_init_is_idempotent_after_response_loss_and_restart(self) -> None:
        payload = b"completed-before-response-loss"
        metadata = self.metadata(payload)
        status, initialized = self.request(
            "POST", "/api/captures/upload/init", json.dumps(metadata).encode()
        )
        self.assertEqual(status, "200 OK")
        upload_id = initialized["upload_id"]
        status, _ = self.request(
            "PUT", f"/api/captures/upload/{upload_id}", payload,
            {"HTTP_X_UPLOAD_OFFSET": "0"},
        )
        self.assertEqual(status, "200 OK")
        status, finished = self.request(
            "POST", f"/api/captures/upload/{upload_id}/finish"
        )
        self.assertEqual(status, "200 OK")
        self.assertTrue(finished["complete"])

        def deny_after_restart(_: dict) -> dict:
            raise PermissionError("live session is no longer available")

        self.application = DashboardApplication(
            self.dashboard, lambda: {},
            lambda command, request: (202, {"ok": True}),
            self.root / "Inbox", deny_after_restart,
        )
        status, resumed = self.request(
            "POST", "/api/captures/upload/init", json.dumps(metadata).encode()
        )
        self.assertEqual(status, "200 OK")
        self.assertEqual(resumed["upload_id"], upload_id)
        self.assertEqual(resumed["next_offset"], len(payload))
        self.assertTrue(resumed["complete"])

    def test_receiver_routes_ego_preview_to_hand(self) -> None:
        source = (
            Path(__file__).resolve().parents[1]
            / "Resources/Receiver/receiver.py"
        ).read_text(encoding="utf-8")
        self.assertIn("@server.on(EVENT_EGO_PREVIEW_FRAME)", source)
        self.assertIn("coordinator.route_ego_preview_frame(sid, data)", source)
        self.assertIn("server.emit(EVENT_EGO_PREVIEW_FRAME, payload, to=target_sid)", source)

    def test_receiver_port_lock_uses_platform_temporary_directory(self) -> None:
        lock_root = self.root / "platform-temp"
        lock_root.mkdir()
        port = 55_661

        with mock.patch("receiver.tempfile.gettempdir", return_value=str(lock_root)):
            with exclusive_receiver_port(port):
                self.assertTrue(
                    (lock_root / f"umi_capture-receiver-{port}.lock").is_file()
                )
                with self.assertRaisesRegex(
                    SystemExit,
                    f"already owns port {port}",
                ):
                    with exclusive_receiver_port(port):
                        self.fail("a second Receiver acquired the same port")


if __name__ == "__main__":
    unittest.main()
