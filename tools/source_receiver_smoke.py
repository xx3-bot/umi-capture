#!/usr/bin/env python3
"""Smoke-test the public source Receiver using a real subprocess."""

from __future__ import annotations

import json
import socket
import subprocess
import sys
import tempfile
import time
import unittest
import urllib.error
import urllib.request
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def _stop_process(process: subprocess.Popen) -> tuple[str, str]:
    if process.poll() is None:
        process.terminate()
    try:
        stdout, stderr = process.communicate(timeout=5.0)
    except subprocess.TimeoutExpired:
        process.kill()
        stdout, stderr = process.communicate()
    return (
        stdout.decode("utf-8", errors="replace"),
        stderr.decode("utf-8", errors="replace"),
    )


def _failure_message(summary: str, stdout: str, stderr: str) -> str:
    return f"{summary}\n--- Receiver stdout ---\n{stdout}\n--- Receiver stderr ---\n{stderr}"


def run_smoke(timeout_seconds: float = 10.0) -> dict:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as port_socket:
        port_socket.bind(("127.0.0.1", 0))
        port = port_socket.getsockname()[1]

    with tempfile.TemporaryDirectory(prefix="umi-capture-receiver-smoke-") as temporary:
        root = Path(temporary)
        command = [
            sys.executable,
            str(ROOT / "apps/macos/Resources/Receiver/receiver.py"),
            "--host", "127.0.0.1",
            "--port", str(port),
            "--recordings-dir", str(root / "recordings"),
            "--capture-upload-root", str(root / "uploads"),
        ]
        process = subprocess.Popen(
            command,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        deadline = time.monotonic() + timeout_seconds
        health_url = f"http://127.0.0.1:{port}/health"
        try:
            while time.monotonic() < deadline:
                return_code = process.poll()
                if return_code is not None:
                    stdout, stderr = _stop_process(process)
                    raise RuntimeError(
                        _failure_message(
                            f"Receiver exited with status {return_code} before reaching /health.",
                            stdout,
                            stderr,
                        )
                    )
                try:
                    with urllib.request.urlopen(health_url, timeout=0.25) as response:
                        result = json.load(response)
                    if isinstance(result, dict) and (
                        result.get("ok") is True
                        and result.get("product") == "UMI Capture Receiver"
                        and result.get("protocol_version") == 1
                    ):
                        return result
                except (OSError, urllib.error.URLError, json.JSONDecodeError):
                    pass
                time.sleep(0.05)
            stdout, stderr = _stop_process(process)
            raise RuntimeError(
                _failure_message(
                    f"Receiver did not reach a valid /health response within {timeout_seconds:.1f}s.",
                    stdout,
                    stderr,
                )
            )
        finally:
            if process.poll() is None:
                _stop_process(process)


class SourceReceiverSmokeTests(unittest.TestCase):
    def test_receiver_subprocess_reaches_health(self) -> None:
        result = run_smoke(timeout_seconds=10.0)
        self.assertEqual(result["product"], "UMI Capture Receiver")
        self.assertEqual(result["protocol_version"], 1)
        self.assertTrue(result["ok"])


if __name__ == "__main__":
    unittest.main()
