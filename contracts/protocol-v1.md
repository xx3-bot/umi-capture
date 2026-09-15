# Coordination protocol v1

UMI Capture coordinates one `wrist_umi` phone and one `ego` phone on a trusted LAN.
Both devices may request preparation, start, or stop; the Receiver is the
authority for session identity, generation, deadlines, group state, and upload
authorization.

The iOS client can browse for compatible `_umicapture._tcp` advertisements, but
the public source Python Receiver does not advertise a Bonjour service. Users
must enter its host and port manually. Live compatibility with an earlier
DeepUMI Receiver is not part of this contract.

## Timing and lifecycle

- Time probes estimate device-to-Receiver monotonic-clock offset and uncertainty.
- Prepare, start, and stop commands carry a session ID, generation, target time,
  and deadline policy. Frames are admitted at or after start and before stop.
- Delayed messages from stale generations fail closed.
- Loss of a peer never discards local capture data; emergency stop remains
  available while a local capture exists.

## Live pose packet

The `update` Socket.IO event carries a base64 string containing exactly 72 bytes:
16 native-endian IEEE-754 `Float32` values in simd column order, followed by one
native-endian IEEE-754 `Float64` ARKit monotonic timestamp. This is protocol v1
and must not be changed without a new protocol version.

## Upload commit

Finalized ZIPs remain local until the Receiver group state has
`upload_commit_authorized=true` for the same session and generation. Upload is
resumable through `POST /api/captures/upload/init`, offset-bearing `PUT` chunks,
and `POST /api/captures/upload/{upload_id}/finish`. The Receiver commits only
after expected byte count and SHA-256 match. A 4xx authorization or integrity
failure is terminal; transport interruption is retryable.

The upload commit path validates only transport: authorization, declared
whole-file size, and whole-file SHA-256. The public source Receiver does not
inspect ZIP contents or validate internal orientation, malformed or duplicate entries,
symlinks, artifact declarations, or coordinate semantics. Committed ZIPs remain
opaque until a downstream validator, which is not included here, accepts them.

## Preview limits

Ego preview is session-bound, generation-bound, role-bound, sequence-monotonic,
and lifecycle-bound. It is limited to 2.5 FPS, a 320-pixel long edge, 160 KiB
JPEG, one frame in flight, and a 1.5-second stale interval. The Ego phone sends
`umi_capture_ego_preview_frame_v1`; the Receiver validates it and relays it only
to the active Hand phone. Preview bytes are never persisted in session state.
