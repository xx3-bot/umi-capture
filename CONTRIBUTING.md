# Contributing

UMI Capture is an experimental public project. Keep changes small, source-backed, and
covered by the nearest contract test. Do not commit captures, participant media,
credentials, Apple signing material, private robot assets, build products, or
large runtime payloads.

For coordinate or synchronization changes, update the relevant document under
`contracts/` and add a machine-checkable fixture before changing behavior. Never
weaken fail-closed upload authorization, generation checks, package integrity,
proper-SO(3) validation, or hardware-profile binding to make an input pass.

Run `PYTHON="$PWD/.venv/bin/python" tools/verify_public_source.sh` after installing
the source Receiver dependencies and before requesting review. Physical-device
claims need named hardware evidence and must not be inferred from a simulator.
