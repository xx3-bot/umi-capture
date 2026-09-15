import XCTest
@testable import UMICapture

final class CaptureFinalizationPolicyTests: XCTestCase {
    func testCompletionGateRunsOnlyOnce() {
        let gate = CaptureCompletionGate()
        var calls = 0
        XCTAssertTrue(gate.performOnce { calls += 1 })
        XCTAssertFalse(gate.performOnce { calls += 1 })
        XCTAssertEqual(calls, 1)
    }

    func testFinalizationDeadlinesAreBounded() {
        XCTAssertEqual(CaptureFinalizationDeadlines.writerSeconds, 12)
        XCTAssertEqual(CaptureFinalizationDeadlines.packageSeconds, 30)
    }

    func testPackageCancellationTokenThrowsAfterCancellation() {
        let token = CapturePackageCancellationToken()
        XCTAssertNoThrow(try token.throwIfCancelled())
        token.cancel()
        XCTAssertThrowsError(try token.throwIfCancelled()) { error in
            XCTAssertTrue(error is CapturePackageCancellationError)
        }
    }

    func testHeavyFrameWorkRunsOnlyDuringPreparationOrCapture() {
        XCTAssertFalse(
            CaptureFrameWorkPolicy.shouldProcess(
                isCalibrating: false,
                isStarting: false,
                isStreaming: false,
                synchronizedPhase: .inactive
            )
        )
        XCTAssertFalse(
            CaptureFrameWorkPolicy.shouldProcess(
                isCalibrating: false,
                isStarting: false,
                isStreaming: false,
                synchronizedPhase: .finalized
            )
        )
        XCTAssertFalse(
            CaptureFrameWorkPolicy.shouldProcess(
                isCalibrating: false,
                isStarting: false,
                isStreaming: false,
                synchronizedPhase: .finalizing
            )
        )
        for phase in [
            SynchronizedCapturePhase.requesting,
            .preparing,
            .armed,
            .running
        ] {
            XCTAssertTrue(
                CaptureFrameWorkPolicy.shouldProcess(
                    isCalibrating: false,
                    isStarting: false,
                    isStreaming: false,
                    synchronizedPhase: phase
                )
            )
        }
        XCTAssertTrue(
            CaptureFrameWorkPolicy.shouldProcess(
                isCalibrating: true,
                isStarting: false,
                isStreaming: false,
                synchronizedPhase: .inactive
            )
        )
    }
}
