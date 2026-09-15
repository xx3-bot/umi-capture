# Third-party software

This directory documents dependencies required to build and run the public
source snapshot. In the public snapshot, `inventory.json` lists the exact
dependencies installed by users from `apps/ios/Podfile.lock` and
`apps/macos/requirements-receiver.txt`. See `PUBLIC_DEPENDENCIES.md` for their
roles and upstream sources.

The license texts for Socket.IO-Client-Swift and Starscream are committed under
`licenses/`. The Python Receiver dependencies are installed by users from PyPI
and are not redistributed by this source repository. The repository also does
not redistribute CocoaPods frameworks, Apple Python, NumPy, OpenCV, FFmpeg, the
private macOS GUI or workers, or any private runtime payload.
