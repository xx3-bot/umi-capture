# Capture package

A UMI Capture capture package is a finalized ZIP with a schema-versioned manifest,
artifact declarations, per-artifact size and SHA-256, capture profile, device
role, session/generation evidence when coordinated, and software provenance.

New `recording_info.json` files use schema 6 for the normalized video-orientation
contract. `fixed_interface_orientation` freezes the capture-time interface;
`umi_preprocessing.rotation_degrees` is the physical clockwise transform applied
to the 224x224 stream; `umi_pixels_physically_upright` must be `true`; and
`raw_video_display_rotation_degrees` declares the raw track's display transform.
The three values must agree with `landscape_right=0`, `portrait=90`, and
`landscape_left=180`; producers and downstream validators applying this contract
must reject inconsistent recording metadata.

`gripper_marker_layout=fastumi_aruco_mount` is emitted only for a Hand capture
whose bundled FastUMI gripper and physical TCP profile both validate. Ego and
unvalidated/custom Hand profiles omit the field. A processor that requires
marker geometry rejects any other non-empty layout.

The public source Python Receiver validates upload authorization, a plain ZIP
filename, declared whole-file size, and whole-file SHA-256 before saving the ZIP
bytes. It does not inspect ZIP contents or validate internal orientation,
schemas, duplicate names, symlinks, artifact hashes, or coordinate semantics.

Downstream importers must reject duplicate ZIP names, symlinks, unsafe paths,
undeclared training artifacts, hash or size mismatches, non-final packages, and capture
profiles that do not match the selected physical-TCP configuration. Raw camera
poses remain device-local. Processing outputs may be labelled training-valid
only after all required hardware, calibration, and coordinate checks pass.
No reference-board or cross-device shared-origin artifact is part of this
package contract; Hand and Ego only share a gravity-up/initial-camera-forward
direction convention.

The historical manifest kind `iphonevio_capture_export` and some `iphonevio_*_v1`
wire identifiers are retained for protocol-v1 compatibility. New packages
identify the client as UMI Capture through software-provenance metadata.

This public source release includes no historical-package importer. A committed
historical ZIP remains opaque stored data unless a separately supplied and
independently reviewed downstream tool validates it.
