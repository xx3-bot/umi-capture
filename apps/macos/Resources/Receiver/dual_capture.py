#!/usr/bin/env python3
"""Protocol-v1 role, clock, command and fail-closed upload coordination.

This extraction intentionally models two independent ARKit worlds. It contains
no cross-device spatial alignment, solver, lease, or joint-layout state. Its
only cross-role media relay is the bounded, ephemeral Ego preview. Event names
and timing/ACK contracts remain protocol-v1 compatible.
"""

from __future__ import annotations

import base64
import binascii
import json
import math
import os
import re
import threading
import time
import uuid
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable, Dict, List, Optional, Tuple


PROTOCOL_VERSION = 1
EVENT_REGISTER = "iphonevio_register_v1"
EVENT_REGISTER_ACK = "iphonevio_register_ack_v1"
EVENT_TIME_PROBE = "iphonevio_time_probe_v1"
EVENT_TIME_REPLY = "iphonevio_time_reply_v1"
EVENT_CLOCK_SAMPLE = "iphonevio_clock_sample_v1"
EVENT_CLOCK_REFRESH_REQUEST = "iphonevio_clock_refresh_request_v1"
EVENT_FRAME_CLOCK_ANCHOR = "iphonevio_frame_clock_anchor_v1"
EVENT_GROUP_COMMAND = "iphonevio_group_command_v1"
EVENT_GROUP_ACK = "iphonevio_group_ack_v1"
EVENT_GROUP_REQUEST = "iphonevio_group_request_v1"
EVENT_GROUP_STATE = "iphonevio_group_state_v1"
EVENT_EGO_PREVIEW_FRAME = "umi_capture_ego_preview_frame_v1"

ROLES = frozenset({"wrist_umi", "ego"})
PROFILES = {"wrist_umi": "handheld_umi", "ego": "chest_ego"}
GROUP_COMMANDS = frozenset({"prepare", "start", "stop"})
TERMINAL_ACK_STATES = frozenset(
    {"armed", "started", "finalized", "rejected", "stale_generation", "unsynchronized"}
)
COMMAND_LEAD_TIME_NS = 1_500_000_000
COMMAND_RETRY_INTERVAL_NS = 500_000_000
COMMAND_MAX_ATTEMPTS = 3
STOP_COMMAND_MAX_ATTEMPTS = 120
COMMAND_PROGRESS_TIMEOUT_NS = 30_000_000_000
MAX_CLOCK_SAMPLE_AGE_NS = 3_000_000_000
MAX_CLOCK_UNCERTAINTY_NS = 8_333_333
LATE_COMMAND_TOLERANCE_NS = 16_666_667
ONE_FRAME_SYNC_BUDGET_NS = 16_666_667
HARD_REJECT_SYNC_NS = 33_333_334
MAX_AUTOMATIC_START_ATTEMPTS = 3
MAX_AUTO_REARM_DELIVERY_ATTEMPTS = 5
MAX_EGO_PREVIEW_JPEG_BYTES = 160 * 1024
EGO_PREVIEW_ORIENTATIONS = frozenset(
    {"portrait", "landscape_left", "landscape_right"}
)
_SAFE_ID = re.compile(r"^[A-Za-z0-9._-]{1,128}$")


class CoordinationError(ValueError):
    """A fail-closed registration, command, or acknowledgement error."""


@dataclass(frozen=True)
class DeviceRegistration:
    device_id: str
    display_name: str
    role: str
    profile_id: str
    controller_capable: bool
    gripper_id: Optional[str]
    client_identity: str


@dataclass
class DeviceState:
    sid: str
    registration: DeviceRegistration
    connected_at_monotonic_ns: int
    last_ack: Optional[dict] = None
    last_clock_sample: Optional[dict] = None
    last_frame_clock_anchor: Optional[dict] = None


@dataclass
class PendingTransmission:
    command_id: str
    target_device_id: str
    payload: dict
    attempt_count: int
    next_attempt_monotonic_ns: int
    acknowledged: bool = False


@dataclass
class GroupSession:
    session_id: str
    generation: int
    controller_kind: str = "mac"
    controller_device_id: Optional[str] = None
    shared_device_control: bool = False
    auto_rearm_after_capture: bool = False
    auto_rearm_status: str = "disabled"
    predecessor_session_id: Optional[str] = None
    successor_session_id: Optional[str] = None
    device_ids_by_role: Dict[str, str] = field(default_factory=dict)
    registrations_by_device: Dict[str, DeviceRegistration] = field(default_factory=dict)
    planned_transitions: List[dict] = field(default_factory=list)
    acknowledgements: List[dict] = field(default_factory=list)
    completion_state: str = "preparing"
    upload_commit_authorized: bool = False
    stop_commit_authorized: bool = False
    partial_reasons: List[str] = field(default_factory=list)
    connection_interruptions: List[dict] = field(default_factory=list)
    membership_valid: bool = True
    upload_grants_by_device: Dict[str, dict] = field(default_factory=dict)
    ego_preview_last_sequence_by_device: Dict[str, int] = field(
        default_factory=dict, repr=False
    )


