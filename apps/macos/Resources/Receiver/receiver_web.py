#!/usr/bin/env python3
"""Small localhost/LAN HTTP surface for UMI Capture Receiver state and uploads."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Callable, Iterable, Tuple

from capture_upload import MAX_CAPTURE_CHUNK_BYTES, CaptureUploadError, CaptureUploadStore


MAX_CONTROL_BODY_BYTES = 64 * 1024


class RequestBodyError(ValueError):
    pass


class DashboardApplication:
    def __init__(
        self,
        dashboard_path: Path,
        state_provider: Callable[[], dict],
        group_handler: Callable[[str, dict], Tuple[int, dict]],
        capture_upload_root: Path,
        upload_authorizer: Callable[[dict], dict],
    ):
        self.dashboard = dashboard_path.read_bytes()
        self.state_provider = state_provider
        self.group_handler = group_handler
        self.upload_authorizer = upload_authorizer
        self.capture_upload_store = CaptureUploadStore(capture_upload_root)

    def __call__(self, environ: dict, start_response) -> Iterable[bytes]:
        method = environ.get("REQUEST_METHOD", "GET")
        path = environ.get("PATH_INFO", "/")
        if method == "GET" and path == "/":
            return self._response(start_response, "200 OK", "text/html; charset=utf-8", self.dashboard)
        if method == "GET" and path == "/health":
            return self._json_response(
                start_response,
                "200 OK",
                {"ok": True, "product": "UMI Capture Receiver", "protocol_version": 1},
            )
        if method == "GET" and path == "/api/state":
            state = dict(self.state_provider())
            state["capture_uploads"] = self.capture_upload_store.snapshot()
            return self._json_response(start_response, "200 OK", state)
        if method == "POST" and path.startswith("/api/group/"):
            command = path.removeprefix("/api/group/")
            try:
                payload = self._read_json_body(environ)
            except RequestBodyError as error:
                return self._json_error(start_response, str(error), "400 Bad Request")
            status_code, result = self.group_handler(command, payload)
            status = "202 Accepted" if status_code == 202 else "409 Conflict" if status_code == 409 else "400 Bad Request"
            return self._json_response(start_response, status, result)
        if method == "POST" and path == "/api/captures/upload/init":
            return self._upload_init(environ, start_response)
        if method == "PUT" and path.startswith("/api/captures/upload/"):
            upload_id = path.removeprefix("/api/captures/upload/")
            return self._upload_chunk(upload_id, environ, start_response)
        if method == "POST" and path.startswith("/api/captures/upload/") and path.endswith("/finish"):
            upload_id = path.removeprefix("/api/captures/upload/").removesuffix("/finish")
            return self._upload_finish(upload_id, environ, start_response)
        return self._response(start_response, "404 Not Found", "text/plain; charset=utf-8", b"Not found\n")

    def _upload_init(self, environ: dict, start_response):
        try:
            payload = self._read_json_body(environ)
            result = self.capture_upload_store.resume_authorized(payload)
            if result is None:
                file_identity = self.capture_upload_store.normalized_identity(payload)
                authorization_identity = {
                    key: file_identity[key]
                    for key in ("filename", "device_id", "platform", "size_bytes", "sha256")
                }
                payload["authorization_grant"] = self.upload_authorizer(authorization_identity)
                result = self.capture_upload_store.initialize(payload)
        except (RequestBodyError, CaptureUploadError) as error:
            return self._json_error(
                start_response,
                str(error),
                getattr(error, "status", "400 Bad Request"),
            )
        except PermissionError as error:
            return self._json_error(start_response, str(error), "403 Forbidden")
        return self._json_response(start_response, "200 OK", result)

    def _upload_chunk(self, upload_id: str, environ: dict, start_response):
        try:
            content_length = self._required_content_length(environ, MAX_CAPTURE_CHUNK_BYTES)
            try:
                offset = int(environ.get("HTTP_X_UPLOAD_OFFSET"))
            except (TypeError, ValueError) as error:
                raise CaptureUploadError("X-Upload-Offset must be an integer.") from error
            input_stream = environ.get("wsgi.input")
            if input_stream is None:
                raise CaptureUploadError("Missing request body stream.")
            result = self.capture_upload_store.append(upload_id, offset, content_length, input_stream)
        except (RequestBodyError, CaptureUploadError) as error:
            return self._json_error(
                start_response,
                str(error),
                getattr(error, "status", "400 Bad Request"),
            )
        return self._json_response(start_response, "200 OK", result)

    def _upload_finish(self, upload_id: str, environ: dict, start_response):
        try:
            self._required_content_length(environ, 0)
            result = self.capture_upload_store.finish(upload_id)
        except (RequestBodyError, CaptureUploadError) as error:
            return self._json_error(
                start_response,
                str(error),
                getattr(error, "status", "400 Bad Request"),
            )
        return self._json_response(start_response, "200 OK", result)

    @staticmethod
    def _required_content_length(environ: dict, maximum: int) -> int:
        value = environ.get("CONTENT_LENGTH")
        try:
            length = int(value)
        except (TypeError, ValueError) as error:
            raise RequestBodyError("Content-Length is required.") from error
        if length < 0 or length > maximum:
            raise RequestBodyError("Request body is outside the allowed range.")
        return length

    @classmethod
    def _read_json_body(cls, environ: dict) -> dict:
        length = cls._required_content_length(environ, MAX_CONTROL_BODY_BYTES)
        stream = environ.get("wsgi.input")
        if stream is None:
            raise RequestBodyError("Missing request body stream.")
        body = stream.read(length)
        if len(body) != length:
            raise RequestBodyError("Request body ended early.")
        if not body:
            return {}
        try:
            payload = json.loads(body.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as error:
            raise RequestBodyError("Request body must be a JSON object.") from error
        if not isinstance(payload, dict):
            raise RequestBodyError("Request body must be a JSON object.")
        return payload

    @classmethod
    def _json_error(cls, start_response, message: str, status: str):
        return cls._json_response(start_response, status, {"ok": False, "error": message})

    @classmethod
    def _json_response(cls, start_response, status: str, payload: dict):
        return cls._response(
            start_response,
            status,
            "application/json; charset=utf-8",
            (json.dumps(payload, indent=2, sort_keys=True) + "\n").encode("utf-8"),
        )

    @staticmethod
    def _response(start_response, status: str, content_type: str, body: bytes):
        start_response(
            status,
            [
                ("Content-Type", content_type),
                ("Content-Length", str(len(body))),
                ("Cache-Control", "no-store"),
                ("X-Content-Type-Options", "nosniff"),
            ],
        )
        return [body]
