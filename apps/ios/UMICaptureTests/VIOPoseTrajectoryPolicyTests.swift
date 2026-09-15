import CryptoKit
import Foundation
import XCTest
import simd
@testable import UMICapture

final class VIOPoseTrajectoryPolicyTests: XCTestCase {
    func testDirectionOnlyAlignmentUsesSameCanonicalAxesForHandAndEgo() {
        var reference = matrix_identity_float4x4
        reference.columns.0 = SIMD4<Float>(0, 0, -1, 0)
        reference.columns.2 = SIMD4<Float>(1, 0, 0, 0)
        let hand = FrameDirectionAlignmentPolicy.displayFrame(
            referenceTransform: reference,
            profileID: .handheldUMI
        )
        let ego = FrameDirectionAlignmentPolicy.displayFrame(
            referenceTransform: reference,
            profileID: .chestEGO
        )
        XCTAssertEqual(hand, ego)
        XCTAssertEqual(
            FrameDirectionAlignmentPolicy.identifier,
            "initial_camera_forward_gravity_up_v1"
        )
    }
    func testLiteralFixtureRowsHaveStableIDsAndSchemas() {
        let tables: [(String, Int, Int)] = [
            (referenceRelativeRows, 4, 3),
            (displayFrameRows, 5, 3),
            (projectionRows, 5, 3),
            (samplingRows, 6, 6),
            (decimationRows, 4, 3),
            (clockRows, 4, 6),
            (originRows, 3, 2),
            (packetRows, 4, 1)
        ]
        let rows = tables.flatMap { table, columns, count in
            let parsed = parsedRows(table, expectedColumns: columns)
            XCTAssertEqual(parsed.count, count)
            return parsed
        }
        let ids = rows.map { String($0[0]) }
        XCTAssertEqual(ids.count, 27)
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertFalse(ids.contains(where: { $0.isEmpty }))
    }