class DualCaptureCoordinator:
    """Own role/session/clock/command state; never infer a relative transform."""

    def __init__(
        self,
        recordings_dir: Path,
        *,
        monotonic_ns: Callable[[], int] = time.monotonic_ns,
        unix_time_ns: Callable[[], int] = time.time_ns,
    ):
        self._recordings_dir = recordings_dir
        self._session_root = recordings_dir / "group_sessions"
        self._monotonic_ns = monotonic_ns
        self._unix_time_ns = unix_time_ns
        self._lock = threading.RLock()
        self._devices_by_id: Dict[str, DeviceState] = {}
        self._device_id_by_sid: Dict[str, str] = {}
        self._active_session: Optional[GroupSession] = None
        self._pending: Dict[Tuple[str, str], PendingTransmission] = {}
        self._receiver_id = self._load_or_create_receiver_id()
        self._restored_upload_grants_by_device = self._load_frozen_upload_grants()

    @property
    def receiver_id(self) -> str:
        return self._receiver_id

    @property
    def active_session(self) -> Optional[GroupSession]:
        with self._lock:
            return self._active_session

    def connected_sid_for_role(self, role: str) -> Optional[str]:
        if role not in ROLES:
            raise CoordinationError("unsupported capture role")
        with self._lock:
            matches = [
                state.sid
                for state in self._devices_by_id.values()
                if state.registration.role == role
            ]
            if len(matches) > 1:
                raise CoordinationError(f"duplicate connected role: {role}")
            return matches[0] if matches else None

    def route_ego_preview_frame(self, sid: str, payload: dict) -> Tuple[str, dict]:
        decoded = _decode_ego_preview_frame(payload)
        with self._lock:
            source_device_id = self._device_id_by_sid.get(sid)
            state = self._devices_by_id.get(source_device_id) if source_device_id else None
            session = self._require_session_locked()
            if state is None or (
                state.registration.role != "ego"
                or decoded["capture_role"] != "ego"
                or decoded["device_id"] != source_device_id
                or session.device_ids_by_role.get("ego") != source_device_id
            ):
                raise CoordinationError("ego preview sender or role mismatch")
            if (
                decoded["session_id"] != session.session_id
                or decoded["generation"] != session.generation
            ):
                raise CoordinationError("ego preview session mismatch")
            if session.completion_state in {"completed", "partial", "finalizing"}:
                raise CoordinationError("ego preview session is no longer active")
            sequence = int(decoded["sequence"])
            last_sequence = session.ego_preview_last_sequence_by_device.get(
                source_device_id
            )
            if last_sequence is not None and sequence <= last_sequence:
                raise CoordinationError("ego preview sequence is not increasing")
            wrist_device_id = session.device_ids_by_role.get("wrist_umi")
            wrist = self._devices_by_id.get(wrist_device_id) if wrist_device_id else None
            if wrist is None:
                raise CoordinationError("ego preview wrist peer is offline")
            session.ego_preview_last_sequence_by_device[source_device_id] = sequence
            return wrist.sid, decoded

    def authorize_upload_initialize(self, file_identity: dict) -> dict:
        """Return a grant frozen atomically at the valid Stop boundary."""

        device_id = file_identity.get("device_id") if isinstance(file_identity, dict) else None
        required_identity_keys = {"filename", "device_id", "platform", "size_bytes", "sha256"}
        if not isinstance(device_id, str) or set(file_identity) != required_identity_keys:
            raise CoordinationError("invalid capture upload file identity")
        with self._lock:
            session = self._active_session
            if session is None:
                restored = self._restored_upload_grants_by_device.get(device_id)
                if restored is not None:
                    return self._bind_restored_upload_grant_locked(device_id, file_identity, restored)
                raise CoordinationError("no active group session")
            grant = session.upload_grants_by_device.get(device_id)
            if grant is not None and grant.get("file_identity") == file_identity:
                return dict(grant)
            restored = self._restored_upload_grants_by_device.get(device_id)
            if restored is not None and restored.get("file_identity") == file_identity:
                return dict(restored)
            if grant is None:
                if device_id not in session.device_ids_by_role.values():
                    raise CoordinationError("device is not a member of the authorized capture session")
                raise CoordinationError("capture upload is not authorized for this session")
            bound_identity = grant.get("file_identity")
            if bound_identity is None:
                raise CoordinationError("authorized upload grant has no frozen file identity")
            if bound_identity != file_identity:
                raise CoordinationError("authorized device upload is already bound to a different file identity")
            return dict(grant)

    def _bind_restored_upload_grant_locked(
        self, device_id: str, file_identity: dict, grant: dict
    ) -> dict:
        bound_identity = grant.get("file_identity")
        if bound_identity is None:
            raise CoordinationError("restored upload grant has no frozen file identity")
        if bound_identity != file_identity:
            raise CoordinationError("authorized device upload is already bound to a different file identity")
        return dict(grant)

    def register(self, sid: str, payload: dict) -> dict:
        registration = _decode_registration(payload)
        now = self._monotonic_ns()
        with self._lock:
            active = self._active_session
            if active is not None:
                session_role = next(
                    (
                        role
                        for role, device_id in active.device_ids_by_role.items()
                        if device_id == registration.device_id
                    ),
                    None,
                )
                if session_role is not None and session_role != registration.role:
                    raise CoordinationError("capture role is locked for the active session")
                role_owner = active.device_ids_by_role.get(registration.role)
                if role_owner not in {None, registration.device_id}:
                    raise CoordinationError(f"capture role {registration.role} is already occupied")
            previous = self._devices_by_id.get(registration.device_id)
            if previous is not None and previous.sid != sid:
                self._device_id_by_sid.pop(previous.sid, None)
            prior_device = self._device_id_by_sid.get(sid)
            if prior_device is not None and prior_device != registration.device_id:
                self._devices_by_id.pop(prior_device, None)
            restored_last_ack = previous.last_ack if previous is not None else None
            if restored_last_ack is None and active is not None:
                command_ids = (
                    set(active.planned_transitions[-1].get("command_ids", {}).values())
                    if active.planned_transitions
                    else set()
                )
                restored_last_ack = next(
                    (
                        ack
                        for ack in reversed(active.acknowledgements)
                        if ack.get("device_id") == registration.device_id
                        and ack.get("command_id") in command_ids
                        and ack.get("state") in TERMINAL_ACK_STATES
                    ),
                    None,
                )
            self._devices_by_id[registration.device_id] = DeviceState(
                sid=sid,
                registration=registration,
                connected_at_monotonic_ns=now,
                last_ack=restored_last_ack,
            )
            self._device_id_by_sid[sid] = registration.device_id
            return {
                "protocol_version": PROTOCOL_VERSION,
                "accepted": True,
                "receiver_id": self._receiver_id,
                "device_id": registration.device_id,
                "capture_role": registration.role,
                "coordinator_monotonic_ns": str(now),
            }

    def disconnect(self, sid: str) -> None:
        with self._lock:
            device_id = self._device_id_by_sid.pop(sid, None)
            if device_id is None:
                return
            state = self._devices_by_id.get(device_id)
            if state is not None and state.sid == sid:
                self._devices_by_id.pop(device_id, None)
            active = self._active_session
            if (
                active is not None
                and active.completion_state != "completed"
                and device_id in active.device_ids_by_role.values()
            ):
                phase = self._command_phase_locked(active)
                active.connection_interruptions.append(
                    {
                        "device_id": device_id,
                        "coordinator_monotonic_ns": str(self._monotonic_ns()),
                    }
                )
                active.membership_valid = False
                reason = f"device_disconnected:{device_id}:{phase}"
                if reason not in active.partial_reasons:
                    active.partial_reasons.append(reason)
                if phase in {"new", "preparing", "armed", "starting"}:
                    active.completion_state = "partial"
                    self._pending.clear()
                if not active.upload_grants_by_device:
                    active.upload_commit_authorized = False
                active.stop_commit_authorized = False
                self._write_manifest_locked(active)

    def make_time_reply(self, sid: str, payload: dict) -> dict:
        with self._lock:
            device_id = self._device_id_by_sid.get(sid)
        if device_id is None:
            raise CoordinationError("device is not registered")
        if payload.get("protocol_version") != PROTOCOL_VERSION:
            raise CoordinationError("unsupported protocol version")
        probe_id = _required_safe_text(payload, "probe_id")
        local_send = _required_uint_text(payload, "local_send_monotonic_ns")
        receive = self._monotonic_ns()
        send = self._monotonic_ns()
        return {
            "protocol_version": PROTOCOL_VERSION,
            "probe_id": probe_id,
            "device_id": device_id,
            "local_send_monotonic_ns": str(local_send),
            "coordinator_receive_monotonic_ns": str(receive),
            "coordinator_send_monotonic_ns": str(send),
        }

    def record_clock_sample(self, sid: str, payload: dict) -> None:
        sample = _decode_clock_sample(payload)
        received = self._monotonic_ns()
        with self._lock:
            device_id = self._device_id_by_sid.get(sid)
            state = self._devices_by_id.get(device_id) if device_id else None
            if state is None or sample["device_id"] != device_id:
                raise CoordinationError("clock sample device does not match socket")
            sample["received_coordinator_monotonic_ns"] = str(received)
            state.last_clock_sample = sample

    def record_frame_clock_anchor(self, sid: str, payload: dict) -> None:
        anchor = _decode_frame_clock_anchor(payload)
        received = self._monotonic_ns()
        with self._lock:
            device_id = self._device_id_by_sid.get(sid)
            state = self._devices_by_id.get(device_id) if device_id else None
            if state is None or anchor["device_id"] != device_id:
                raise CoordinationError("frame clock anchor device does not match socket")
            anchor["received_coordinator_monotonic_ns"] = str(received)
            state.last_frame_clock_anchor = anchor

    def begin_session(
        self,
        *,
        controller_kind: str = "mac",
        controller_device_id: Optional[str] = None,
        shared_device_control: bool = False,
        auto_rearm_after_capture: bool = False,
    ) -> GroupSession:
        with self._lock:
            if (
                self._active_session is not None
                and self._active_session.completion_state not in {"completed", "partial"}
            ):
                raise CoordinationError("active group session already exists")
            roles: Dict[str, str] = {}
            for device_id, state in self._devices_by_id.items():
                role = state.registration.role
                if role in roles:
                    raise CoordinationError(f"duplicate connected role: {role}")
                roles[role] = device_id
            if set(roles) != ROLES:
                raise CoordinationError("both wrist_umi and ego devices are required")
            if controller_kind not in {"mac", "device"}:
                raise CoordinationError("invalid controller kind")
            if controller_kind == "device":
                if controller_device_id not in roles.values():
                    raise CoordinationError("controller device is not in the session")
                controller_state = self._devices_by_id[controller_device_id]
                if not controller_state.registration.controller_capable:
                    raise CoordinationError("device did not opt in as controller")
            else:
                controller_device_id = None
                shared_device_control = False
            generation = self._active_session.generation + 1 if self._active_session else 1
            session = GroupSession(
                session_id=str(uuid.uuid4()),
                generation=generation,
                controller_kind=controller_kind,
                controller_device_id=controller_device_id,
                shared_device_control=shared_device_control,
                auto_rearm_after_capture=auto_rearm_after_capture,
                auto_rearm_status=(
                    "pending" if auto_rearm_after_capture else "disabled"
                ),
                device_ids_by_role=roles,
                registrations_by_device={
                    device_id: self._devices_by_id[device_id].registration
                    for device_id in roles.values()
                },
            )
            self._active_session = session
            self._pending.clear()
            self._write_manifest_locked(session)
            return session

    def authorize_device_request(self, sid: str) -> str:
        with self._lock:
            session = self._require_session_locked()
            device_id = self._device_id_by_sid.get(sid)
            if session.shared_device_control:
                state = self._devices_by_id.get(device_id) if device_id else None
                if (
                    device_id not in session.device_ids_by_role.values()
                    or state is None
                    or not state.registration.controller_capable
                ):
                    raise CoordinationError("device is not a shared group controller")
                return device_id
            if session.controller_kind != "device" or session.controller_device_id != device_id:
                raise CoordinationError("device is not the selected controller")
            return device_id

    def begin_or_authorize_device_session(
        self,
        sid: str,
        *,
        auto_rearm_after_capture: bool = False,
    ) -> GroupSession:
        with self._lock:
            device_id = self._device_id_by_sid.get(sid)
            if device_id is None:
                raise CoordinationError("device is not registered")
            session = self._active_session
            if session is None or session.completion_state in {"completed", "partial"}:
                return self.begin_session(
                    controller_kind="device",
                    controller_device_id=device_id,
                    shared_device_control=True,
                    auto_rearm_after_capture=auto_rearm_after_capture,
                )
            self.authorize_device_request(sid)
            return session

    def issue_device_request(
        self,
        sid: str,
        command: str,
        *,
        allow_stale_clock_for_stop: bool = False,
        auto_rearm_after_capture: bool = False,
    ) -> List[Tuple[str, dict]]:
        if command not in GROUP_COMMANDS:
            raise CoordinationError("unsupported group command")
        with self._lock:
            if command == "prepare":
                session = self.begin_or_authorize_device_session(
                    sid,
                    auto_rearm_after_capture=auto_rearm_after_capture,
                )
                device_id = self._device_id_by_sid.get(sid)
            else:
                session = self._require_session_locked()
                device_id = self.authorize_device_request(sid)
            if device_id is None:
                raise CoordinationError("device is not registered")
            if self._request_is_superseded_locked(session, command):
                return []
            return self.issue_command(
                command,
                requested_by_device_id=device_id,
                allow_stale_clock_for_stop=allow_stale_clock_for_stop,
            )

    def recover_device_session(
        self,
        sid: str,
        *,
        auto_rearm_after_capture: bool = False,
    ) -> List[Tuple[str, dict]]:
        with self._lock:
            device_id = self._device_id_by_sid.get(sid)
            state = self._devices_by_id.get(device_id) if device_id else None
            if state is None or not state.registration.controller_capable:
                raise CoordinationError("registered controller-capable device required")
            if {item.registration.role for item in self._devices_by_id.values()} != ROLES:
                raise CoordinationError("both wrist_umi and ego devices are required")
            previous = self._active_session
            if previous is not None and previous.completion_state not in {"completed", "partial"}:
                reason = f"operator_recovery_reset:{device_id}"
                if reason not in previous.partial_reasons:
                    previous.partial_reasons.append(reason)
                previous.completion_state = "partial"
                previous.upload_commit_authorized = False
                previous.stop_commit_authorized = False
                self._write_manifest_locked(previous)
            self.begin_session(
                controller_kind="device",
                controller_device_id=device_id,
                shared_device_control=True,
                auto_rearm_after_capture=auto_rearm_after_capture,
            )
            return self.issue_command("prepare", requested_by_device_id=device_id, recovery_reset=True)

    def reset_device_session(self, sid: str) -> None:
        with self._lock:
            session = self._require_session_locked()
            device_id = self.authorize_device_request(sid)
            phase = self._command_phase_locked(session)
            if phase not in {"new", "preparing", "armed", "starting"}:
                raise CoordinationError("group reset is only allowed before recording")
            reason = f"operator_reset:{device_id}"
            if reason not in session.partial_reasons:
                session.partial_reasons.append(reason)
            session.completion_state = "partial"
            session.upload_commit_authorized = False
            session.stop_commit_authorized = False
            self._pending.clear()
            self._write_manifest_locked(session)

    def issue_mac_request(
        self,
        command: str,
        *,
        allow_stale_clock_for_stop: bool = False,
    ) -> List[Tuple[str, dict]]:
        if command not in GROUP_COMMANDS:
            raise CoordinationError("unsupported group command")
        with self._lock:
            session = self._require_session_locked()
            if session.controller_kind != "mac":
                raise CoordinationError("Mac is not the selected controller")
            if self._request_is_superseded_locked(session, command):
                return []
            return self.issue_command(command, allow_stale_clock_for_stop=allow_stale_clock_for_stop)

    def issue_emergency_stop(self) -> List[Tuple[str, dict]]:
        """Stop both devices after clock refresh timeout, permanently fail-closed."""

        with self._lock:
            session = self._require_session_locked()
            if session.controller_kind != "mac":
                raise CoordinationError("Mac is not the selected controller")
            if self._request_is_superseded_locked(session, "stop"):
                return []
            self._invalidate_for_emergency_stop_locked(session)
            return self.issue_command("stop", allow_stale_clock_for_stop=True)

    def issue_device_emergency_stop(self, sid: str) -> List[Tuple[str, dict]]:
        """Issue a controller-device emergency Stop with the same permanent gate."""

        with self._lock:
            session = self._require_session_locked()
            device_id = self.authorize_device_request(sid)
            if self._request_is_superseded_locked(session, "stop"):
                return []
            self._invalidate_for_emergency_stop_locked(session)
            return self.issue_command(
                "stop",
                requested_by_device_id=device_id,
                allow_stale_clock_for_stop=True,
            )

    def _invalidate_for_emergency_stop_locked(self, session: GroupSession) -> None:
        reason = "stop_clock_synchronization_timeout"
        if reason not in session.partial_reasons:
            session.partial_reasons.append(reason)
        session.membership_valid = False
        session.completion_state = "partial"
        session.upload_commit_authorized = False
        session.stop_commit_authorized = False
        session.upload_grants_by_device.clear()
        self._write_manifest_locked(session)

    def issue_command(
        self,
        command: str,
        *,
        requested_by_device_id: Optional[str] = None,
        allow_stale_clock_for_stop: bool = False,
        recovery_reset: bool = False,
        automatic_rearm: bool = False,
    ) -> List[Tuple[str, dict]]:
        if command not in GROUP_COMMANDS:
            raise CoordinationError("unsupported group command")
        now = self._monotonic_ns()
        with self._lock:
            session = self._require_session_locked()
            if command != "stop" and not session.membership_valid:
                raise CoordinationError("group membership was interrupted; re-prepare both devices")
            if command == "start":
                self._require_all_session_devices_connected_locked(session)
                self._require_all_devices_armed_locked(session)
                self._require_fresh_clock_samples_locked(session, now)
            elif command == "stop" and not allow_stale_clock_for_stop:
                self._require_fresh_clock_samples_locked(session, now)
            deadline = None if command == "prepare" else now + COMMAND_LEAD_TIME_NS
            transition = {
                "command": command,
                "requested_by_device_id": requested_by_device_id,
                "recovery_reset": recovery_reset,
                "automatic_rearm": automatic_rearm,
                "issued_coordinator_monotonic_ns": str(now),
                "coordinator_deadline_ns": str(deadline) if deadline is not None else None,
                "command_ids": {},
            }
            transmissions: List[Tuple[str, dict]] = []
            for role in sorted(ROLES):
                device_id = session.device_ids_by_role[role]
                state = self._devices_by_id.get(device_id)
                command_id = uuid.uuid4().hex
                payload = {
                    "protocol_version": PROTOCOL_VERSION,
                    "command": command,
                    "command_id": command_id,
                    "session_id": session.session_id,
                    "generation": session.generation,
                    "target_device_id": device_id,
                    "controller_kind": session.controller_kind,
                    "controller_device_id": session.controller_device_id,
                    "shared_device_control": session.shared_device_control,
                    "recovery_reset": recovery_reset,
                    "automatic_rearm": automatic_rearm,
                }
                if deadline is not None:
                    payload["coordinator_deadline_ns"] = str(deadline)
                transition["command_ids"][role] = command_id
                self._pending[(command_id, device_id)] = PendingTransmission(
                    command_id=command_id,
                    target_device_id=device_id,
                    payload=payload,
                    attempt_count=1,
                    next_attempt_monotonic_ns=now + COMMAND_RETRY_INTERVAL_NS,
                )
                if state is not None:
                    transmissions.append((state.sid, payload))
            session.planned_transitions.append(transition)
            self._write_manifest_locked(session)
            return transmissions

    def _request_is_superseded_locked(self, session: GroupSession, command: str) -> bool:
        phase = self._command_phase_locked(session)
        allowed = {"new": {"prepare"}, "armed": {"start"}, "running": {"stop"}}
        if command in allowed.get(phase, set()):
            return False
        if phase in {"preparing", "starting", "stopping", "terminal"}:
            return True
        raise CoordinationError(f"group command {command} is invalid while session is {phase}")

    @staticmethod
    def _command_phase_locked(session: GroupSession) -> str:
        if session.completion_state in {"completed", "partial"}:
            return "terminal"
        if not session.planned_transitions:
            return "new"
        transition = session.planned_transitions[-1]
        command = transition.get("command")
        command_ids = set(transition.get("command_ids", {}).values())
        terminal_state = {"prepare": "armed", "start": "started", "stop": "finalized"}.get(command)
        reached = {
            ack.get("command_id")
            for ack in session.acknowledgements
            if ack.get("command_id") in command_ids and ack.get("state") == terminal_state
        }
        settled = len(command_ids) == len(ROLES) and reached == command_ids
        if command == "prepare":
            return "armed" if settled else "preparing"
        if command == "start":
            return "running" if settled else "starting"
        if command == "stop":
            return "terminal" if settled else "stopping"
        raise CoordinationError("session contains an unsupported transition")

    def record_ack(self, sid: str, payload: dict) -> List[Tuple[str, dict]]:
        ack = _decode_ack(payload)
        with self._lock:
            device_id = self._device_id_by_sid.get(sid)
            if device_id is None or ack["device_id"] != device_id:
                raise CoordinationError("ack device identity mismatch")
            role = self._devices_by_id[device_id].registration.role
            logical_acceptance = ack["logical_window_acceptance"]
            if logical_acceptance is not None and (
                role != "wrist_umi" or ack["command"] != "stop" or ack["state"] != "finalized"
            ):
                raise CoordinationError("logical window acceptance is only valid for finalized wrist stop")
            artifact_names = {
                artifact.get("name")
                for artifact in (ack.get("artifacts") or [])
                if isinstance(artifact, dict)
            }
            if "capture_logical_window.json" in artifact_names and logical_acceptance is None:
                raise CoordinationError("logical window artifact requires acceptance summary")
            session = self._require_session_locked()
            if ack["session_id"] != session.session_id or ack["generation"] != session.generation:
                raise CoordinationError("ack session or generation mismatch")
            key = (ack["command_id"], device_id)
            pending = self._pending.get(key)
            if pending is None:
                raise CoordinationError("ack does not match a targeted command")
            previous_terminal = next(
                (
                    item
                    for item in reversed(session.acknowledgements)
                    if item.get("command_id") == ack["command_id"]
                    and item.get("device_id") == device_id
                    and item.get("state") in TERMINAL_ACK_STATES
                ),
                None,
            )
            if previous_terminal is not None and ack["state"] not in TERMINAL_ACK_STATES:
                pending.acknowledged = True
                self._devices_by_id[device_id].last_ack = previous_terminal
                return []
            pending.acknowledged = pending.acknowledged or ack["state"] in TERMINAL_ACK_STATES
            if not pending.acknowledged:
                pending.next_attempt_monotonic_ns = self._monotonic_ns() + COMMAND_PROGRESS_TIMEOUT_NS
            session.acknowledgements.append(ack)
            self._update_stop_commit_locked(session)
            retryable_start_miss = (
                ack["command"] == "start"
                and ack["state"] == "unsynchronized"
                and ack["partial_reason"] == "scheduled_deadline_missed"
            )
            if ack["partial_reason"] is not None and not retryable_start_miss:
                reason = f'{ack["state"]}:{device_id}:{ack["partial_reason"]}'
                if reason not in session.partial_reasons:
                    session.partial_reasons.append(reason)
            state = self._devices_by_id.get(device_id)
            if state is not None:
                previous = state.last_ack
                same_command = isinstance(previous, dict) and previous.get("command_id") == ack["command_id"]
                downgrade = (
                    same_command
                    and previous.get("state") in TERMINAL_ACK_STATES
                    and ack["state"] not in TERMINAL_ACK_STATES
                )
                if not downgrade:
                    state.last_ack = ack
            if retryable_start_miss:
                settled, transmissions = self._retry_start_after_settled_deadline_miss_locked(session)
                if transmissions:
                    return transmissions
                if not settled:
                    self._write_manifest_locked(session)
                    return []
            self._update_transition_evidence_locked(session)
            self._update_completion_locked(session)
            self._write_manifest_locked(session)
            return self._auto_rearm_after_completed_uploads_locked(session)

    def _auto_rearm_after_completed_uploads_locked(
        self, session: GroupSession
    ) -> List[Tuple[str, dict]]:
        if (
            self._active_session is not session
            or not session.auto_rearm_after_capture
            or session.auto_rearm_status != "pending"
            or session.partial_reasons
            or not session.membership_valid
            or not session.stop_commit_authorized
            or session.completion_state != "completed"
        ):
            return []
        if not session.planned_transitions:
            return []
        transition = session.planned_transitions[-1]
        if transition.get("command") != "stop":
            return []
        command_ids = set(transition.get("command_ids", {}).values())
        finalized_ids = {
            ack.get("command_id")
            for ack in session.acknowledgements
            if ack.get("command_id") in command_ids
            and ack.get("state") == "finalized"
            and _artifact_references_are_complete(ack.get("artifacts"))
        }
        if len(command_ids) != len(ROLES) or finalized_ids != command_ids:
            return []
        if set(session.device_ids_by_role.values()) != set(self._devices_by_id):
            session.auto_rearm_status = "failed"
            self._write_manifest_locked(session)
            return []
        successor = GroupSession(
            session_id=str(uuid.uuid4()),
            generation=session.generation + 1,
            controller_kind=session.controller_kind,
            controller_device_id=session.controller_device_id,
            shared_device_control=session.shared_device_control,
            auto_rearm_after_capture=True,
            auto_rearm_status="pending",
            predecessor_session_id=session.session_id,
            device_ids_by_role=dict(session.device_ids_by_role),
            registrations_by_device=dict(session.registrations_by_device),
        )
        session.auto_rearm_status = "rearmed"
        session.successor_session_id = successor.session_id
        self._active_session = successor
        self._pending.clear()
        self._write_manifest_locked(session)
        self._write_manifest_locked(successor)
        return self.issue_command(
            "prepare",
            requested_by_device_id=session.controller_device_id,
            automatic_rearm=True,
        )

    @staticmethod
    def _update_stop_commit_locked(session: GroupSession) -> None:
        if not session.planned_transitions:
            return
        transition = session.planned_transitions[-1]
        if transition.get("command") != "stop":
            return
        command_ids = set(transition.get("command_ids", {}).values())
        scheduled_ids = {
            ack.get("command_id")
            for ack in session.acknowledgements
            if ack.get("command_id") in command_ids
            and ack.get("state") in {"scheduled", "finalizing", "finalized"}
        }
        session.stop_commit_authorized = (
            session.membership_valid
            and not session.partial_reasons
            and len(command_ids) == len(ROLES)
            and scheduled_ids == command_ids
        )

    def _retry_start_after_settled_deadline_miss_locked(
        self, session: GroupSession
    ) -> Tuple[bool, List[Tuple[str, dict]]]:
        transition = session.planned_transitions[-1]
        if transition.get("command") != "start":
            return False, []
        command_ids = set(transition.get("command_ids", {}).values())
        retryable_ids = {
            ack.get("command_id")
            for ack in session.acknowledgements
            if ack.get("command_id") in command_ids
            and ack.get("command") == "start"
            and ack.get("state") == "unsynchronized"
            and ack.get("partial_reason") == "scheduled_deadline_missed"
        }
        if len(command_ids) != len(ROLES) or retryable_ids != command_ids:
            return False, []
        attempts = sum(item.get("command") == "start" for item in session.planned_transitions)
        transition["automatic_retry_reason"] = "scheduled_deadline_missed"
        if attempts >= MAX_AUTOMATIC_START_ATTEMPTS:
            transition["automatic_retry_exhausted"] = True
            if "start_automatic_retry_exhausted" not in session.partial_reasons:
                session.partial_reasons.append("start_automatic_retry_exhausted")
            return True, []
        transition["automatic_retry_scheduled"] = True
        transition["automatic_retry_attempt"] = attempts + 1
        session.completion_state = "preparing"
        return True, self.issue_command(
            "start", requested_by_device_id=transition.get("requested_by_device_id")
        )

    def _require_all_devices_armed_locked(self, session: GroupSession) -> None:
        for role in sorted(ROLES):
            device_id = session.device_ids_by_role[role]
            ack = next(
                (
                    item
                    for item in reversed(session.acknowledgements)
                    if item.get("device_id") == device_id
                    and item.get("session_id") == session.session_id
                    and item.get("generation") == session.generation
                    and item.get("command") == "prepare"
                    and item.get("state") == "armed"
                ),
                None,
            )
            if ack is None:
                raise CoordinationError(f"device is not armed:{role}")

    def _require_all_session_devices_connected_locked(self, session: GroupSession) -> None:
        for role in sorted(ROLES):
            if session.device_ids_by_role[role] not in self._devices_by_id:
                raise CoordinationError(f"session device is offline:{role}")

    def _require_fresh_clock_samples_locked(self, session: GroupSession, now: int) -> None:
        for role in sorted(ROLES):
            device_id = session.device_ids_by_role[role]
            state = self._devices_by_id.get(device_id)
            sample = state.last_clock_sample if state is not None else None
            if sample is None:
                raise CoordinationError(f"clock mapping unavailable:{role}")
            age = max(0, now - int(sample["received_coordinator_monotonic_ns"]))
            if age > MAX_CLOCK_SAMPLE_AGE_NS:
                raise CoordinationError(f"clock mapping stale:{role}")
            if int(sample["uncertainty_ns"]) > MAX_CLOCK_UNCERTAINTY_NS:
                raise CoordinationError(f"clock uncertainty too high:{role}")

    def due_retries(self) -> List[Tuple[str, dict]]:
        now = self._monotonic_ns()
        with self._lock:
            result: List[Tuple[str, dict]] = []
            session = self._active_session
            for pending in self._pending.values():
                if pending.acknowledged or pending.next_attempt_monotonic_ns > now:
                    continue
                state = self._devices_by_id.get(pending.target_device_id)
                if state is None:
                    continue
                maximum = (
                    STOP_COMMAND_MAX_ATTEMPTS
                    if pending.payload.get("command") == "stop"
                    else (
                        MAX_AUTO_REARM_DELIVERY_ATTEMPTS
                        if pending.payload.get("automatic_rearm") is True
                        else COMMAND_MAX_ATTEMPTS
                    )
                )
                if pending.attempt_count >= maximum:
                    if session is not None:
                        reason = f"ack_timeout:{pending.target_device_id}:{pending.command_id}"
                        if reason not in session.partial_reasons:
                            session.partial_reasons.append(reason)
                        session.completion_state = "partial"
                        session.upload_commit_authorized = False
                        session.stop_commit_authorized = False
                        self._write_manifest_locked(session)
                    pending.acknowledged = True
                    continue
                pending.attempt_count += 1
                pending.next_attempt_monotonic_ns = now + COMMAND_RETRY_INTERVAL_NS
                result.append((state.sid, dict(pending.payload)))
            return result

    def snapshot(self) -> dict:
        with self._lock:
            devices = []
            for device_id, state in sorted(self._devices_by_id.items()):
                registration = state.registration
                clock = dict(state.last_clock_sample) if state.last_clock_sample else None
                if clock is not None:
                    received = int(clock["received_coordinator_monotonic_ns"])
                    clock["receiver_sample_age_ns"] = str(max(0, self._monotonic_ns() - received))
                frame_anchor = (
                    dict(state.last_frame_clock_anchor) if state.last_frame_clock_anchor else None
                )
                if frame_anchor is not None:
                    received = int(frame_anchor["received_coordinator_monotonic_ns"])
                    frame_anchor["receiver_sample_age_ns"] = str(
                        max(0, self._monotonic_ns() - received)
                    )
                devices.append(
                    {
                        "device_id": device_id,
                        "display_name": registration.display_name,
                        "capture_role": registration.role,
                        "profile_id": registration.profile_id,
                        "client_identity": registration.client_identity,
                        "controller_capable": registration.controller_capable,
                        "last_ack_state": state.last_ack.get("state") if state.last_ack else None,
                        "preparation": state.last_ack.get("preparation") if state.last_ack else None,
                        "clock": clock,
                        "frame_clock_anchor": frame_anchor,
                    }
                )
            session = self._active_session
            return {
                "protocol_version": PROTOCOL_VERSION,
                "group_features_enabled": True,
                "receiver_id": self._receiver_id,
                "frozen_upload_grants_by_device": {
                    device_id: dict(grant)
                    for device_id, grant in self._restored_upload_grants_by_device.items()
                    if isinstance(grant.get("file_identity"), dict)
                },
                "devices": devices,
                "session": _session_payload(session) if session else None,
                "connected_roles": sorted(
                    state.registration.role for state in self._devices_by_id.values()
                ),
                "policy": {
                    "command_lead_time_ns": str(COMMAND_LEAD_TIME_NS),
                    "maximum_clock_sample_age_ns": str(MAX_CLOCK_SAMPLE_AGE_NS),
                    "maximum_clock_uncertainty_ns": str(MAX_CLOCK_UNCERTAINTY_NS),
                    "late_command_tolerance_ns": str(LATE_COMMAND_TOLERANCE_NS),
                    "one_frame_sync_budget_ns": str(ONE_FRAME_SYNC_BUDGET_NS),
                    "hard_reject_sync_ns": str(HARD_REJECT_SYNC_NS),
                    "coordinate_relationship": "independent_device_local_arkit_frames",
                },
            }

    def _require_session_locked(self) -> GroupSession:
        if self._active_session is None:
            raise CoordinationError("no active group session")
        return self._active_session

    def _update_completion_locked(self, session: GroupSession) -> None:
        if session.partial_reasons or not session.membership_valid:
            session.stop_commit_authorized = False
        latest_by_device: Dict[str, dict] = {}
        for ack in session.acknowledgements:
            latest_by_device[ack["device_id"]] = ack
        expected = set(session.device_ids_by_role.values())
        require_receiver_upload = all(
            registration.controller_capable
            for registration in session.registrations_by_device.values()
        )
        locally_finalized = {
            device_id
            for device_id, ack in latest_by_device.items()
            if ack.get("state") == "finalized"
            and _artifact_references_are_complete(ack.get("artifacts"))
        }
        latest_transition = session.planned_transitions[-1] if session.planned_transitions else None
        was_authorized = bool(session.upload_grants_by_device)
        if not was_authorized:
            session.upload_commit_authorized = (
                locally_finalized == expected
                and not session.partial_reasons
                and session.membership_valid
                and isinstance(latest_transition, dict)
                and latest_transition.get("command") == "stop"
                and latest_transition.get("within_one_frame") is True
                and latest_transition.get("hard_reject") is False
            )
        if session.upload_commit_authorized and not was_authorized and not session.upload_grants_by_device:
            authorized_at = str(self._monotonic_ns())
            grants = {}
            for role, device_id in session.device_ids_by_role.items():
                latest_ack = latest_by_device.get(device_id)
                file_identity = _zip_upload_identity_from_ack(latest_ack)
                if file_identity is None:
                    session.upload_commit_authorized = False
                    session.completion_state = "partial"
                    reason = f"finalized_upload_identity_missing:{device_id}"
                    if reason not in session.partial_reasons:
                        session.partial_reasons.append(reason)
                    session.upload_grants_by_device.clear()
                    return
                grants[device_id] = {
                    "schema_version": 1,
                    "session_id": session.session_id,
                    "generation": session.generation,
                    "device_id": device_id,
                    "capture_role": role,
                    "authorized_coordinator_monotonic_ns": authorized_at,
                    "file_identity": file_identity,
                }
            session.upload_grants_by_device = grants
            self._restored_upload_grants_by_device.update(
                {
                    device_id: dict(grant)
                    for device_id, grant in session.upload_grants_by_device.items()
                }
            )
            self._write_frozen_grant_ledger_locked()
        if session.upload_grants_by_device:
            session.upload_commit_authorized = True
        uploaded = {
            device_id
            for device_id, ack in latest_by_device.items()
            if ack.get("state") == "finalized"
            and _artifact_references_are_complete(
                ack.get("artifacts"),
                require_receiver_upload=require_receiver_upload,
            )
            and (
                not require_receiver_upload
                or _zip_upload_identity_from_ack(ack)
                    == session.upload_grants_by_device
                        .get(device_id, {})
                        .get("file_identity")
            )
        }
        if uploaded == expected and session.upload_commit_authorized and not session.partial_reasons:
            session.completion_state = "completed"
        elif session.partial_reasons:
            session.completion_state = "partial"
        elif locally_finalized:
            session.completion_state = "finalizing"
        elif session.planned_transitions:
            transition = session.planned_transitions[-1]
            command_ids = set(transition.get("command_ids", {}).values())
            transition_acks = [
                ack for ack in session.acknowledgements if ack.get("command_id") in command_ids
            ]
            if transition.get("command") == "stop" and any(
                ack.get("state") in {"finalizing", "finalized"} for ack in transition_acks
            ):
                session.completion_state = "finalizing"
            elif any(
                ack.get("state") in {"rejected", "stale_generation", "unsynchronized"}
                for ack in transition_acks
            ):
                session.completion_state = "partial"

    def _update_transition_evidence_locked(self, session: GroupSession) -> None:
        for transition in session.planned_transitions:
            if transition.get("command") not in {"start", "stop"}:
                continue
            actuals = {}
            for role, command_id in transition.get("command_ids", {}).items():
                ack = next(
                    (
                        item
                        for item in reversed(session.acknowledgements)
                        if item.get("command_id") == command_id
                        and item.get("actual_coordinator_monotonic_ns") is not None
                    ),
                    None,
                )
                if ack is not None:
                    actuals[role] = int(ack["actual_coordinator_monotonic_ns"])
            transition["actual_coordinator_monotonic_ns_by_role"] = {
                role: str(value) for role, value in sorted(actuals.items())
            }
            if set(actuals) != ROLES:
                continue
            gap = max(actuals.values()) - min(actuals.values())
            transition["observed_boundary_gap_ns"] = str(gap)
            transition["within_one_frame"] = gap <= ONE_FRAME_SYNC_BUDGET_NS
            transition["hard_reject"] = gap > HARD_REJECT_SYNC_NS
            if gap > ONE_FRAME_SYNC_BUDGET_NS:
                reason = f'{transition["command"]}_boundary_gap_exceeds_one_frame:{gap}'
                if reason not in session.partial_reasons:
                    session.partial_reasons.append(reason)

    def _write_manifest_locked(self, session: GroupSession) -> None:
        session_dir = self._session_root / session.session_id
        session_dir.mkdir(parents=True, exist_ok=True)
        destination = session_dir / "session_manifest.json"
        temporary = session_dir / ".session_manifest.writing"
        payload = {
            "schema_version": 1,
            "kind": "umi_capture_dual_capture_session",
            "receiver_id": self._receiver_id,
            "session": _session_payload(session),
            "devices": [
                _registration_payload(registration)
                for registration in session.registrations_by_device.values()
            ],
            "protocol": {"version": PROTOCOL_VERSION, "update_event_unchanged": True, "pose_packet_bytes": 72},
            "synchronization_claim": "bounded monotonic clock mapping; independent local ARKit frames",
            "updated_unix_ns": str(self._unix_time_ns()),
        }
        with temporary.open("wb") as handle:
            handle.write((json.dumps(payload, indent=2, sort_keys=True) + "\n").encode("utf-8"))
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, destination)

    def _load_or_create_receiver_id(self) -> str:
        identity_path = self._recordings_dir / "receiver_identity.json"
        try:
            payload = json.loads(identity_path.read_text(encoding="utf-8"))
            return str(uuid.UUID(payload["receiver_id"])).lower()
        except (OSError, KeyError, TypeError, ValueError, json.JSONDecodeError):
            pass
        self._recordings_dir.mkdir(parents=True, exist_ok=True)
        receiver_id = str(uuid.uuid4()).lower()
        temporary = self._recordings_dir / ".receiver_identity.writing"
        temporary.write_text(
            json.dumps({"receiver_id": receiver_id}, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        os.replace(temporary, identity_path)
        return receiver_id

    def _load_frozen_upload_grants(self) -> Dict[str, dict]:
        path = self._recordings_dir / "frozen_upload_grants.json"
        try:
            payload = json.loads(path.read_text(encoding="utf-8"))
            if (
                payload.get("schema_version") != 1
                or payload.get("kind") != "umi_capture_frozen_upload_grants"
                or payload.get("receiver_id") != self._receiver_id
                or not isinstance(payload.get("grants_by_device"), dict)
            ):
                return {}
            result: Dict[str, dict] = {}
            for device_id, grant in payload["grants_by_device"].items():
                if not _valid_persisted_upload_grant(device_id, grant):
                    return {}
                result[device_id] = dict(grant)
            return result
        except (OSError, TypeError, ValueError, json.JSONDecodeError):
            return {}

    def _write_frozen_grant_ledger_locked(self) -> None:
        self._recordings_dir.mkdir(parents=True, exist_ok=True)
        destination = self._recordings_dir / "frozen_upload_grants.json"
        temporary = self._recordings_dir / ".frozen_upload_grants.writing"
        payload = {
            "schema_version": 1,
            "kind": "umi_capture_frozen_upload_grants",
            "receiver_id": self._receiver_id,
            "grants_by_device": self._restored_upload_grants_by_device,
            "updated_unix_ns": str(self._unix_time_ns()),
        }
        with temporary.open("wb") as handle:
            handle.write((json.dumps(payload, indent=2, sort_keys=True) + "\n").encode("utf-8"))
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, destination)


def _decode_registration(payload: dict) -> DeviceRegistration:
    if not isinstance(payload, dict) or payload.get("protocol_version") != PROTOCOL_VERSION:
        raise CoordinationError("unsupported registration protocol")
    device_id = _required_uuid(payload, "device_id")
    display_name = _required_display_name(payload)
    role = _required_safe_text(payload, "capture_role")
    profile_id = _required_safe_text(payload, "profile_id")
    if role not in ROLES or PROFILES.get(role) != profile_id:
        raise CoordinationError("role/profile mismatch")
    # Protocol-v1 legacy clients send a camera/body binding object. UMI Capture
    # accepts it only as an ignored compatibility placeholder and never stores,
    # solves, displays, or exports it.
    legacy_binding = payload.get("calibration")
    if legacy_binding is not None and not isinstance(legacy_binding, dict):
        raise CoordinationError("invalid compatibility binding")
    gripper_id = payload.get("gripper_id")
    if role == "ego" and gripper_id is not None:
        raise CoordinationError("ego role cannot claim gripper semantics")
    if gripper_id is not None and (
        not isinstance(gripper_id, str) or _SAFE_ID.fullmatch(gripper_id) is None
    ):
        raise CoordinationError("invalid gripper id")
    client_metadata = payload.get("client_metadata")
    if client_metadata is not None and not isinstance(client_metadata, dict):
        raise CoordinationError("invalid client metadata")
    metadata_identity = (
        client_metadata.get("app_name") if isinstance(client_metadata, dict) else None
    )
    if metadata_identity is not None and not isinstance(metadata_identity, str):
        raise CoordinationError("invalid client metadata app name")
    identity = (
        metadata_identity
        or payload.get("client_identity")
        or payload.get("app_name")
        or "iPhoneVIO"
    )
    if not isinstance(identity, str):
        identity = "iPhoneVIO"
    compact_identity = "".join(
        character for character in identity.casefold() if character.isalnum()
    )
    normalized_identity = (
        "UMI Capture" if compact_identity.startswith("umicapture") else "iPhoneVIO"
    )
    return DeviceRegistration(
        device_id=device_id,
        display_name=display_name,
        role=role,
        profile_id=profile_id,
        controller_capable=payload.get("controller_capable") is True,
        gripper_id=gripper_id,
        client_identity=normalized_identity,
    )


def _decode_ack(payload: dict) -> dict:
    if not isinstance(payload, dict) or payload.get("protocol_version") != PROTOCOL_VERSION:
        raise CoordinationError("unsupported ack protocol")
    ack = {
        "command": _required_safe_text(payload, "command"),
        "command_id": _required_safe_text(payload, "command_id"),
        "session_id": _required_uuid(payload, "session_id"),
        "generation": payload.get("generation"),
        "device_id": _required_uuid(payload, "device_id"),
        "state": _required_safe_text(payload, "state"),
        "planned_coordinator_monotonic_ns": payload.get("planned_coordinator_monotonic_ns"),
        "actual_local_monotonic_ns": payload.get("actual_local_monotonic_ns"),
        "actual_coordinator_monotonic_ns": payload.get("actual_coordinator_monotonic_ns"),
        "planned_start_local_ns": payload.get("planned_start_local_ns"),
        "planned_stop_local_ns": payload.get("planned_stop_local_ns"),
        "first_frame_coordinator_monotonic_ns": payload.get("first_frame_coordinator_monotonic_ns"),
        "last_frame_coordinator_monotonic_ns": payload.get("last_frame_coordinator_monotonic_ns"),
        "rejected_frames_before_start": payload.get("rejected_frames_before_start"),
        "rejected_frames_at_or_after_stop": payload.get("rejected_frames_at_or_after_stop"),
        "first_arkit_timestamp_s": payload.get("first_arkit_timestamp_s"),
        "last_arkit_timestamp_s": payload.get("last_arkit_timestamp_s"),
        "clock": payload.get("clock"),
        "artifacts": payload.get("artifacts"),
        "logical_window_acceptance": _decode_logical_window_acceptance(
            payload.get("logical_window_acceptance")
        ),
        "partial_reason": _optional_safe_text(payload, "partial_reason"),
        "preparation": _decode_preparation(payload.get("preparation")),
    }
    if not isinstance(ack["generation"], int) or ack["generation"] < 0:
        raise CoordinationError("invalid ack generation")
    if ack["command"] not in GROUP_COMMANDS or ack["state"] not in (
        TERMINAL_ACK_STATES | {"received", "scheduled", "finalizing"}
    ):
        raise CoordinationError("invalid ack command or state")
    for key in ("first_arkit_timestamp_s", "last_arkit_timestamp_s"):
        value = ack[key]
        if value is not None and (
            not isinstance(value, (int, float)) or isinstance(value, bool) or not math.isfinite(value)
        ):
            raise CoordinationError(f"invalid {key}")
    for key in (
        "planned_coordinator_monotonic_ns",
        "actual_local_monotonic_ns",
        "actual_coordinator_monotonic_ns",
        "planned_start_local_ns",
        "planned_stop_local_ns",
        "first_frame_coordinator_monotonic_ns",
        "last_frame_coordinator_monotonic_ns",
    ):
        ack[key] = _optional_uint_text_value(ack[key], key)
    for key in ("rejected_frames_before_start", "rejected_frames_at_or_after_stop"):
        value = ack[key]
        if value is not None and (
            not isinstance(value, int) or isinstance(value, bool) or value < 0
        ):
            raise CoordinationError(f"invalid {key}")
    planned = ack["planned_coordinator_monotonic_ns"]
    actual = ack["actual_coordinator_monotonic_ns"]
    if planned is not None and actual is not None:
        residual = abs(int(actual) - int(planned))
        ack["boundary_residual_ns"] = str(residual)
        ack["boundary_within_one_frame"] = residual <= ONE_FRAME_SYNC_BUDGET_NS
        ack["boundary_hard_reject"] = residual > HARD_REJECT_SYNC_NS
    return ack


def _decode_preparation(value: object) -> Optional[dict]:
    if value is None:
        return None
    if not isinstance(value, dict):
        raise CoordinationError("invalid preparation evidence")
    phase = value.get("phase")
    if phase not in {"stationary_imu", "ready"}:
        raise CoordinationError("unsupported preparation phase")
    result = {"phase": phase}
    for key in ("stationary_duration_s", "gyro_rms_rad_s", "gyro_peak_rad_s"):
        number = value.get(key)
        if number is not None:
            if (
                not isinstance(number, (int, float))
                or isinstance(number, bool)
                or not math.isfinite(number)
                or number < 0
            ):
                raise CoordinationError(f"invalid preparation {key}")
            result[key] = float(number)
    return result


def _decode_logical_window_acceptance(value: object) -> Optional[dict]:
    if value is None:
        return None
    required = {
        "schema_version",
        "mode",
        "interval",
        "within_one_frame",
        "one_frame_budget_ns",
        "maximum_observed_boundary_gap_ns",
        "maximum_combined_uncertainty_ns",
        "logical_timestamp_deadline_stop",
        "physical_collector_deadline_stop",
        "raw_artifacts_modified",
    }
    if not isinstance(value, dict) or set(value) != required:
        raise CoordinationError("invalid logical window acceptance schema")
    if (
        value["schema_version"] != 1
        or value["mode"] != "official_ros_header_csv_v1"
        or value["interval"] != "[start,stop)"
    ):
        raise CoordinationError("unsupported logical window acceptance")
    for key in (
        "within_one_frame",
        "logical_timestamp_deadline_stop",
        "physical_collector_deadline_stop",
        "raw_artifacts_modified",
    ):
        if not isinstance(value[key], bool):
            raise CoordinationError("invalid logical window acceptance boolean")
    budget = _required_uint_text(value, "one_frame_budget_ns")
    gap = _required_uint_text(value, "maximum_observed_boundary_gap_ns")
    uncertainty = _required_uint_text(value, "maximum_combined_uncertainty_ns")
    if (
        budget != ONE_FRAME_SYNC_BUDGET_NS
        or gap > budget
        or uncertainty > MAX_CLOCK_UNCERTAINTY_NS
        or value["within_one_frame"] is not True
        or value["logical_timestamp_deadline_stop"] is not True
        or value["physical_collector_deadline_stop"] is not False
        or value["raw_artifacts_modified"] is not False
    ):
        raise CoordinationError("logical window acceptance exceeds policy")
    return {
        **value,
        "one_frame_budget_ns": str(budget),
        "maximum_observed_boundary_gap_ns": str(gap),
        "maximum_combined_uncertainty_ns": str(uncertainty),
    }


def _decode_clock_sample(payload: dict) -> dict:
    if not isinstance(payload, dict) or payload.get("protocol_version") != PROTOCOL_VERSION:
        raise CoordinationError("unsupported clock sample protocol")
    sample = {
        "probe_id": _required_safe_text(payload, "probe_id"),
        "device_id": _required_uuid(payload, "device_id"),
        "local_midpoint_monotonic_ns": str(_required_uint_text(payload, "local_midpoint_monotonic_ns")),
        "coordinator_midpoint_monotonic_ns": str(
            _required_uint_text(payload, "coordinator_midpoint_monotonic_ns")
        ),
        "offset_ns": str(_required_int_text(payload, "offset_ns")),
        "rtt_ns": str(_required_uint_text(payload, "rtt_ns")),
        "uncertainty_ns": str(_required_uint_text(payload, "uncertainty_ns")),
        "sampled_at_local_monotonic_ns": str(
            _required_uint_text(payload, "sampled_at_local_monotonic_ns")
        ),
    }
    if int(sample["uncertainty_ns"]) > MAX_CLOCK_UNCERTAINTY_NS:
        raise CoordinationError("clock sample exceeds uncertainty budget")
    return sample


def _decode_frame_clock_anchor(payload: dict) -> dict:
    if not isinstance(payload, dict) or payload.get("protocol_version") != PROTOCOL_VERSION:
        raise CoordinationError("unsupported frame clock anchor protocol")
    arkit_timestamp = payload.get("arkit_timestamp_s")
    if (
        not isinstance(arkit_timestamp, (int, float))
        or isinstance(arkit_timestamp, bool)
        or not math.isfinite(arkit_timestamp)
        or arkit_timestamp < 0
    ):
        raise CoordinationError("invalid arkit_timestamp_s")
    anchor = {
        "probe_id": _required_safe_text(payload, "probe_id"),
        "device_id": _required_uuid(payload, "device_id"),
        "arkit_timestamp_s": float(arkit_timestamp),
        "frame_local_monotonic_ns": str(_required_uint_text(payload, "frame_local_monotonic_ns")),
        "callback_local_monotonic_ns": str(
            _required_uint_text(payload, "callback_local_monotonic_ns")
        ),
        "frame_callback_lag_ns": str(_required_uint_text(payload, "frame_callback_lag_ns")),
        "coordinator_frame_monotonic_ns": str(
            _required_uint_text(payload, "coordinator_frame_monotonic_ns")
        ),
        "uncertainty_ns": str(_required_uint_text(payload, "uncertainty_ns")),
        "clock_sample_age_ns": str(_required_uint_text(payload, "clock_sample_age_ns")),
    }
    frame_local = int(anchor["frame_local_monotonic_ns"])
    callback_local = int(anchor["callback_local_monotonic_ns"])
    lag = int(anchor["frame_callback_lag_ns"])
    if callback_local < frame_local or callback_local - frame_local != lag:
        raise CoordinationError("inconsistent frame clock basis")
    if lag > 1_000_000_000:
        raise CoordinationError("ARKit frame timestamp is not on the local uptime basis")
    if int(anchor["uncertainty_ns"]) > MAX_CLOCK_UNCERTAINTY_NS:
        raise CoordinationError("frame clock anchor exceeds uncertainty budget")
    if int(anchor["clock_sample_age_ns"]) > MAX_CLOCK_SAMPLE_AGE_NS:
        raise CoordinationError("frame clock anchor uses a stale sample")
    return anchor


def _decode_ego_preview_frame(payload: dict) -> dict:
    if not isinstance(payload, dict) or payload.get("protocol_version") != PROTOCOL_VERSION:
        raise CoordinationError("unsupported ego preview protocol")
    session_id = _required_uuid(payload, "session_id")
    device_id = _required_uuid(payload, "device_id")
    generation = payload.get("generation")
    if not isinstance(generation, int) or isinstance(generation, bool) or generation < 1:
        raise CoordinationError("invalid ego preview generation")
    if payload.get("capture_role") != "ego":
        raise CoordinationError("invalid ego preview role")
    sequence = _required_uint_text(payload, "sequence")
    sender_monotonic_ns = _required_uint_text(payload, "sender_monotonic_ns")
    if sequence < 1 or sender_monotonic_ns < 1:
        raise CoordinationError("invalid ego preview sequence or timestamp")
    arkit_timestamp = payload.get("arkit_timestamp_s")
    if (
        not isinstance(arkit_timestamp, (int, float))
        or isinstance(arkit_timestamp, bool)
        or not math.isfinite(arkit_timestamp)
        or arkit_timestamp < 0
    ):
        raise CoordinationError("invalid ego preview ARFrame timestamp")
    orientation = payload.get("orientation")
    if orientation not in EGO_PREVIEW_ORIENTATIONS:
        raise CoordinationError("invalid ego preview orientation")
    encoded = payload.get("jpeg_base64")
    maximum_encoded_size = ((MAX_EGO_PREVIEW_JPEG_BYTES + 2) // 3) * 4
    if not isinstance(encoded, str) or not encoded or len(encoded) > maximum_encoded_size:
        raise CoordinationError("ego preview JPEG payload is out of bounds")
    try:
        jpeg = base64.b64decode(encoded, validate=True)
    except (binascii.Error, ValueError) as error:
        raise CoordinationError("invalid ego preview JPEG base64") from error
    if (
        not jpeg
        or len(jpeg) > MAX_EGO_PREVIEW_JPEG_BYTES
        or not jpeg.startswith(b"\xff\xd8")
        or not jpeg.endswith(b"\xff\xd9")
    ):
        raise CoordinationError("invalid ego preview JPEG")
    return {
        "protocol_version": PROTOCOL_VERSION,
        "session_id": session_id,
        "generation": generation,
        "device_id": device_id,
        "capture_role": "ego",
        "sequence": str(sequence),
        "arkit_timestamp_s": float(arkit_timestamp),
        "sender_monotonic_ns": str(sender_monotonic_ns),
        "orientation": orientation,
        "jpeg_base64": encoded,
    }


def _artifact_references_are_complete(
    value: object, *, require_receiver_upload: bool = False
) -> bool:
    if not isinstance(value, list) or not value:
        return False
    names = set()
    for artifact in value:
        if not isinstance(artifact, dict):
            return False
        safe_name = artifact.get("name")
        sha256 = artifact.get("sha256")
        if (
            not isinstance(safe_name, str)
            or "/" in safe_name
            or "\\" in safe_name
            or safe_name in names
            or not isinstance(sha256, str)
            or len(sha256) != 64
        ):
            return False
        try:
            bytes.fromhex(sha256)
        except ValueError:
            return False
        names.add(safe_name)
    if require_receiver_upload and not any(
        isinstance(item, dict)
        and str(item.get("name", "")).lower().endswith(".zip")
        and item.get("receiver_upload_complete") is True
        and isinstance(item.get("upload_id"), str)
        and bool(item.get("upload_id"))
        for item in value
    ):
        return False
    return True


def _zip_upload_identity_from_ack(ack: object) -> Optional[dict]:
    if not isinstance(ack, dict):
        return None
    device_id = ack.get("device_id")
    artifacts = ack.get("artifacts")
    if not isinstance(device_id, str) or not isinstance(artifacts, list):
        return None
    zip_artifacts = [
        item
        for item in artifacts
        if isinstance(item, dict) and str(item.get("name", "")).lower().endswith(".zip")
    ]
    if len(zip_artifacts) != 1:
        return None
    artifact = zip_artifacts[0]
    name = artifact.get("name")
    size = artifact.get("size_bytes")
    sha256 = artifact.get("sha256")
    platform = artifact.get("platform", "iOS")
    if (
        not isinstance(name, str)
        or "/" in name
        or "\\" in name
        or not isinstance(size, int)
        or isinstance(size, bool)
        or size < 1
        or not isinstance(sha256, str)
        or len(sha256) != 64
        or platform != "iOS"
    ):
        return None
    try:
        bytes.fromhex(sha256)
    except ValueError:
        return None
    return {
        "filename": name,
        "device_id": device_id,
        "platform": platform,
        "size_bytes": size,
        "sha256": sha256.lower(),
    }


def _registration_payload(registration: DeviceRegistration) -> dict:
    return {
        "device_id": registration.device_id,
        "display_name": registration.display_name,
        "capture_role": registration.role,
        "profile_id": registration.profile_id,
        "controller_capable": registration.controller_capable,
        "gripper_id": registration.gripper_id,
        "client_identity": registration.client_identity,
    }


def _session_payload(session: GroupSession) -> dict:
    return {
        "session_id": session.session_id,
        "generation": session.generation,
        "controller_kind": session.controller_kind,
        "controller_device_id": session.controller_device_id,
        "shared_device_control": session.shared_device_control,
        "auto_rearm_after_capture": session.auto_rearm_after_capture,
        "auto_rearm_status": session.auto_rearm_status,
        "predecessor_session_id": session.predecessor_session_id,
        "successor_session_id": session.successor_session_id,
        "device_ids_by_role": dict(session.device_ids_by_role),
        "planned_transitions": list(session.planned_transitions),
        "acknowledgements": list(session.acknowledgements),
        "completion_state": session.completion_state,
        "upload_commit_authorized": session.upload_commit_authorized,
        "stop_commit_authorized": session.stop_commit_authorized,
        "partial_reasons": list(session.partial_reasons),
        "connection_interruptions": list(session.connection_interruptions),
        "membership_valid": session.membership_valid,
        "upload_grants_by_device": dict(session.upload_grants_by_device),
    }


def _valid_persisted_upload_grant(device_id: object, grant: object) -> bool:
    if not isinstance(device_id, str) or not isinstance(grant, dict):
        return False
    if grant.get("schema_version") != 1 or grant.get("device_id") != device_id:
        return False
    try:
        normalized_device = str(uuid.UUID(device_id)).lower()
        normalized_session = str(uuid.UUID(grant.get("session_id"))).lower()
    except (TypeError, ValueError, AttributeError):
        return False
    if normalized_device != device_id or normalized_session != grant.get("session_id"):
        return False
    if not isinstance(grant.get("generation"), int) or grant["generation"] < 1:
        return False
    if grant.get("capture_role") not in ROLES:
        return False
    authorized_at = grant.get("authorized_coordinator_monotonic_ns")
    if not isinstance(authorized_at, str) or not authorized_at.isdigit():
        return False
    file_identity = grant.get("file_identity")
    return (
        isinstance(file_identity, dict)
        and set(file_identity) == {"filename", "device_id", "platform", "size_bytes", "sha256"}
        and file_identity.get("device_id") == device_id
    )


def _required_safe_text(payload: dict, key: str) -> str:
    value = payload.get(key)
    if not isinstance(value, str) or _SAFE_ID.fullmatch(value) is None:
        raise CoordinationError(f"invalid {key}")
    return value


def _optional_safe_text(payload: dict, key: str) -> Optional[str]:
    value = payload.get(key)
    if value is None:
        return None
    if not isinstance(value, str) or _SAFE_ID.fullmatch(value) is None:
        raise CoordinationError(f"invalid {key}")
    return value


def _required_display_name(payload: dict) -> str:
    value = payload.get("display_name")
    if (
        not isinstance(value, str)
        or not value.strip()
        or len(value) > 128
        or any(ord(character) < 32 or ord(character) == 127 for character in value)
    ):
        raise CoordinationError("invalid display_name")
    return value.strip()


def _required_uuid(payload: dict, key: str) -> str:
    value = payload.get(key)
    if not isinstance(value, str):
        raise CoordinationError(f"invalid {key}")
    try:
        return str(uuid.UUID(value)).lower()
    except ValueError as error:
        raise CoordinationError(f"invalid {key}") from error


def _required_uint_text(payload: dict, key: str) -> int:
    value = payload.get(key)
    if not isinstance(value, str) or not value.isdigit():
        raise CoordinationError(f"invalid {key}")
    parsed = int(value)
    if parsed < 0 or parsed > 2**64 - 1:
        raise CoordinationError(f"invalid {key}")
    return parsed


def _required_int_text(payload: dict, key: str) -> int:
    value = payload.get(key)
    if not isinstance(value, str):
        raise CoordinationError(f"invalid {key}")
    try:
        parsed = int(value)
    except ValueError as error:
        raise CoordinationError(f"invalid {key}") from error
    if str(parsed) != value or parsed < -(2**63) or parsed > 2**63 - 1:
        raise CoordinationError(f"invalid {key}")
    return parsed


def _optional_uint_text_value(value: object, key: str) -> Optional[str]:
    if value is None:
        return None
    if not isinstance(value, str) or not value.isdigit():
        raise CoordinationError(f"invalid {key}")
    parsed = int(value)
    if parsed < 0 or parsed > 2**64 - 1:
        raise CoordinationError(f"invalid {key}")
    return str(parsed)
