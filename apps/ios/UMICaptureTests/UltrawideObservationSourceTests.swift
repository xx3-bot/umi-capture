import XCTest
import simd
@testable import UMICapture

final class UltrawideObservationSourceTests: XCTestCase {
    func testPrivateFieldContractMatchesIPhUMIReference() {
        XCTAssertEqual(
            ARFrameUltrawideObservationSource
                .capturedImageIvarName,
            "_capturedUltraWideImage"
        )
        XCTAssertEqual(
            ARFrameUltrawideObservationSource.timestampIvarName,
            "_ultraWideImageTimestamp"
        )
        XCTAssertEqual(
            ARFrameUltrawideObservationSource.cameraIvarName,
            "_ultraWideCamera"
        )
    }

    func testFieldOfViewUsesActualBufferWidthAndIntrinsics() {
        var intrinsics = matrix_identity_float3x3
        intrinsics[0][0] = 240
        intrinsics[1][1] = 240

        let fieldOfView = UltrawideObservationMath
            .horizontalFieldOfViewDegrees(
                width: 640,
                intrinsics: intrinsics
            )

        XCTAssertEqual(fieldOfView!, 106.2602, accuracy: 0.001)
    }

    func testInvalidFocalLengthDoesNotProduceFieldOfView() {
        var intrinsics = matrix_identity_float3x3
        intrinsics[0][0] = Float.nan
        XCTAssertNil(
            UltrawideObservationMath
                .horizontalFieldOfViewDegrees(
                    width: 640,
                    intrinsics: intrinsics
                )
        )
    }
}
