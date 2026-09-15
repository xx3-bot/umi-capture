# UMI Capture Receiver

UMI Capture Receiver is the public protocol-v1 Python Receiver for UMI Capture. It accepts VIO pose streams, coordinates paired captures, stores recordings, and accepts authorized capture uploads.

The private Swift GUI, processing workers, and hardware-specific calibration profiles are not included in this source release.

## Source setup and launch

Create an isolated environment, install the Receiver's direct dependencies, and prepare writable data directories:

```sh
python3 -m venv .venv
.venv/bin/python -m pip install -r apps/macos/requirements-receiver.txt
mkdir -p "$PWD/umi-library/recordings" "$PWD/umi-library/uploads"
.venv/bin/python apps/macos/Resources/Receiver/receiver.py \
  --host 127.0.0.1 \
  --port 5566 \
  --recordings-dir "$PWD/umi-library/recordings" \
  --capture-upload-root "$PWD/umi-library/uploads"
```

The dashboard and health endpoint are then available at `http://127.0.0.1:5566` and `http://127.0.0.1:5566/health`.

## Trusted LAN access

To accept clients from a trusted isolated LAN, bind explicitly to all interfaces and acknowledge the LAN boundary:

```sh
.venv/bin/python apps/macos/Resources/Receiver/receiver.py \
  --host 0.0.0.0 \
  --port 5566 \
  --recordings-dir "$PWD/umi-library/recordings" \
  --capture-upload-root "$PWD/umi-library/uploads" \
  --allow-lan
```

Do not use the trusted-LAN mode on an untrusted or Internet-facing network.

## Verification

After installing the Receiver dependencies into the active Python environment, run the real-subprocess source smoke test:

```sh
.venv/bin/python tools/source_receiver_smoke.py
```

The smoke test starts the exact source Receiver entrypoint on a temporary loopback port, waits for the protocol-v1 `/health` response, and shuts the process down.
