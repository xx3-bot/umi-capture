# Known limitations

UMI Capture v0.1.0-experimental is a source-only experimental release. Supported
verification covers an iOS Simulator build and the source Python Receiver on
macOS. Ubuntu Receiver execution is not part of the supported first-release path
and remains unverified.

| Area | Current limitation |
| --- | --- |
| Real-device acceptance | Physical-device end-to-end acceptance is still in progress. Camera availability, ARKit behavior, timing, paired capture, and uploads on named hardware are not accepted by Simulator or synthetic tests. |
| Binary distribution | No supported IPA, DMG, prebuilt app, or sideload package is available. Physical iPhone installation requires your own signing configuration. |
| Private Mac GUI and processing | The Swift GUI, processing workers, bundled runtime, and private processing profiles are excluded and unavailable in this release. The browser dashboard belongs to the source Python Receiver. |
| Windows and Ubuntu | No native Windows or Ubuntu application package is available. Windows source execution is not an accepted path. The Receiver implementation retains portable paths, but Ubuntu source execution is deferred until platform testing is complete. |
| Benchmarks | Reproducible performance, accuracy, synchronization, and downstream robot-learning benchmarks are unavailable. |
| Translated documentation | Maintained translated public documentation and full illustrated manuals are unavailable. The five English interface screenshots are reference images. |
| Notarization | No notarized macOS application or notarization workflow is provided. |
| Camera calibration | Numeric camera profiles are experimental approximations, with zero-initialized distortion coefficients. Runtime ARKit intrinsics remain available; neither replaces validated physical lens calibration. |
| Coordinate alignment | Hand and Ego share session time, not one ARKit spatial frame. No cross-device pose or shared origin is inferred. |
| Network deployment | The Receiver is intended for loopback or an explicitly enabled trusted isolated LAN, not Internet-facing or untrusted-network deployment. |

The retained project-owned physical TCP profile describes its matching mount;
it does not establish calibration for an arbitrary assembly. Raw capture
packages must not be called robot-ready or training-valid solely because they
upload successfully. See [coordinate frames](coordinate-frames.md).
