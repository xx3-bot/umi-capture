import CoreGraphics
import XCTest
@testable import UMICapture

@MainActor
final class TrajectoryPresentationMathTests: XCTestCase {
    func testPlotPointPreservesRecordedCoordinates() {
        let math = makeMath(yaw: 0, pitch: 0)

        XCTAssertEqual(
            math.plotPoint(
                SIMD3<Float>(-1.25, 2.5, -3.75)
            ),
            SIMD3<Double>(-1.25, 2.5, -3.75)
        )
    }

    func testZeroRotationMapsRecordedXYZToDisplayXZY() {
        let math = makeMath(yaw: 0, pitch: 0)

        assertVector(
            math.rotate(
                SIMD3<Double>(1, 2, 3)
            ),
            equals: SIMD3<Double>(1, 3, 2)
        )
    }

    func testCombinedYawAndPitchRotationKeepsCurrentSigns() {
        let math = makeMath(
            yaw: .pi / 2,
            pitch: .pi / 2
        )

        assertVector(
            math.rotate(
                SIMD3<Double>(1, 2, 3)
            ),
            equals: SIMD3<Double>(2, 1, 3)
        )
    }

    func testProjectionKeepsCurrentScreenAxisDirections() {
        let math = makeMath(
            yaw: .pi / 2,
            pitch: .pi / 2
        )

        let projected = math.project(
            SIMD3<Double>(1, 2, 3),
            screenCenter: CGPoint(x: 120, y: 80),
            scale: 10
        )

        XCTAssertEqual(projected.x, 140, accuracy: 1e-9)
        XCTAssertEqual(projected.y, 70, accuracy: 1e-9)
    }

    private func makeMath(
        yaw: CGFloat,
        pitch: CGFloat
    ) -> TrajectoryPresentationMath {
        TrajectoryPresentationMath(yaw: yaw, pitch: pitch)
    }

    private func assertVector(
        _ actual: SIMD3<Double>,
        equals expected: SIMD3<Double>,
        accuracy: Double = 1e-9,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            actual.x,
            expected.x,
            accuracy: accuracy,
            file: file,
            line: line
        )
        XCTAssertEqual(
            actual.y,
            expected.y,
            accuracy: accuracy,
            file: file,
            line: line
        )
        XCTAssertEqual(
            actual.z,
            expected.z,
            accuracy: accuracy,
            file: file,
            line: line
        )
    }
}
