#!/usr/bin/env python3
"""Persistent UMI Capture protocol-v1 Receiver for VIO and paired capture control."""

from __future__ import annotations

import argparse
import base64
import binascii
import csv
import fcntl
import json
import math
import os
import re
import struct
import tempfile
import threading
import time
import uuid
from collections import deque
from contextlib import contextmanager
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Deque, Dict, List, Optional, Sequence, Tuple
from urllib.parse import urlsplit

# Eventlet 0.40's kqueue hub is incompatible with the bundled Xcode Python
# build on macOS 14. The poll hub preserves the same wire protocol while
# avoiding a startup-time kevent type failure. A maintainer can still provide
# an explicit EVENTLET_HUB override before launch.
os.environ.setdefault("EVENTLET_HUB", "poll")

import eventlet
import eventlet.wsgi
import socketio

from dual_capture import (
    CoordinationError,
    DualCaptureCoordinator,
    EVENT_CLOCK_REFRESH_REQUEST,
    EVENT_CLOCK_SAMPLE,
    EVENT_FRAME_CLOCK_ANCHOR,
    EVENT_GROUP_ACK,
    EVENT_GROUP_COMMAND,
    EVENT_GROUP_REQUEST,
    EVENT_GROUP_STATE,
    EVENT_EGO_PREVIEW_FRAME,
    EVENT_REGISTER,
    EVENT_REGISTER_ACK,
    EVENT_TIME_PROBE,
    EVENT_TIME_REPLY,
)
from receiver_web import DashboardApplication


POSE_PACKET_SIZE = 72
GROUP_REQUEST_ID_PATTERN = re.compile(r"^[A-Za-z0-9._-]{1,128}$")
CSV_COLUMNS = [
    "receive_time_utc",
    "receive_time_unix_ns",
    "device_timestamp_s",
    "x_m",
    "y_m",
    "z_m",
] + [f"m{row}{column}" for row in range(4) for column in range(4)]


def is_same_host_socket_origin(origin: str, environ: dict) -> bool:
    if not isinstance(origin, str) or not origin:
        return False
    host = environ.get("HTTP_HOST")
    if not isinstance(host, str) or not host:
        return False
    try:
        parsed = urlsplit(origin)
    except ValueError:
        return False
    return (
        parsed.scheme.lower() in {"http", "https", "ws", "wss"}
        and parsed.username is None
        and parsed.password is None
        and parsed.path in {"", "/"}
        and not parsed.query
        and not parsed.fragment
        and parsed.netloc.casefold() == host.casefold()
    )


@dataclass(frozen=True)
class PosePacket:
    matrix: Tuple[Tuple[float, float, float, float], ...]
    timestamp: float

    @property
    def position(self) -> Tuple[float, float, float]:
        return self.matrix[0][3], self.matrix[1][3], self.matrix[2][3]


def decode_pose(encoded_data: str) -> PosePacket:
    if not isinstance(encoded_data, str) or not encoded_data:
        raise ValueError("pose payload is not valid base64")
    try:
        raw = base64.b64decode(encoded_data, validate=True)
    except (binascii.Error, ValueError) as error:
        raise ValueError("pose payload is not valid base64") from error
    if len(raw) != POSE_PACKET_SIZE:
        raise ValueError(f"pose payload must be {POSE_PACKET_SIZE} bytes, got {len(raw)}")
    column_major = struct.unpack("<16f", raw[:64])
    if not all(math.isfinite(value) for value in column_major):
        raise ValueError("pose matrix contains a non-finite Float32")
    matrix = tuple(
        tuple(column_major[column * 4 + row] for column in range(4))
        for row in range(4)
    )
    timestamp = struct.unpack("<d", raw[64:])[0]
    if not math.isfinite(timestamp):
        raise ValueError("pose timestamp is not a finite Double")
    return PosePacket(matrix=matrix, timestamp=timestamp)


@dataclass
class ClientState:
    sid: str
    ip_address: str
    connected_at: str
    session_dir: Path
    csv_path: Path
    csv_file: object
    csv_writer: csv.writer
    sample_count: int = 0
    last_receive_monotonic: Optional[float] = None
    sample_intervals: Deque[float] = field(default_factory=lambda: deque(maxlen=120))
    trajectory: Deque[Tuple[float, float, float]] = field(
        default_factory=lambda: deque(maxlen=20_000)
    )
    capture_status: Optional[dict] = None

    @property
    def fps(self) -> float:
        if not self.sample_intervals:
            return 0.0
        mean = sum(self.sample_intervals) / len(self.sample_intervals)
        return 1.0 / mean if mean > 0 else 0.0


