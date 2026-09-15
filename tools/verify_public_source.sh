#!/usr/bin/env bash
# Run from the root of a public source Git checkout with dependencies installed.
set -euo pipefail

PYTHON_BIN="${PYTHON:-python3}"
export PYTHONDONTWRITEBYTECODE=1

"$PYTHON_BIN" -m unittest \
  tools/test_ios_product_boundary.py \
  tools/test_public_docs.py \
  tools/test_public_license_inventory.py \
  tools/test_public_release_gate.py \
  tools/test_public_ci.py -v
env PYTHONPATH=apps/macos/Resources/Receiver \
  "$PYTHON_BIN" -m unittest \
  apps/macos/Tests/test_capture_upload.py \
  apps/macos/Tests/test_dual_capture.py \
  apps/macos/Tests/test_receiver_web.py -v
"$PYTHON_BIN" tools/source_receiver_smoke.py
"$PYTHON_BIN" tools/public_release_gate.py --root .
git diff --check
