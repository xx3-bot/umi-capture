import Foundation
import simd
import XCTest
@testable import UMICapture

final class PosePacketV1Tests: XCTestCase {
    func testNontrivialPacketMatchesExactV1Golden() {
        let transform = simd_float4x4(
            SIMD4<Float>(0, 1, 0, 0),
            SIMD4<Float>(-1, 0, 0, 0),
            SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(1.25, -2.5, 3.75, 1)
        )
        let packet = PosePacketV1(
            transformMatrix: transform,
            timestamp: 42.125
        )
        let bytes = packet.toBytes()

        XCTAssertEqual(bytes.count, PosePacketV1.byteCount)
        XCTAssertEqual(bytes.count, 72)
        XCTAssertEqual(
            bytes.map { String(format: "%02x", $0) }.joined(),
            "000000000000803f0000000000000000"
                + "000080bf000000000000000000000000"
                + "00000000000000000000803f00000000"
                + "0000a03f000020c0000070400000803f"
                + "0000000000104540"
        )
    }

    func testSocketHotPathKeepsProtocolAndRemovesBlockingNoise()
        throws {
        let repositoryURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let socketSource = try String(
            contentsOf: repositoryURL.appendingPathComponent(
                "UMICapture/SocketClient.swift"
            ),
            encoding: .utf8
        )
        let packetSource = try String(
            contentsOf: repositoryURL.appendingPathComponent(
                "UMICapture/PosePacketV1.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(
            socketSource.contains(
                "self.socket?.emit(\"update\", "
                    + "data.toBytes().base64EncodedString())"
            )
        )
        XCTAssertFalse(socketSource.contains("usleep("))
        XCTAssertFalse(socketSource.contains(".log(true)"))
        XCTAssertTrue(socketSource.contains(".log(false)"))
        XCTAssertFalse(socketSource.contains("URL(string:")
            && socketSource.contains(")!"))
        XCTAssertFalse(socketSource.contains("Not ready to send"))
        XCTAssertFalse(socketSource.contains("Start sending package"))

        for forbiddenImport in [
            "import SocketIO",
            "import ARKit",
            "import AVFoundation",
            "import SwiftUI"
        ] {
            XCTAssertFalse(packetSource.contains(forbiddenImport))
        }
    }

    func testFastUMIUploadContractKeepsLegacyHeaderAndEndpoints()
        throws {
        let repositoryURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let uploader = try String(
            contentsOf: repositoryURL.appendingPathComponent(
                "UMICapture/CapturePackageUploader.swift"
            ),
            encoding: .utf8
        )

        for expected in [
            "X-iPhoneVIO-Pairing-Token",
            "api/captures/upload/init",
            "api/captures/upload/\\(uploadID)",
            "api/captures/upload/\\(uploadID)/finish",
            "X-Upload-Offset",
            "sha256"
        ] {
            XCTAssertTrue(uploader.contains(expected), expected)
        }
        XCTAssertFalse(uploader.contains("X-UMICapture-Pairing-Token"))
    }

    func testUploadResumesFromReceiverOffsetAfterChunkTransportFailure()
        throws {
        let fixture = try makeUploadFixture(Data("abcdefgh".utf8))
        defer { try? FileManager.default.removeItem(at: fixture) }
        let requests = UploadRequestRecorder()
        let step = LockedCounter()
        UploadURLProtocol.handler = { request in
            requests.append(request)
            switch step.incrementAndGet() {
            case 1:
                return .json(200, [
                    "upload_id": "upload-1",
                    "next_offset": 0,
                    "complete": false
                ])
            case 2:
                return .transport(
                    URLError(.networkConnectionLost)
                )
            case 3:
                return .json(200, [
                    "upload_id": "upload-1",
                    "next_offset": 3,
                    "complete": false
                ])
            case 4:
                return .json(200, ["next_offset": 8])
            case 5:
                return .json(200, [
                    "complete": true,
                    "stored_path": "captures/upload-1.zip"
                ])
            default:
                XCTFail("Unexpected upload request")
                return .json(500, ["error": "unexpected"])
            }
        }
        defer { UploadURLProtocol.handler = nil }
        let uploader = makeUploader()
        let completed = expectation(description: "upload completed")
        let duplicate = expectation(description: "completion exactly once")
        duplicate.isInverted = true
        let completionCount = LockedCounter()

        uploader.upload(
            fileURL: fixture,
            host: "receiver.test",
            port: 8848,
            deviceID: "device-hand",
            pairingToken: "token"
        ) { result in
            if completionCount.incrementAndGet() > 1 {
                duplicate.fulfill()
                return
            }
            XCTAssertEqual(
                try? result.get(),
                CaptureUploadReceipt(
                    uploadID: "upload-1",
                    storedPath: "captures/upload-1.zip"
                )
            )
            completed.fulfill()
        }
        wait(for: [completed, duplicate], timeout: 1)

        let captured = requests.snapshot()
        XCTAssertEqual(captured.map(\.httpMethod), ["POST", "PUT", "POST", "PUT", "POST"])
        let initializeBodies = try captured
            .filter { $0.url?.path == "/api/captures/upload/init" }
            .map(uploadJSONBody)
        XCTAssertEqual(initializeBodies.count, 2)
        XCTAssertEqual(
            initializeBodies[0] as NSDictionary,
            initializeBodies[1] as NSDictionary
        )
        XCTAssertEqual(initializeBodies[0]["device_id"] as? String, "device-hand")
        XCTAssertEqual(initializeBodies[0]["size_bytes"] as? Int, 8)
        XCTAssertEqual(
            captured[3].value(forHTTPHeaderField: "X-Upload-Offset"),
            "3"
        )
        XCTAssertEqual(captured[3].httpBody, Data("defgh".utf8))
        XCTAssertTrue(
            captured.allSatisfy {
                $0.value(
                    forHTTPHeaderField: "X-iPhoneVIO-Pairing-Token"
                ) == "token"
            }
        )
    }

    func testUploadReinitializesAfterTransientFinishFailure() throws {
        let fixture = try makeUploadFixture(Data("abc".utf8))
        defer { try? FileManager.default.removeItem(at: fixture) }
        let requests = UploadRequestRecorder()
        let step = LockedCounter()
        UploadURLProtocol.handler = { request in
            requests.append(request)
            switch step.incrementAndGet() {
            case 1:
                return .json(200, [
                    "upload_id": "upload-2",
                    "next_offset": 0,
                    "complete": false
                ])
            case 2:
                return .json(200, ["next_offset": 3])
            case 3:
                return .json(503, ["error": "temporary"])
            case 4:
                return .json(200, [
                    "upload_id": "upload-2",
                    "next_offset": 3,
                    "complete": false
                ])
            case 5:
                return .json(200, [
                    "complete": true,
                    "stored_path": "captures/upload-2.zip"
                ])
            default:
                XCTFail("Unexpected upload request")
                return .json(500, ["error": "unexpected"])
            }
        }
        defer { UploadURLProtocol.handler = nil }
        let completed = expectation(description: "finish retried")

        makeUploader().upload(
            fileURL: fixture,
            host: "receiver.test",
            port: 8848,
            deviceID: "device-hand",
            pairingToken: nil
        ) { result in
            XCTAssertEqual(try? result.get().uploadID, "upload-2")
            completed.fulfill()
        }
        wait(for: [completed], timeout: 1)

        let paths = requests.snapshot().compactMap { $0.url?.path }
        XCTAssertEqual(
            paths,
            [
                "/api/captures/upload/init",
                "/api/captures/upload/upload-2",
                "/api/captures/upload/upload-2/finish",
                "/api/captures/upload/init",
                "/api/captures/upload/upload-2/finish"
            ]
        )
    }

    func testUploadDoesNotRetryAuthorizationOrIntegrity4xx() throws {
        for statusCode in [401, 409] {
            let fixture = try makeUploadFixture(Data("abc".utf8))
            defer { try? FileManager.default.removeItem(at: fixture) }
            let requests = UploadRequestRecorder()
            let step = LockedCounter()
            UploadURLProtocol.handler = { request in
                requests.append(request)
                if step.incrementAndGet() == 1 {
                    return .json(200, [
                        "upload_id": "upload-4xx",
                        "next_offset": 0,
                        "complete": false
                    ])
                }
                return .json(
                    statusCode,
                    ["error": "terminal \(statusCode)"]
                )
            }
            let completed = expectation(
                description: "HTTP \(statusCode) failed fast"
            )

            makeUploader().upload(
                fileURL: fixture,
                host: "receiver.test",
                port: 8848,
                deviceID: "device-hand",
                pairingToken: "bad-token"
            ) { result in
                guard case .failure = result else {
                    XCTFail("4xx must fail")
                    completed.fulfill()
                    return
                }
                completed.fulfill()
            }
            wait(for: [completed], timeout: 1)
            XCTAssertEqual(requests.snapshot().count, 2)
            UploadURLProtocol.handler = nil
        }
    }

    func testAuthorizedUploadCanResumeAfterImmediateBudgetIsExhausted()
        throws {
        let fixture = try makeUploadFixture(Data("abcdefgh".utf8))
        defer { try? FileManager.default.removeItem(at: fixture) }
        let requests = UploadRequestRecorder()
        let step = LockedCounter()
        UploadURLProtocol.handler = { request in
            requests.append(request)
            switch step.incrementAndGet() {
            case 1:
                return .json(200, [
                    "upload_id": "durable-grant",
                    "next_offset": 0,
                    "complete": false
                ])
            case 2:
                return .transport(URLError(.notConnectedToInternet))
            case 3:
                return .json(200, [
                    "upload_id": "durable-grant",
                    "next_offset": 3,
                    "complete": false
                ])
            case 4:
                return .json(200, ["next_offset": 8])
            case 5:
                return .json(200, [
                    "complete": true,
                    "stored_path": "captures/durable-grant.zip"
                ])
            default:
                XCTFail("Unexpected upload request")
                return .json(500, ["error": "unexpected"])
            }
        }
        defer { UploadURLProtocol.handler = nil }

        let interrupted = expectation(
            description: "immediate retry budget exhausted"
        )
        makeUploader(maximumResumeAttempts: 0).upload(
            fileURL: fixture,
            host: "receiver.test",
            port: 8848,
            deviceID: "device-hand",
            pairingToken: "token"
        ) { result in
            guard case .failure(let error) = result else {
                XCTFail("Long interruption must leave a retryable job")
                interrupted.fulfill()
                return
            }
            XCTAssertTrue(
                CapturePackageUploadError.isRetryableInterruption(error)
            )
            interrupted.fulfill()
        }
        wait(for: [interrupted], timeout: 1)

        let resumed = expectation(description: "durable grant resumed")
        makeUploader(maximumResumeAttempts: 0).upload(
            fileURL: fixture,
            host: "receiver.test",
            port: 8848,
            deviceID: "device-hand",
            pairingToken: "token"
        ) { result in
            XCTAssertEqual(
                try? result.get(),
                CaptureUploadReceipt(
                    uploadID: "durable-grant",
                    storedPath: "captures/durable-grant.zip"
                )
            )
            resumed.fulfill()
        }
        wait(for: [resumed], timeout: 1)

        let captured = requests.snapshot()
        let initializeBodies = try captured
            .filter { $0.url?.path == "/api/captures/upload/init" }
            .map(uploadJSONBody)
        XCTAssertEqual(initializeBodies.count, 2)
        XCTAssertEqual(
            initializeBodies[0] as NSDictionary,
            initializeBodies[1] as NSDictionary
        )
        XCTAssertEqual(
            captured[3].value(forHTTPHeaderField: "X-Upload-Offset"),
            "3"
        )
        XCTAssertEqual(captured[3].httpBody, Data("defgh".utf8))
    }

    func testAuthorizedUploadJobIsRetainedUntilSuccessOrExplicitReset()
        throws {
        let repositoryURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let manager = try String(
            contentsOf: repositoryURL.appendingPathComponent(
                "UMICapture/ARSessionManager.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(
            manager.contains(
                "retryAuthorizedCoordinatedCaptureUpload()"
            )
        )
        XCTAssertTrue(
            manager.contains(
                "scheduleAuthorizedCoordinatedCaptureUploadRetry()"
            )
        )
        XCTAssertTrue(
            manager.contains(
                ".isRetryableInterruption(error)"
            )
        )
        XCTAssertTrue(
            manager.contains(
                "guard self.pendingCoordinatedCaptureUpload?.retryID"
            )
        )
    }

    private func makeUploader(
        maximumResumeAttempts: Int = 3
    ) -> CapturePackageUploader {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UploadURLProtocol.self]
        return CapturePackageUploader(
            session: URLSession(configuration: configuration),
            maximumResumeAttempts: maximumResumeAttempts,
            retryDelay: { _ in 0 }
        )
    }

    private func makeUploadFixture(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".zip")
        try data.write(to: url)
        return url
    }