class PoseRecorder:
    def __init__(self, recordings_dir: Path):
        self.recordings_dir = recordings_dir.expanduser().resolve()
        self.recordings_dir.mkdir(parents=True, exist_ok=True)
        self._lock = threading.RLock()
        self._clients: Dict[str, ClientState] = {}
        self._decode_error_count = 0

    def connect(self, sid: str, environ: dict) -> None:
        with self._lock:
            self._close_client_locked(sid)
            stamp = datetime.now().strftime("%Y%m%d_%H%M%S_%f")[:-3]
            session_dir = self.recordings_dir / f"{stamp}_{sid[:8]}"
            session_dir.mkdir(parents=True, exist_ok=False)
            csv_path = session_dir / "poses.csv"
            handle = csv_path.open("w", newline="", encoding="utf-8")
            writer = csv.writer(handle)
            writer.writerow(CSV_COLUMNS)
            self._clients[sid] = ClientState(
                sid=sid,
                ip_address=str(environ.get("REMOTE_ADDR", "unknown")),
                connected_at=_utc_now(),
                session_dir=session_dir,
                csv_path=csv_path,
                csv_file=handle,
                csv_writer=writer,
            )
            self._write_metadata_locked(self._clients[sid])

    def disconnect(self, sid: str) -> None:
        with self._lock:
            self._close_client_locked(sid)

    def connected_sids(self) -> List[str]:
        with self._lock:
            return list(self._clients)

    def record(self, sid: str, encoded_data: str) -> None:
        try:
            packet = decode_pose(encoded_data)
        except ValueError:
            with self._lock:
                self._decode_error_count += 1
            return
        now_monotonic = time.monotonic()
        now_unix_ns = time.time_ns()
        with self._lock:
            state = self._clients.get(sid)
            if state is None:
                return
            if state.last_receive_monotonic is not None:
                interval = now_monotonic - state.last_receive_monotonic
                if interval > 0:
                    state.sample_intervals.append(interval)
            state.last_receive_monotonic = now_monotonic
            state.sample_count += 1
            state.trajectory.append(packet.position)
            flattened = [packet.matrix[row][column] for row in range(4) for column in range(4)]
            state.csv_writer.writerow(
                [_utc_now(), str(now_unix_ns), f"{packet.timestamp:.9f}"]
                + [f"{value:.9f}" for value in packet.position]
                + [f"{value:.9f}" for value in flattened]
            )
            if state.sample_count % 120 == 0:
                state.csv_file.flush()

    def record_capture_status(self, sid: str, data: dict) -> None:
        with self._lock:
            state = self._clients.get(sid)
            if state is not None:
                state.capture_status = dict(data)
                self._write_metadata_locked(state)

    def reset_recording(self, sid: str) -> None:
        with self._lock:
            state = self._clients.get(sid)
            if state is None:
                return
            environ = {"REMOTE_ADDR": state.ip_address}
            self._close_client_locked(sid)
            self.connect(sid, environ)

    def end_recording(self, sid: str) -> None:
        with self._lock:
            state = self._clients.get(sid)
            if state is not None:
                state.csv_file.flush()
                self._write_metadata_locked(state)

    def snapshot(self) -> dict:
        with self._lock:
            clients = []
            for state in self._clients.values():
                points = list(state.trajectory)
                stride = max(1, len(points) // 800)
                clients.append(
                    {
                        "sid": state.sid,
                        "ip_address": state.ip_address,
                        "connected_at": state.connected_at,
                        "sample_count": state.sample_count,
                        "fps": state.fps,
                        "capture_status": state.capture_status,
                        "trajectory": points[::stride],
                    }
                )
            return {
                "product": "UMI Capture Receiver",
                "connected_client_count": len(clients),
                "clients": clients,
                "decode_error_count": self._decode_error_count,
            }

    def close(self) -> None:
        with self._lock:
            for sid in list(self._clients):
                self._close_client_locked(sid)

    def _close_client_locked(self, sid: str) -> None:
        state = self._clients.pop(sid, None)
        if state is None:
            return
        self._write_metadata_locked(state)
        try:
            state.csv_file.flush()
            os.fsync(state.csv_file.fileno())
        except OSError:
            pass
        state.csv_file.close()

    @staticmethod
    def _write_metadata_locked(state: ClientState) -> None:
        path = state.session_dir / "metadata.json"
        temporary = state.session_dir / ".metadata.writing"
        temporary.write_text(
            json.dumps(
                {
                    "schema_version": 1,
                    "product": "UMI Capture Receiver",
                    "connected_at": state.connected_at,
                    "sample_count": state.sample_count,
                    "capture_status": state.capture_status,
                    "coordinate_frame": "device_local_arkit",
                },
                indent=2,
                sort_keys=True,
            )
            + "\n",
            encoding="utf-8",
        )
        os.replace(temporary, path)


def create_application(recordings_dir: Path, capture_upload_root: Path):
    recorder = PoseRecorder(recordings_dir)
    coordinator = DualCaptureCoordinator(recordings_dir)
    server = socketio.Server(
        async_mode="eventlet",
        cors_allowed_origins=is_same_host_socket_origin,
        max_http_buffer_size=12_000_000,
    )
    authenticated_sids: set[str] = set()
    processed_request_ids: dict[str, None] = {}
    clock_transition_lock = threading.Lock()
    pending_clock_transition: Optional[str] = None

    def state_snapshot() -> dict:
        snapshot = recorder.snapshot()
        snapshot["dual_capture"] = coordinator.snapshot()
        return snapshot

    def emit_transmissions(transmissions) -> None:
        for target_sid, payload in transmissions:
            server.emit(EVENT_GROUP_COMMAND, payload, to=target_sid)

    def broadcast_group_state(error: Optional[str] = None) -> None:
        payload = coordinator.snapshot()
        if error:
            payload["error"] = error
        for target_sid in tuple(authenticated_sids):
            server.emit(EVENT_GROUP_STATE, payload, to=target_sid)

    def request_fresh_clocks() -> None:
        for target_sid in tuple(authenticated_sids):
            server.emit(EVENT_CLOCK_REFRESH_REQUEST, {"protocol_version": 1}, to=target_sid)

    def is_clock_error(error: CoordinationError) -> bool:
        message = str(error)
        return message.startswith("clock mapping ") or message.startswith("clock uncertainty ")

    def queue_after_clock_refresh(command: str, issue, emergency=None) -> bool:
        nonlocal pending_clock_transition
        with clock_transition_lock:
            if pending_clock_transition is not None:
                request_fresh_clocks()
                return False
            token = uuid.uuid4().hex
            pending_clock_transition = token
        request_fresh_clocks()
        broadcast_group_state(f"Synchronizing both device clocks before {command.capitalize()}")

        def retry() -> None:
            nonlocal pending_clock_transition
            deadline = time.monotonic() + 5.0
            try:
                while time.monotonic() < deadline:
                    server.sleep(0.1)
                    try:
                        transmissions = issue()
                    except CoordinationError as error:
                        if is_clock_error(error):
                            request_fresh_clocks()
                            continue
                        broadcast_group_state(str(error))
                        return
                    emit_transmissions(transmissions)
                    broadcast_group_state()
                    return
                if command == "stop" and emergency is not None:
                    try:
                        emit_transmissions(emergency())
                    except CoordinationError as error:
                        broadcast_group_state(str(error))
                        return
                    broadcast_group_state(
                        "Stop clock synchronization timed out; emergency Stop was issued and this capture is partial"
                    )
                else:
                    broadcast_group_state("Start cancelled: device clock synchronization timed out")
            finally:
                with clock_transition_lock:
                    if pending_clock_transition == token:
                        pending_clock_transition = None

        server.start_background_task(retry)
        return True

    def issue_group_command(command: str, request_payload: dict):
        try:
            if command == "create":
                session = coordinator.begin_session(controller_kind="mac")
                return 202, {"ok": True, "session_id": session.session_id, "generation": session.generation}
            if command not in {"prepare", "start", "stop"}:
                return 400, {"ok": False, "error": f"Unsupported command: {command}"}
            if command == "prepare" and (
                coordinator.active_session is None
                or coordinator.active_session.completion_state in {"completed", "partial"}
            ):
                coordinator.begin_session(controller_kind="mac")
            try:
                transmissions = coordinator.issue_mac_request(command)
            except CoordinationError as error:
                if command in {"start", "stop"} and is_clock_error(error):
                    queue_after_clock_refresh(
                        command,
                        lambda: coordinator.issue_mac_request(command),
                        (
                            lambda: coordinator.issue_emergency_stop()
                            if command == "stop"
                            else None
                        ),
                    )
                    return 202, {"ok": True, "command": command, "queued_for_clock_sync": True}
                raise
            emit_transmissions(transmissions)
            broadcast_group_state()
            return 202, {"ok": True, "command": command}
        except CoordinationError as error:
            return 409, {"ok": False, "error": str(error)}

    def authorize_capture_upload(payload: dict) -> dict:
        try:
            return coordinator.authorize_upload_initialize(payload)
        except CoordinationError as error:
            raise PermissionError(str(error)) from error

    dashboard_application = DashboardApplication(
        Path(__file__).with_name("dashboard.html"),
        state_snapshot,
        issue_group_command,
        capture_upload_root,
        authorize_capture_upload,
    )

    @server.event
    def connect(sid, environ, auth=None):
        authenticated_sids.add(sid)
        recorder.connect(sid, environ)

    @server.event
    def disconnect(sid):
        authenticated_sids.discard(sid)
        coordinator.disconnect(sid)
        recorder.disconnect(sid)
        broadcast_group_state()

    @server.on(EVENT_REGISTER)
    def handle_register(sid, data):
        if sid not in authenticated_sids or not isinstance(data, dict):
            return
        try:
            response = coordinator.register(sid, data)
        except CoordinationError as error:
            response = {"protocol_version": 1, "accepted": False, "error": str(error)}
        server.emit(EVENT_REGISTER_ACK, response, to=sid)
        broadcast_group_state()

    @server.on(EVENT_TIME_PROBE)
    def handle_time_probe(sid, data):
        if sid not in authenticated_sids or not isinstance(data, dict):
            return
        try:
            response = coordinator.make_time_reply(sid, data)
        except CoordinationError:
            return
        server.emit(EVENT_TIME_REPLY, response, to=sid)

    @server.on(EVENT_CLOCK_SAMPLE)
    def handle_clock_sample(sid, data):
        if sid not in authenticated_sids or not isinstance(data, dict):
            return
        try:
            coordinator.record_clock_sample(sid, data)
        except CoordinationError:
            return

    @server.on(EVENT_FRAME_CLOCK_ANCHOR)
    def handle_frame_clock_anchor(sid, data):
        if sid not in authenticated_sids or not isinstance(data, dict):
            return
        try:
            coordinator.record_frame_clock_anchor(sid, data)
        except CoordinationError:
            return

    @server.on(EVENT_EGO_PREVIEW_FRAME)
    def handle_ego_preview_frame(sid, data):
        if sid not in authenticated_sids or not isinstance(data, dict):
            return
        try:
            target_sid, payload = coordinator.route_ego_preview_frame(sid, data)
        except CoordinationError:
            return
        server.emit(EVENT_EGO_PREVIEW_FRAME, payload, to=target_sid)

    @server.on(EVENT_GROUP_ACK)
    def handle_group_ack(sid, data):
        if sid not in authenticated_sids or not isinstance(data, dict):
            return
        try:
            emit_transmissions(coordinator.record_ack(sid, data))
        except CoordinationError as error:
            broadcast_group_state(str(error))
            return
        broadcast_group_state()

    @server.on(EVENT_GROUP_REQUEST)
    def handle_group_request(sid, data):
        if sid not in authenticated_sids or not isinstance(data, dict):
            return
        command = data.get("command")
        recover = data.get("recover_previous_session", False)
        auto_rearm = data.get("auto_rearm_after_capture", False)
        request_id = data.get("request_id")
        try:
            if request_id is not None and (
                not isinstance(request_id, str) or GROUP_REQUEST_ID_PATTERN.fullmatch(request_id) is None
            ):
                raise CoordinationError("invalid group request id")
            if request_id is not None and request_id in processed_request_ids:
                broadcast_group_state()
                return
            if not isinstance(recover, bool):
                raise CoordinationError("invalid recovery request")
            if not isinstance(auto_rearm, bool):
                raise CoordinationError("invalid automatic rearm policy")
            if command != "prepare" and auto_rearm:
                raise CoordinationError(
                    "automatic rearm policy is only valid for prepare"
                )
            if command == "reset":
                if recover:
                    raise CoordinationError("reset cannot request automatic recovery")
                coordinator.reset_device_session(sid)
            elif recover:
                if command != "prepare":
                    raise CoordinationError("recovery is only valid for prepare")
                emit_transmissions(coordinator.recover_device_session(
                    sid,
                    auto_rearm_after_capture=auto_rearm,
                ))
            else:
                emit_transmissions(coordinator.issue_device_request(
                    sid,
                    command,
                    auto_rearm_after_capture=auto_rearm,
                ))
            if request_id is not None:
                processed_request_ids[request_id] = None
                if len(processed_request_ids) > 2048:
                    processed_request_ids.pop(next(iter(processed_request_ids)))
            broadcast_group_state()
        except CoordinationError as error:
            if command in {"start", "stop"} and is_clock_error(error):
                queue_after_clock_refresh(
                    command,
                    lambda: coordinator.issue_device_request(sid, command),
                    (
                        lambda: coordinator.issue_device_emergency_stop(sid)
                        if command == "stop"
                        else None
                    ),
                )
                return
            broadcast_group_state(str(error))

    def retry_commands():
        while True:
            server.sleep(0.25)
            emit_transmissions(coordinator.due_retries())

    server.start_background_task(retry_commands)

    @server.on("update")
    def handle_update(sid, data):
        recorder.record(sid, data)

    @server.on("capture_control")
    def handle_capture_control(sid, data):
        if not isinstance(data, dict):
            return
        command = data.get("command")
        if command in {"reset", "new_recording"}:
            recorder.reset_recording(sid)
        elif command == "end_recording":
            recorder.end_recording(sid)

    @server.on("capture_status")
    def handle_capture_status(sid, data):
        if isinstance(data, dict):
            recorder.record_capture_status(sid, data)

    return socketio.WSGIApp(server, dashboard_application), recorder


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run the UMI Capture protocol-v1 Receiver.")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=5566)
    parser.add_argument("--parent-pid", type=int)
    parser.add_argument("--recordings-dir", type=Path, required=True)
    parser.add_argument("--capture-upload-root", type=Path, required=True)
    parser.add_argument("--allow-lan", action="store_true")
    return parser.parse_args()


def receiver_parent_is_alive(expected_parent_pid: int, current_parent_pid: Optional[int] = None) -> bool:
    if expected_parent_pid <= 1:
        return False
    actual = os.getppid() if current_parent_pid is None else current_parent_pid
    return actual == expected_parent_pid


def start_parent_watchdog(expected_parent_pid: int) -> None:
    if not receiver_parent_is_alive(expected_parent_pid):
        raise SystemExit(f"Receiver parent process {expected_parent_pid} is no longer active.")

    def watch() -> None:
        while receiver_parent_is_alive(expected_parent_pid):
            time.sleep(0.25)
        os._exit(0)

    threading.Thread(target=watch, name="receiver-parent-watchdog", daemon=True).start()


@contextmanager
def exclusive_receiver_port(port: int):
    lock_path = Path(tempfile.gettempdir()) / f"umi_capture-receiver-{port}.lock"
    lock_file = lock_path.open("a+")
    try:
        try:
            fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise SystemExit(f"A UMI Capture Receiver already owns port {port}.") from error
        yield
    finally:
        try:
            fcntl.flock(lock_file.fileno(), fcntl.LOCK_UN)
        finally:
            lock_file.close()


def _utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def main() -> None:
    args = parse_args()
    if not 1 <= args.port <= 65535:
        raise SystemExit("Port must be between 1 and 65535.")
    if args.parent_pid is not None:
        start_parent_watchdog(args.parent_pid)
    is_loopback = args.host in {"127.0.0.1", "::1", "localhost"}
    if not is_loopback and not args.allow_lan:
        raise SystemExit("Non-loopback binding requires --allow-lan.")
    with exclusive_receiver_port(args.port):
        application, recorder = create_application(args.recordings_dir, args.capture_upload_root)
        try:
            listener = eventlet.listen((args.host, args.port), reuse_port=False)
            print(f"UMI Capture Receiver listening on {args.host}:{args.port}", flush=True)
            print(f"Dashboard: http://127.0.0.1:{args.port}", flush=True)
            print(f"Recordings: {recorder.recordings_dir}", flush=True)
            print(f"Capture inbox: {args.capture_upload_root.expanduser()}", flush=True)
            eventlet.wsgi.server(listener, application, log_output=False)
        finally:
            recorder.close()


if __name__ == "__main__":
    main()