    func testLiteralFixtureDigestIsFrozen() {
        let digest = SHA256.hash(data: Data(canonicalFixture.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        print("VIO_POSE_TRAJECTORY_LITERAL_DIGEST " + digest)
        XCTAssertEqual(
            digest,
            "225e93999ba47640c570a13292e45b72719a2fbb3ce9e443da17dccd455d95dc"
        )
    }

    func testCurrentReferenceRelativePoseMatchesLockedRows() {
        for row in parsedRows(
            referenceRelativeRows,
            expectedColumns: 4
        ) {
            let actual = ReferenceRelativePose.make(
                reference: matrix(String(row[1])),
                current: matrix(String(row[2]))
            )
            assertMatrix(
                actual,
                equals: matrix(String(row[3])),
                accuracy: 0.000_01,
                id: String(row[0])
            )
        }
    }

    func testPhysicalTCPRelativePoseStartsAtCompleteIdentity() {
        let camera = matrix(
            String(
                parsedRows(
                    referenceRelativeRows,
                    expectedColumns: 4
                )[1][2]
            )
        )
        let result = VIOPoseTrajectoryPolicy.physicalTCPRelativePose(
            referenceCamera: camera,
            currentCamera: camera,
            cameraToTCP: PhysicalTCPProfile.fastUMIIPhone.cameraToTCP
        )
        assertMatrix(
            result,
            equals: matrix_identity_float4x4,
            accuracy: 0.000_001,
            id: "physical_tcp.first_identity"
        )
    }

    func testPhysicalTCPMotionIsNotCameraOpticalHeadingProjection() {
        let cameraToTCP = PhysicalTCPProfile.fastUMIIPhone.cameraToTCP
        var expectedMotion = matrix_identity_float4x4
        expectedMotion.columns.3 = SIMD4<Float>(0.12, -0.04, -0.08, 1)
        let currentCamera = cameraToTCP
            * expectedMotion
            * simd_inverse(cameraToTCP)
        let actual = VIOPoseTrajectoryPolicy.physicalTCPRelativePose(
            referenceCamera: matrix_identity_float4x4,
            currentCamera: currentCamera,
            cameraToTCP: cameraToTCP
        )
        assertMatrix(
            actual,
            equals: expectedMotion,
            accuracy: 0.000_001,
            id: "physical_tcp.signed_xyz"
        )
    }

    func testCurrentPosePacketMatchesLockedNontrivialHex() {
        let row = parsedRows(packetRows, expectedColumns: 4)[0]
        let packet = PosePacketV1(
            transformMatrix: matrix(String(row[1])),
            timestamp: Double(row[2])!
        )
        XCTAssertEqual(
            packet.toBytes().map { String(format: "%02x", $0) }
                .joined(),
            String(row[3])
        )
        XCTAssertEqual(packet.toBytes().count, 72)
    }

    func testProductionDisplayFramesMatchLockedRows() {
        for row in parsedRows(displayFrameRows, expectedColumns: 5) {
            let frame = VIOPoseTrajectoryPolicy
                .makeTrajectoryDisplayFrame(
                    referenceTransform: matrix(String(row[1]))
                )
            let expectedX = vector3(String(row[2]))
            let expectedY = vector3(String(row[3]))
            let expectedZ = vector3(String(row[4]))
            assertVector(
                frame.xAxisInReference,
                equals: expectedX,
                id: String(row[0]) + ".x"
            )
            assertVector(
                frame.yAxisInReference,
                equals: expectedY,
                id: String(row[0]) + ".y"
            )
            assertVector(
                frame.zAxisInReference,
                equals: expectedZ,
                id: String(row[0]) + ".z"
            )
            XCTAssertEqual(
                simd_length(frame.xAxisInReference),
                1,
                accuracy: 0.000_01
            )
            XCTAssertEqual(
                simd_dot(
                    frame.xAxisInReference,
                    frame.yAxisInReference
                ),
                0,
                accuracy: 0.000_01
            )
            assertVector(
                simd_cross(
                    frame.xAxisInReference,
                    frame.yAxisInReference
                ),
                equals: frame.zAxisInReference,
                id: String(row[0]) + ".handedness"
            )
        }
    }

    func testProductionProjectionMatchesLockedRows() {
        let frame = VIOPoseTrajectoryPolicy
            .makeTrajectoryDisplayFrame(
                referenceTransform: matrix_identity_float4x4
            )
        for row in parsedRows(projectionRows, expectedColumns: 5) {
            let id = String(row[0])
            switch row[1] {
            case "position":
                assertVector(
                    VIOPoseTrajectoryPolicy
                        .trajectoryDisplayPosition(
                            vector3(String(row[2])),
                            frame: frame
                        ),
                    equals: vector3(String(row[3])),
                    id: id
                )
            case "direction":
                assertVector(
                    VIOPoseTrajectoryPolicy
                        .trajectoryDisplayDirection(
                            vector3(String(row[2])),
                            frame: frame
                        ),
                    equals: vector3(String(row[3])),
                    id: id
                )
            case "orientation":
                assertVector(
                    VIOPoseTrajectoryPolicy
                        .trajectoryDisplayOrientationXYZW(
                            from: matrix(String(row[2])),
                            frame: frame
                        ),
                    equals: vector4(String(row[3])),
                    id: id
                )
            default:
                XCTFail("Unknown projection row: \(id)")
            }
        }
    }

    func testProductionCameraForwardPreservesLockedFallback() {
        let lockedForward = vector3(
            String(
                parsedRows(projectionRows, expectedColumns: 5)[1][2]
            )
        )
        assertVector(
            VIOPoseTrajectoryPolicy.cameraForward(
                from: matrix(
                    String(
                        parsedRows(packetRows, expectedColumns: 4)[0][1]
                    )
                )
            ),
            equals: lockedForward,
            id: "cameraForward.nontrivial"
        )
        assertVector(
            VIOPoseTrajectoryPolicy.cameraForward(
                from: simd_float4x4(
                    SIMD4<Float>(1, 0, 0, 0),
                    SIMD4<Float>(0, 1, 0, 0),
                    SIMD4<Float>(0, 0, 0, 0),
                    SIMD4<Float>(0, 0, 0, 1)
                )
            ),
            equals: lockedForward,
            id: "cameraForward.degenerate"
        )
    }

    func testProductionSamplingDecimationAndOriginMatchLockedRows() {
        for row in parsedRows(samplingRows, expectedColumns: 6) {
            XCTAssertEqual(
                VIOPoseTrajectoryPolicy.shouldSkipTrajectorySample(
                    lastTimestamp: timeValue(row[1]),
                    timestamp: timeValue(row[2])!,
                    interval: timeValue(row[3])!,
                    force: row[4] == "1"
                ),
                row[5] == "1",
                String(row[0])
            )
        }
        for row in parsedRows(decimationRows, expectedColumns: 4) {
            XCTAssertEqual(
                VIOPoseTrajectoryPolicy.shouldDecimateTrajectory(
                    sampleCount: Int(row[1])!,
                    maximumPointCount: Int(row[2])!
                ),
                row[3] == "1",
                String(row[0])
            )
        }
        for row in parsedRows(originRows, expectedColumns: 3) {
            XCTAssertEqual(
                VIOPoseTrajectoryPolicy.shouldSeedOrigin(
                    sampleCount: Int(row[1])!
                ),
                row[2] == "1",
                String(row[0])
            )
        }
    }

    func testCaptureRelativeTrajectoryStartsAtTheAcceptedCapturePosition() {
        let origin = SIMD3<Float>(-1.99, 2.11, -0.05)
        assertVector(
            VIOPoseTrajectoryPolicy.captureRelativeTrajectoryPosition(
                origin,
                captureOrigin: origin
            ),
            equals: .zero,
            id: "capture-origin"
        )
        assertVector(
            VIOPoseTrajectoryPolicy.captureRelativeTrajectoryPosition(
                SIMD3<Float>(-1.79, 2.01, 0.05),
                captureOrigin: origin
            ),
            equals: SIMD3<Float>(0.2, -0.1, 0.1),
            id: "capture-relative-motion"
        )
    }

    func testProductionClockDeltaMatchesLockedRows() {
        for row in parsedRows(clockRows, expectedColumns: 4) {
            let actual = VIOPoseTrajectoryPolicy.activeClockDelta(
                previousTimestamp: timeValue(row[1]),
                timestamp: timeValue(row[2])!
            )
            if let expected = timeValue(row[3]) {
                XCTAssertNotNil(actual, String(row[0]))
                XCTAssertEqual(
                    actual!,
                    expected,
                    accuracy: 0.000_000_1,
                    String(row[0])
                )
            } else {
                XCTAssertNil(actual, String(row[0]))
            }
        }
    }

    func testARSessionManagerRetainsMutationAndOutputOwnership() throws {
        let source = try String(
            contentsOf: projectFile(
                "UMICapture/ARSessionManager.swift"
            ),
            encoding: .utf8
        )
        let orderedTokens = [
            "shouldSeedOrigin(",
            "trajectorySamples = [",
            "shouldSkipTrajectorySample(",
            "shouldDecimateTrajectory(",
            "trajectorySamples.append("
        ]
        var lowerBound = source.startIndex
        for token in orderedTokens {
            let range = try XCTUnwrap(
                source.range(of: token, range: lowerBound..<source.endIndex),
                token
            )
            lowerBound = range.upperBound
        }
        XCTAssertTrue(
            source.contains(
                "PosePacketV1("
            )
        )
        XCTAssertTrue(source.contains("cameraPose: outputTransform"))
        XCTAssertTrue(
            source.contains(
                "trajectoryDisplayPosition(latestOutputPosition)"
            )
        )
    }

    func testPolicySourceHasNoPlatformOrOwnershipDependencies() throws {
        let source = try String(
            contentsOf: projectFile(
                "UMICapture/VIOPoseTrajectoryPolicy.swift"
            ),
            encoding: .utf8
        )
        for forbidden in [
            "import ARKit",
            "import UIKit",
            "import SwiftUI",
            "import AVFoundation",
            "import Combine",
            "import SceneKit",
            "import SocketIO",
            "DispatchQueue",
            "FileManager",
            "static var ",
            "class "
        ] {
            XCTAssertFalse(source.contains(forbidden), forbidden)
        }
        XCTAssertTrue(source.contains("import Foundation"))
        XCTAssertTrue(source.contains("import simd"))
    }

    private func parsedRows(
        _ table: String,
        expectedColumns: Int
    ) -> [[Substring]] {
        table.split(separator: "\n").map { line in
            let columns = line.split(
                separator: "|",
                omittingEmptySubsequences: false
            )
            XCTAssertEqual(
                columns.count,
                expectedColumns,
                String(line)
            )
            return columns
        }
    }

    private func matrix(_ value: String) -> simd_float4x4 {
        let values = value.split(separator: ",").map {
            Float($0)!
        }
        XCTAssertEqual(values.count, 16)
        return simd_float4x4(
            SIMD4<Float>(values[0], values[1], values[2], values[3]),
            SIMD4<Float>(values[4], values[5], values[6], values[7]),
            SIMD4<Float>(values[8], values[9], values[10], values[11]),
            SIMD4<Float>(values[12], values[13], values[14], values[15])
        )
    }

    private func vector3(_ value: String) -> SIMD3<Float> {
        let values = value.split(separator: ",").map { Float($0)! }
        XCTAssertEqual(values.count, 3)
        return SIMD3<Float>(values[0], values[1], values[2])
    }

    private func vector4(_ value: String) -> SIMD4<Float> {
        let values = value.split(separator: ",").map { Float($0)! }
        XCTAssertEqual(values.count, 4)
        return SIMD4<Float>(
            values[0],
            values[1],
            values[2],
            values[3]
        )
    }

    private func timeValue(_ value: Substring) -> TimeInterval? {
        switch value {
        case "nil":
            return nil
        case "nan":
            return .nan
        case "inf":
            return .infinity
        default:
            return TimeInterval(value)!
        }
    }

    private func assertMatrix(
        _ actual: simd_float4x4,
        equals expected: simd_float4x4,
        accuracy: Float,
        id: String
    ) {
        for column in 0..<4 {
            for row in 0..<4 {
                XCTAssertEqual(
                    actual[column][row],
                    expected[column][row],
                    accuracy: accuracy,
                    "\(id) [\(column)][\(row)]"
                )
            }
        }
    }

    private func assertVector(
        _ actual: SIMD3<Float>,
        equals expected: SIMD3<Float>,
        id: String
    ) {
        for index in 0..<3 {
            XCTAssertEqual(
                actual[index],
                expected[index],
                accuracy: 0.000_01,
                "\(id) [\(index)]"
            )
        }
    }

    private func assertVector(
        _ actual: SIMD4<Float>,
        equals expected: SIMD4<Float>,
        id: String
    ) {
        for index in 0..<4 {
            XCTAssertEqual(
                actual[index],
                expected[index],
                accuracy: 0.000_01,
                "\(id) [\(index)]"
            )
        }
    }

    private func projectFile(_ path: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(path)
    }

    private var canonicalFixture: String {
        [
            referenceRelativeRows,
            "--DISPLAY-FRAME--",
            displayFrameRows,
            "--PROJECTION--",
            projectionRows,
            "--SAMPLING--",
            samplingRows,
            "--DECIMATION--",
            decimationRows,
            "--CLOCK--",
            clockRows,
            "--ORIGIN--",
            originRows,
            "--PACKET--",
            packetRows
        ].joined(separator: "\n")
    }

    private let referenceRelativeRows = #"""
pose.identity|1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1|1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1|1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1
pose.nontrivial|1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1|0,1,0,0,-1,0,0,0,0,0,1,0,1.25,-2.5,3.75,1|0,1,0,0,-1,0,0,0,0,0,1,0,1.25,-2.5,3.75,1
pose.globalRollInvariant|1,0,0,0,0,0,1,0,0,-1,0,0,0,0,0,1|1,0,0,0,0,0,1,0,0,-1,0,0,0.5,0.75,0.25,1|1,0,0,0,0,1,0,0,0,0,1,0,0.5,0.25,-0.75,1
"""#

    private let displayFrameRows = #"""
display.identityReference|1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1|0,0,-1|-1,0,0|0,1,0
display.zeroFallback|0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0|0,0,-1|-1,0,0|0,1,0
display.forwardDegenerate|1,0,0,0,0,0,1,0,0,-1,0,0,0,0,0,1|1,0,0|0,-1,0|0,0,-1
"""#

    private let projectionRows = #"""
projection.position|position|1.25,-2.5,3.75|-3.75,-1.25,-2.5|identity-reference-display-frame
projection.cameraForward|direction|0,0,-1|1,0,0|identity-reference-display-frame
projection.orientation|orientation|0,1,0,0,-1,0,0,0,0,0,1,0,1.25,-2.5,3.75,1|0,-0.70710677,0,0.70710677|identity-reference-display-frame-xyzw
"""#

    private let samplingRows = #"""
sampling.noPrevious|nil|10|0.1|0|0
sampling.underInterval|0|0.099|0.1|0|1
sampling.equalInterval|0|0.1|0.1|0|0
sampling.overInterval|0|0.101|0.1|0|0
sampling.forceBypassesInterval|0|0.01|0.1|1|0
sampling.nanDoesNotCompareLess|0|nan|0.1|0|0
"""#

    private let decimationRows = #"""
decimation.belowLimit|4999|5000|0
decimation.atLimit|5000|5000|1
decimation.aboveLimit|5001|5000|1
"""#

    private let clockRows = #"""
clock.noPrevious|nil|1|nil
clock.positive|1|1.25|0.25
clock.zero|1|1|nil
clock.negative|1|0.5|nil
clock.nan|1|nan|nil
clock.infinity|1|inf|nil
"""#

    private let originRows = #"""
origin.empty|0|1
origin.nonempty|1|0
"""#

    private let packetRows = #"""
packet.nontrivial72|0,1,0,0,-1,0,0,0,0,0,1,0,1.25,-2.5,3.75,1|42.125|000000000000803f0000000000000000000080bf00000000000000000000000000000000000000000000803f000000000000a03f000020c0000070400000803f0000000000104540
"""#
}
