import XCTest
@testable import UMICapture

final class RGBFrameAdmissionTests: XCTestCase {
    func testThirtyFPSAdmissionFromSixtyHzKeepsEveryOtherMainImage() {
        var state = RGBFrameAdmissionState(
            targetFramesPerSecond: 30,
            sourceFramesPerSecond: 60
        )
        let timestamps = (0..<6).map { Double($0) / 60.0 }
        XCTAssertEqual(
            timestamps.map { state.reserveMainImage(timestamp: $0) },
            [true, false, true, false, true, false]
        )
    }

    func testRawOffPlanContainsNoRawPipeline() {
        let plan = RecorderStreamPlan(
            rawRGB: false,
            processed224: true,
            ultrawide: true
        )
        XCTAssertFalse(plan.requiresRawWriter)
        XCTAssertEqual(plan.packageKinds, [.processed224, .ultrawide])
    }

    func testUltrawideOnlyPlanDoesNotRetainMainCameraImage() {
        let plan = RecorderStreamPlan(
            rawRGB: false,
            processed224: false,
            ultrawide: true
        )
        var state = RGBFrameAdmissionState(
            targetFramesPerSecond: 30,
            sourceFramesPerSecond: 60,
            retainsMainCameraImage: plan.retainsMainCameraImage
        )
        XCTAssertFalse(state.reserveMainImage(timestamp: 1))
        XCTAssertTrue(plan.ultrawide)
    }
}
