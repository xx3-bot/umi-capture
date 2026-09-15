import Foundation
import XCTest
@testable import UMICapture

final class CaptureStoragePreflightTests: XCTestCase {
    private static let gibibyte: Int64 = 1_073_741_824

    func testOrdinaryCaptureRequiresOneGiB() {
        XCTAssertEqual(
            CaptureStorageMode.ordinaryVIO.requiredBytes,
            Self.gibibyte
        )
        XCTAssertEqual(
            CaptureStoragePreflight.evaluate(
                mode: .ordinaryVIO,
                importantCapacityBytes: Self.gibibyte,
                fallbackCapacityBytes: nil
            ).outcome,
            .allowed
        )
        XCTAssertEqual(
            CaptureStoragePreflight.evaluate(
                mode: .ordinaryVIO,
                importantCapacityBytes: Self.gibibyte - 1,
                fallbackCapacityBytes: nil
            ).outcome,
            .lowCapacity
        )
    }

    func testImportantCapacityWinsAndUnknownCapacityFailsClosed() {
        XCTAssertEqual(
            CaptureStoragePreflight.evaluate(
                mode: .ordinaryVIO,
                importantCapacityBytes: Self.gibibyte - 1,
                fallbackCapacityBytes: Self.gibibyte * 10
            ).outcome,
            .lowCapacity
        )
        XCTAssertEqual(
            CaptureStoragePreflight.evaluate(
                mode: .ordinaryVIO,
                importantCapacityBytes: nil,
                fallbackCapacityBytes: nil
            ).outcome,
            .capacityUnavailable
        )
    }

    func testStorageGateRunsBeforeCaptureMutation() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("UMICapture/ARSessionManager.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let validation = try sourceSlice(
            source,
            from: "    private func validateCaptureStart(",
            to: "    private func startStreamingImmediately("
        )
        let preflight = try XCTUnwrap(
            validation.range(of: "CaptureStoragePreflight.evaluateCurrent")
        )
        let cameraGuard = try XCTUnwrap(
            validation.range(of: "if selectedRGBVideoFormat == nil")
        )
        XCTAssertLessThan(
            validation.distance(from: validation.startIndex, to: preflight.lowerBound),
            validation.distance(from: validation.startIndex, to: cameraGuard.lowerBound)
        )
        let refusal = try sourceSlice(
            String(validation),
            from: "        let storageDecision = CaptureStoragePreflight.evaluateCurrent(",
            to: "        if selectedRGBVideoFormat == nil {"
        )
        XCTAssertTrue(refusal.contains("storage_unavailable"))
        for forbidden in [
            "isStreaming =", "beginCalibration(", "startRGBRecording(",
            "beginLogicalTrajectoryIfNeeded("
        ] {
            XCTAssertFalse(refusal.contains(forbidden), forbidden)
        }
    }

    private func sourceSlice(
        _ source: String,
        from startMarker: String,
        to endMarker: String
    ) throws -> Substring {
        let start = try XCTUnwrap(source.range(of: startMarker))
        let end = try XCTUnwrap(
            source.range(of: endMarker, range: start.upperBound..<source.endIndex)
        )
        return source[start.lowerBound..<end.lowerBound]
    }
}
