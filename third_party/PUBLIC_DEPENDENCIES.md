# Public source dependencies

The public repository is a source-only snapshot. Its dependency manifests pin
the following source dependencies, which users install when building the iOS
app or running the Python Receiver.

| Dependency | Version | Use | License | Upstream source and license |
| --- | --- | --- | --- | --- |
| Socket.IO-Client-Swift | 16.1.0 | iOS Socket.IO client | MIT | [source](https://github.com/socketio/socket.io-client-swift/tree/v16.1.0), [committed license](licenses/Socket.IO-Client-Swift-LICENSE) |
| Starscream | 4.0.8 | WebSocket transport resolved by CocoaPods | Apache-2.0 | [source](https://github.com/daltoniam/Starscream/tree/4.0.8), [committed license](licenses/Starscream-LICENSE) |
| python-socketio | 5.11.4 | Python Receiver Socket.IO server | MIT | [source](https://github.com/miguelgrinberg/python-socketio/tree/v5.11.4), [upstream license](https://github.com/miguelgrinberg/python-socketio/blob/v5.11.4/LICENSE) |
| eventlet | 0.37.0 | Python Receiver network server | MIT | [source](https://github.com/eventlet/eventlet/tree/0.37.0), [upstream license](https://github.com/eventlet/eventlet/blob/0.37.0/LICENSE) |

The source repository does not redistribute pip wheels, CocoaPods frameworks,
Apple Python, NumPy, OpenCV, FFmpeg, the private macOS GUI or workers, or any
private runtime payload. Dependencies obtained by users remain subject to their
own license terms.