    private func uploadJSONBody(
        _ request: URLRequest
    ) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: try XCTUnwrap(request.httpBody)
            ) as? [String: Any]
        )
    }
}

private enum UploadProtocolResponse {
    case json(Int, [String: Any])
    case transport(Error)
}

private final class UploadURLProtocol: URLProtocol {
    static var handler: ((URLRequest) -> UploadProtocolResponse)?

    override class func canInit(with _: URLRequest) -> Bool { true }

    override class func canonicalRequest(
        for request: URLRequest
    ) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(
                self,
                didFailWithError: URLError(.badServerResponse)
            )
            return
        }
        switch handler(request) {
        case .transport(let error):
            client?.urlProtocol(self, didFailWithError: error)
        case .json(let statusCode, let object):
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(
                self,
                didReceive: response,
                cacheStoragePolicy: .notAllowed
            )
            let data = try! JSONSerialization.data(withJSONObject: object)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}

private final class LockedCounter {
    private let lock = NSLock()
    private var value = 0

    func incrementAndGet() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}

private final class UploadRequestRecorder {
    private let lock = NSLock()
    private var requests: [URLRequest] = []

    func append(_ request: URLRequest) {
        var preserved = request
        if preserved.httpBody == nil,
           let stream = preserved.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var body = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = stream.read(
                    &buffer,
                    maxLength: buffer.count
                )
                guard count > 0 else { break }
                body.append(contentsOf: buffer.prefix(count))
            }
            preserved.httpBody = body
        }
        lock.lock()
        requests.append(preserved)
        lock.unlock()
    }

    func snapshot() -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }
}
