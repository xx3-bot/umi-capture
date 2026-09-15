from __future__ import annotations

import json
import base64
import tempfile
import unittest
import uuid
from pathlib import Path

from dual_capture import (
    CoordinationError,
    DualCaptureCoordinator,
    EVENT_EGO_PREVIEW_FRAME,
)


class FakeClock:
    def __init__(self, value: int = 10_000_000_000):
        self.value = value

    def __call__(self) -> int:
        return self.value


class DualCaptureCoordinatorTests(unittest.TestCase):
    HAND_ID = "11111111-1111-4111-8111-111111111111"
    EGO_ID = "22222222-2222-4222-8222-222222222222"

    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.clock = FakeClock()
        self.coordinator = DualCaptureCoordinator(
            Path(self.temporary.name),
            monotonic_ns=self.clock,
            unix_time_ns=lambda: 1_800_000_000_000_000_000,
        )
        self._register("sid-hand", self.HAND_ID, "wrist_umi", "UMI Capture 1.0")
        self._register("sid-ego", self.EGO_ID, "ego", "iPhoneVIO")

    def _register(self, sid: str, device_id: str, role: str, identity: str) -> dict:
        return self.coordinator.register(
            sid,
            {
                "protocol_version": 1,
                "device_id": device_id,
                "display_name": f"Test {role}",
                "capture_role": role,
                "profile_id": "handheld_umi" if role == "wrist_umi" else "chest_ego",
                "controller_capable": True,
                "gripper_id": "fastumi" if role == "wrist_umi" else None,
                "client_identity": identity,
                "calibration": {},
            },
        )

    def _record_fresh_clocks(self) -> None:
        for sid, device_id in (("sid-hand", self.HAND_ID), ("sid-ego", self.EGO_ID)):
            self.coordinator.record_clock_sample(
                sid,
                {
                    "protocol_version": 1,
                    "probe_id": "probe-1",
                    "device_id": device_id,
                    "local_midpoint_monotonic_ns": str(self.clock.value),
                    "coordinator_midpoint_monotonic_ns": str(self.clock.value),
                    "offset_ns": "0",
                    "rtt_ns": "1000",
                    "uncertainty_ns": "1000",
                    "sampled_at_local_monotonic_ns": str(self.clock.value),
                },
            )

    def test_ego_preview_routes_only_from_ego_to_hand_and_is_ephemeral(self) -> None:
        self.assertEqual(EVENT_EGO_PREVIEW_FRAME, "umi_capture_ego_preview_frame_v1")
        session = self.coordinator.begin_session()
        payload = {
            "protocol_version": 1,
            "session_id": session.session_id,
            "generation": session.generation,
            "device_id": self.EGO_ID,
            "capture_role": "ego",
            "sequence": "1",
            "arkit_timestamp_s": 10.5,
            "sender_monotonic_ns": "100000",
            "orientation": "portrait",
            "jpeg_base64": base64.b64encode(b"\xff\xd8preview\xff\xd9").decode(),
        }
        target_sid, relayed = self.coordinator.route_ego_preview_frame(
            "sid-ego", payload
        )
        self.assertEqual(target_sid, "sid-hand")
        self.assertEqual(relayed, payload)
        self.assertNotIn("ego_preview", json.dumps(self.coordinator.snapshot()["session"]))
        with self.assertRaisesRegex(CoordinationError, "sender or role mismatch"):
            self.coordinator.route_ego_preview_frame("sid-hand", payload)
        with self.assertRaisesRegex(CoordinationError, "sequence"):
            self.coordinator.route_ego_preview_frame("sid-ego", payload)
        with self.assertRaisesRegex(CoordinationError, "session"):
            self.coordinator.route_ego_preview_frame(
                "sid-ego", dict(payload, generation=999, sequence="2")
            )

    @staticmethod
    def _transmission_by_sid(transmissions: list[tuple[str, dict]]) -> dict[str, dict]:
        return {sid: payload for sid, payload in transmissions}

    def _ack(
        self,
        sid: str,
        device_id: str,
        command: dict,
        state: str,
        *,
        actual_ns: int | None = None,
        artifacts: list[dict] | None = None,
    ) -> list[tuple[str, dict]]:
        payload = {
            "protocol_version": 1,
            "command": command["command"],
            "command_id": command["command_id"],
            "session_id": command["session_id"],
            "generation": command["generation"],
            "device_id": device_id,
            "state": state,
        }
        if actual_ns is not None:
            payload["planned_coordinator_monotonic_ns"] = command.get(
                "coordinator_deadline_ns"
            )
            payload["actual_coordinator_monotonic_ns"] = str(actual_ns)
        if artifacts is not None:
            payload["artifacts"] = artifacts
        if state == "armed":
            payload["preparation"] = {"phase": "ready"}
        return self.coordinator.record_ack(sid, payload)

    def test_optional_auto_rearm_starts_fresh_prepare_and_retries_five_times(self) -> None:
        session = self.coordinator.begin_session(auto_rearm_after_capture=True)
        self._record_fresh_clocks()
        prepare = self._transmission_by_sid(self.coordinator.issue_mac_request("prepare"))
        self._ack("sid-hand", self.HAND_ID, prepare["sid-hand"], "armed")
        self._ack("sid-ego", self.EGO_ID, prepare["sid-ego"], "armed")
        start = self._transmission_by_sid(self.coordinator.issue_mac_request("start"))
        deadline = int(start["sid-hand"]["coordinator_deadline_ns"])
        self._ack("sid-hand", self.HAND_ID, start["sid-hand"], "started", actual_ns=deadline)
        self._ack("sid-ego", self.EGO_ID, start["sid-ego"], "started", actual_ns=deadline)
        stop = self._transmission_by_sid(self.coordinator.issue_mac_request("stop"))
        deadline = int(stop["sid-hand"]["coordinator_deadline_ns"])
        self._ack(
            "sid-hand", self.HAND_ID, stop["sid-hand"], "finalized",
            actual_ns=deadline, artifacts=self._local_artifact(self.HAND_ID),
        )
        transmissions = self._ack(
            "sid-ego", self.EGO_ID, stop["sid-ego"], "finalized",
            actual_ns=deadline, artifacts=self._local_artifact(self.EGO_ID),
        )
        self.assertEqual(transmissions, [])
        self.assertEqual(self.coordinator.active_session.session_id, session.session_id)
        self.assertEqual(
            self.coordinator.authorize_upload_initialize(
                self._file_identity(self.HAND_ID)
            )["session_id"],
            session.session_id,
        )
        self._ack(
            "sid-hand", self.HAND_ID, stop["sid-hand"], "finalized",
            actual_ns=deadline, artifacts=self._completed_artifact(self.HAND_ID),
        )
        wrong_ego_upload = self._completed_artifact(self.EGO_ID)
        wrong_ego_upload[0]["name"] = "different.zip"
        wrong_ego_upload[0]["sha256"] = "b" * 64
        transmissions = self._ack(
            "sid-ego", self.EGO_ID, stop["sid-ego"], "finalized",
            actual_ns=deadline, artifacts=wrong_ego_upload,
        )
        self.assertEqual(transmissions, [])
        self.assertEqual(self.coordinator.active_session.session_id, session.session_id)
        transmissions = self._ack(
            "sid-ego", self.EGO_ID, stop["sid-ego"], "finalized",
            actual_ns=deadline, artifacts=self._completed_artifact(self.EGO_ID),
        )
        self.assertEqual(len(transmissions), 2)
        successor = self.coordinator.active_session
        self.assertNotEqual(successor.session_id, session.session_id)
        self.assertEqual(successor.generation, session.generation + 1)
        self.assertTrue(all(payload["automatic_rearm"] for _, payload in transmissions))
        manifest = json.loads(
            (
                Path(self.temporary.name)
                / "group_sessions"
                / session.session_id
                / "session_manifest.json"
            )
            .read_text(encoding="utf-8")
        )
        self.assertEqual(manifest["session"]["completion_state"], "completed")
        for expected_attempt in range(2, 6):
            self.clock.value += 500_000_000
            retried = self.coordinator.due_retries()
            self.assertEqual(len(retried), 2, expected_attempt)
        self.clock.value += 500_000_000
        self.assertEqual(self.coordinator.due_retries(), [])
        self.assertIn("ack_timeout", " ".join(successor.partial_reasons))

    @staticmethod
    def _completed_artifact(device_id: str) -> list[dict]:
        return [
            {
                "name": "capture.zip",
                "sha256": "a" * 64,
                "size_bytes": 100,
                "platform": "iOS",
                "receiver_upload_complete": True,
                "upload_id": uuid.uuid4().hex,
            }
        ]

    @staticmethod
    def _local_artifact(device_id: str) -> list[dict]:
        return [
            {
                "name": "capture.zip",
                "sha256": "a" * 64,
                "size_bytes": 100,
                "platform": "iOS",
                "receiver_upload_complete": False,
            }
        ]

    @staticmethod
    def _file_identity(device_id: str, *, suffix: str = "") -> dict:
        return {
            "filename": f"capture{suffix}.zip",
            "device_id": device_id,
            "platform": "iOS",
            "size_bytes": 100,
            "sha256": ("a" if not suffix else "b") * 64,
        }

    def _advance_to_running(self) -> None:
        self.coordinator.begin_session()
        self._record_fresh_clocks()
        prepare = self._transmission_by_sid(self.coordinator.issue_mac_request("prepare"))
        self._ack("sid-hand", self.HAND_ID, prepare["sid-hand"], "armed")
        self._ack("sid-ego", self.EGO_ID, prepare["sid-ego"], "armed")
        start = self._transmission_by_sid(self.coordinator.issue_mac_request("start"))
        deadline = int(start["sid-hand"]["coordinator_deadline_ns"])
        self.assertEqual(start["sid-ego"]["coordinator_deadline_ns"], str(deadline))
        self._ack("sid-hand", self.HAND_ID, start["sid-hand"], "started", actual_ns=deadline)
        self._ack("sid-ego", self.EGO_ID, start["sid-ego"], "started", actual_ns=deadline + 1_000_000)

    def _advance_to_running_from_device(self, controller_sid: str) -> None:
        self._record_fresh_clocks()
        prepare = self._transmission_by_sid(
            self.coordinator.issue_device_request(controller_sid, "prepare")
        )
        self._ack("sid-hand", self.HAND_ID, prepare["sid-hand"], "armed")
        self._ack("sid-ego", self.EGO_ID, prepare["sid-ego"], "armed")
        start = self._transmission_by_sid(
            self.coordinator.issue_device_request(controller_sid, "start")
        )
        deadline = int(start["sid-hand"]["coordinator_deadline_ns"])
        self._ack("sid-hand", self.HAND_ID, start["sid-hand"], "started", actual_ns=deadline)
        self._ack(
            "sid-ego",
            self.EGO_ID,
            start["sid-ego"],
            "started",
            actual_ns=deadline + 1_000_000,
        )

    def test_registration_clock_mapping_and_protocol_surface(self) -> None:
        snapshot = self.coordinator.snapshot()
        identities = {item["capture_role"]: item["client_identity"] for item in snapshot["devices"]}
        self.assertEqual(identities, {"ego": "iPhoneVIO", "wrist_umi": "UMI Capture"})
        reply = self.coordinator.make_time_reply(
            "sid-hand",
            {
                "protocol_version": 1,
                "probe_id": "probe-1",
                "local_send_monotonic_ns": str(self.clock.value - 1000),
            },
        )
        self.assertEqual(reply["device_id"], self.HAND_ID)
        self._record_fresh_clocks()
        self.assertEqual(
            self.coordinator.snapshot()["devices"][1]["clock"]["uncertainty_ns"],
            "1000",
        )
        with self.assertRaises(CoordinationError):
            self.coordinator.issue_command("pause")

    def test_exact_umi_capture_ios_registration_uses_client_metadata_identity(self) -> None:
        coordinator = DualCaptureCoordinator(
            Path(self.temporary.name) / "exact-registration",
            monotonic_ns=self.clock,
            unix_time_ns=lambda: 1_800_000_000_000_000_000,
        )
        result = coordinator.register(
            "sid-exact-ios",
            {
                "protocol_version": 1,
                "device_id": self.HAND_ID,
                "display_name": "UMI Capture Hand",
                "capture_role": "wrist_umi",
                "profile_id": "handheld_umi",
                "controller_capable": True,
                "gripper_id": "fastumi-iphone15pro-v1",
                "calibration": {},
                "client_metadata": {
                    "app_name": "UMI Capture",
                    "platform": "iOS",
                    "app_version": "1.0",
                },
            },
        )
        self.assertTrue(result["accepted"])
        self.assertEqual(coordinator.snapshot()["devices"][0]["client_identity"], "UMI Capture")

    def test_prepare_start_stop_authorizes_upload_after_valid_finalization(self) -> None:
        self._advance_to_running()
        stop = self._transmission_by_sid(self.coordinator.issue_mac_request("stop"))
        deadline = int(stop["sid-hand"]["coordinator_deadline_ns"])
        self.assertEqual(stop["sid-ego"]["coordinator_deadline_ns"], str(deadline))
        self._ack(
            "sid-hand",
            self.HAND_ID,
            stop["sid-hand"],
            "finalized",
            actual_ns=deadline,
            artifacts=self._completed_artifact(self.HAND_ID),
        )
        self._ack(
            "sid-ego",
            self.EGO_ID,
            stop["sid-ego"],
            "finalized",
            actual_ns=deadline + 1_000_000,
            artifacts=self._completed_artifact(self.EGO_ID),
        )
        session = self.coordinator.snapshot()["session"]
        self.assertTrue(session["membership_valid"])
        self.assertTrue(session["stop_commit_authorized"])
        self.assertTrue(session["upload_commit_authorized"])
        self.assertEqual(session["completion_state"], "completed")

    def test_disconnect_at_stop_boundary_is_fail_closed_after_reconnection(self) -> None:
        self._advance_to_running()
        stop = self._transmission_by_sid(self.coordinator.issue_mac_request("stop"))
        deadline = int(stop["sid-hand"]["coordinator_deadline_ns"])
        self.coordinator.disconnect("sid-ego")
        self._register("sid-ego-new", self.EGO_ID, "ego", "UMI Capture")
        self._ack(
            "sid-hand",
            self.HAND_ID,
            stop["sid-hand"],
            "finalized",
            actual_ns=deadline,
            artifacts=self._completed_artifact(self.HAND_ID),
        )
        self._ack(
            "sid-ego-new",
            self.EGO_ID,
            stop["sid-ego"],
            "finalized",
            actual_ns=deadline + 500_000,
            artifacts=self._completed_artifact(self.EGO_ID),
        )
        session = self.coordinator.snapshot()["session"]
        self.assertFalse(session["membership_valid"])
        self.assertFalse(session["stop_commit_authorized"])
        self.assertFalse(session["upload_commit_authorized"])
        self.assertEqual(session["completion_state"], "partial")
        self.assertTrue(any(reason.startswith("device_disconnected:") for reason in session["partial_reasons"]))
        with self.assertRaisesRegex(CoordinationError, "not authorized"):
            self.coordinator.authorize_upload_initialize(self._file_identity(self.HAND_ID))

    def test_stale_clock_emergency_stop_stops_both_but_never_authorizes_upload(self) -> None:
        self._advance_to_running()
        self.clock.value += 6_000_000_000
        stop = self._transmission_by_sid(self.coordinator.issue_emergency_stop())
        self.assertEqual(set(stop), {"sid-hand", "sid-ego"})
        deadline = int(stop["sid-hand"]["coordinator_deadline_ns"])
        for sid, device_id in (("sid-hand", self.HAND_ID), ("sid-ego", self.EGO_ID)):
            self._ack(
                sid,
                device_id,
                stop[sid],
                "finalized",
                actual_ns=deadline,
                artifacts=self._completed_artifact(device_id),
            )
        session = self.coordinator.snapshot()["session"]
        self.assertEqual(session["completion_state"], "partial")
        self.assertIn("stop_clock_synchronization_timeout", session["partial_reasons"])
        self.assertFalse(session["upload_commit_authorized"])
        self.assertEqual(session["upload_grants_by_device"], {})
        with self.assertRaisesRegex(CoordinationError, "not authorized"):
            self.coordinator.authorize_upload_initialize(self._file_identity(self.HAND_ID))

    def test_device_controller_emergency_stop_is_permanently_fail_closed(self) -> None:
        self._advance_to_running_from_device("sid-hand")
        self.clock.value += 6_000_000_000
        with self.assertRaisesRegex(CoordinationError, "clock mapping stale"):
            self.coordinator.issue_device_request("sid-hand", "stop")
        stop = self._transmission_by_sid(
            self.coordinator.issue_device_emergency_stop("sid-hand")
        )
        self.assertEqual(set(stop), {"sid-hand", "sid-ego"})
        deadline = int(stop["sid-hand"]["coordinator_deadline_ns"])
        for sid, device_id in (("sid-hand", self.HAND_ID), ("sid-ego", self.EGO_ID)):
            self._ack(
                sid,
                device_id,
                stop[sid],
                "finalized",
                actual_ns=deadline,
                artifacts=self._completed_artifact(device_id),
            )
        session = self.coordinator.snapshot()["session"]
        self.assertEqual(session["controller_kind"], "device")
        self.assertEqual(session["completion_state"], "partial")
        self.assertFalse(session["membership_valid"])
        self.assertIn("stop_clock_synchronization_timeout", session["partial_reasons"])
        self.assertFalse(session["upload_commit_authorized"])
        self.assertEqual(session["upload_grants_by_device"], {})
        with self.assertRaisesRegex(CoordinationError, "not authorized"):
            self.coordinator.authorize_upload_initialize(self._file_identity(self.HAND_ID))

    def test_upload_grant_is_bound_to_authorized_session_generation_and_device(self) -> None:
        self._advance_to_running()
        stop = self._transmission_by_sid(self.coordinator.issue_mac_request("stop"))
        deadline = int(stop["sid-hand"]["coordinator_deadline_ns"])
        for sid, device_id in (("sid-hand", self.HAND_ID), ("sid-ego", self.EGO_ID)):
            self._ack(
                sid,
                device_id,
                stop[sid],
                "finalized",
                actual_ns=deadline,
                artifacts=self._completed_artifact(device_id),
            )
        session = self.coordinator.snapshot()["session"]
        identity = self._file_identity(self.HAND_ID)
        grant = self.coordinator.authorize_upload_initialize(identity)
        self.assertEqual(grant["session_id"], session["session_id"])
        self.assertEqual(grant["generation"], session["generation"])
        self.assertEqual(grant["capture_role"], "wrist_umi")
        self.assertEqual(grant["file_identity"], identity)
        self.assertEqual(self.coordinator.authorize_upload_initialize(identity), grant)
        with self.assertRaisesRegex(CoordinationError, "different file identity"):
            self.coordinator.authorize_upload_initialize(
                self._file_identity(self.HAND_ID, suffix="-different")
            )
        with self.assertRaisesRegex(CoordinationError, "not a member"):
            self.coordinator.authorize_upload_initialize(
                self._file_identity("33333333-3333-4333-8333-333333333333")
            )

    def test_frozen_grant_survives_disconnect_during_authorized_transfer_boundary(self) -> None:
        self._advance_to_running()
        stop = self._transmission_by_sid(self.coordinator.issue_mac_request("stop"))
        deadline = int(stop["sid-hand"]["coordinator_deadline_ns"])
        for sid, device_id in (("sid-hand", self.HAND_ID), ("sid-ego", self.EGO_ID)):
            artifacts = self._completed_artifact(device_id)
            artifacts[0]["receiver_upload_complete"] = False
            artifacts[0].pop("upload_id")
            self._ack(
                sid, device_id, stop[sid], "finalized", actual_ns=deadline, artifacts=artifacts
            )
        session = self.coordinator.snapshot()["session"]
        self.assertEqual(session["completion_state"], "finalizing")
        self.assertEqual(set(session["upload_grants_by_device"]), {self.HAND_ID, self.EGO_ID})
        identity = self._file_identity(self.HAND_ID)
        grant = self.coordinator.authorize_upload_initialize(identity)
        self.coordinator.disconnect("sid-hand")
        after_disconnect = self.coordinator.snapshot()["session"]
        self.assertTrue(after_disconnect["upload_commit_authorized"])
        self.assertEqual(after_disconnect["upload_grants_by_device"][self.HAND_ID], grant)
        self.assertEqual(self.coordinator.authorize_upload_initialize(identity), grant)
        with self.assertRaisesRegex(CoordinationError, "different file identity"):
            self.coordinator.authorize_upload_initialize(
                self._file_identity(self.HAND_ID, suffix="-different")
            )

    def test_frozen_grant_survives_receiver_restart_before_first_upload_init(self) -> None:
        self._advance_to_running()
        stop = self._transmission_by_sid(self.coordinator.issue_mac_request("stop"))
        deadline = int(stop["sid-hand"]["coordinator_deadline_ns"])
        for sid, device_id in (("sid-hand", self.HAND_ID), ("sid-ego", self.EGO_ID)):
            artifacts = self._completed_artifact(device_id)
            artifacts[0]["receiver_upload_complete"] = False
            artifacts[0].pop("upload_id")
            self._ack(
                sid,
                device_id,
                stop[sid],
                "finalized",
                actual_ns=deadline,
                artifacts=artifacts,
            )
        self.assertEqual(
            set(self.coordinator.snapshot()["session"]["upload_grants_by_device"]),
            {self.HAND_ID, self.EGO_ID},
        )

        restarted = DualCaptureCoordinator(
            Path(self.temporary.name),
            monotonic_ns=self.clock,
            unix_time_ns=lambda: 1_800_000_000_000_000_000,
        )
        identity = self._file_identity(self.HAND_ID)
        grant = restarted.authorize_upload_initialize(identity)
        self.assertEqual(grant["device_id"], self.HAND_ID)
        self.assertEqual(grant["file_identity"], identity)
        with self.assertRaisesRegex(CoordinationError, "different file identity"):
            restarted.authorize_upload_initialize(
                self._file_identity(self.HAND_ID, suffix="-different")
            )

        restarted_again = DualCaptureCoordinator(
            Path(self.temporary.name),
            monotonic_ns=self.clock,
            unix_time_ns=lambda: 1_800_000_000_000_000_000,
        )
        self.assertEqual(restarted_again.authorize_upload_initialize(identity), grant)
        frozen = restarted_again.snapshot()["frozen_upload_grants_by_device"]
        self.assertEqual(frozen[self.HAND_ID], grant)

    def test_failed_later_session_cannot_consume_an_older_frozen_grant(self) -> None:
        self._advance_to_running()
        stop = self._transmission_by_sid(self.coordinator.issue_mac_request("stop"))
        deadline = int(stop["sid-hand"]["coordinator_deadline_ns"])
        for sid, device_id in (("sid-hand", self.HAND_ID), ("sid-ego", self.EGO_ID)):
            artifacts = self._completed_artifact(device_id)
            artifacts[0]["receiver_upload_complete"] = False
            artifacts[0].pop("upload_id")
            self._ack(
                sid, device_id, stop[sid], "finalized", actual_ns=deadline, artifacts=artifacts
            )

        restarted = DualCaptureCoordinator(
            Path(self.temporary.name),
            monotonic_ns=self.clock,
            unix_time_ns=lambda: 1_800_000_000_000_000_000,
        )
        with self.assertRaisesRegex(CoordinationError, "different file identity"):
            restarted.authorize_upload_initialize(
                self._file_identity(self.HAND_ID, suffix="-later-session")
            )
        original = self._file_identity(self.HAND_ID)
        self.assertEqual(
            restarted.authorize_upload_initialize(original)["file_identity"], original
        )

    def test_unbound_legacy_grant_ledger_is_rejected_fail_closed(self) -> None:
        recordings = Path(self.temporary.name)
        ledger = {
            "schema_version": 1,
            "kind": "umi_capture_frozen_upload_grants",
            "receiver_id": self.coordinator.receiver_id,
            "updated_unix_ns": "1800000000000000000",
            "grants_by_device": {
                self.HAND_ID: {
                    "schema_version": 1,
                    "session_id": str(uuid.uuid4()),
                    "generation": 1,
                    "device_id": self.HAND_ID,
                    "capture_role": "wrist_umi",
                    "authorized_coordinator_monotonic_ns": str(self.clock.value),
                    "file_identity": None,
                }
            },
        }
        (recordings / "frozen_upload_grants.json").write_text(
            json.dumps(ledger), encoding="utf-8"
        )
        restarted = DualCaptureCoordinator(
            recordings,
            monotonic_ns=self.clock,
            unix_time_ns=lambda: 1_800_000_000_000_000_000,
        )
        self.assertEqual(restarted.snapshot()["frozen_upload_grants_by_device"], {})
        with self.assertRaisesRegex(CoordinationError, "no active group session"):
            restarted.authorize_upload_initialize(self._file_identity(self.HAND_ID))

    def test_wrong_generation_ack_is_rejected(self) -> None:
        session = self.coordinator.begin_session()
        prepare = self._transmission_by_sid(self.coordinator.issue_mac_request("prepare"))
        payload = {
            "protocol_version": 1,
            "command": "prepare",
            "command_id": prepare["sid-hand"]["command_id"],
            "session_id": session.session_id,
            "generation": session.generation + 1,
            "device_id": self.HAND_ID,
            "state": "armed",
        }
        with self.assertRaises(CoordinationError):
            self.coordinator.record_ack("sid-hand", payload)


if __name__ == "__main__":
    unittest.main()
