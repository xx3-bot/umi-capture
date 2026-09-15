# Compatibility

The current supported pair is the UMI Capture iOS client and UMI Capture Receiver
in this repository. The iOS client can browse for compatible
`_umicapture._tcp` advertisements, but the public source Python Receiver does
not advertise a Bonjour service. Enter its host and port manually. Protocol v1
retains only the established Socket.IO event names, HTTP fields, and manifest
kind whose semantics did not change; these constants do not provide live
compatibility with an earlier application's Receiver.

This public source release includes no historical-package importer. Historical
DeepUMI and earlier VIO-only ZIP envelopes are not upgraded or interpreted as
training truth. LiDAR, depth,
mesh, material, spatial scan, shared-world, fabricated cross-device alignment,
joint trajectory, and Pause/Resume workflows are unsupported.
