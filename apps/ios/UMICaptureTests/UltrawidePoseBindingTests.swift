import XCTest
import simd
@testable import UMICapture

final class UltrawidePoseBindingTests: XCTestCase {
    func testNearestMatchUsesEarlierSampleOnEqualDelta() throws {
        let generation = UUID()
        var timeline = UltrawidePoseTimeline(capacity: 4)
        timeline.append(sample(timestamp: 10.0, generation: generation))
        timeline.append(sample(timestamp: 10.02, generation: generation))

        let matched = try XCTUnwrap(
            timeline.nearest(
                to: 10.01,
                captureGeneration: generation
            )
        )
        XCTAssertEqual(matched.timestamp, 10.0, accuracy: 0.000_001)
    }

    func testBindingUsesMatchedARKitMetricPose() throws {
        let generation = UUID()
        var timeline = UltrawidePoseTimeline(capacity: 4)
        timeline.append(
            sample(
                timestamp: 2.0,
                generation: generation,
                referenceRelativeTransform:
                    translated(x: 0.25, y: -0.5, z: 0.75)
            )
        )
        let reference = translated(x: 1, y: 0, z: 0)
        let observation = UltrawideObservationSample(
            timestamp: 2.005,
            width: 640,
            height: 480,
            intrinsics: validIntrinsics,
            worldTransform: matrix_identity_float4x4
        )

        let bound = try XCTUnwrap(
            UltrawidePoseBinding.bind(
                observation: observation,
                referenceTransform: reference,
                timeline: timeline,
                captureGeneration: generation
            )
        )

        XCTAssertEqual(bound.cameraPose[3][0], 0.25, accuracy: 0.000_001)
        XCTAssertEqual(bound.cameraPose[3][1], -0.5, accuracy: 0.000_001)
        XCTAssertEqual(bound.cameraPose[3][2], 0.75, accuracy: 0.000_001)
        XCTAssertEqual(bound.poseMatchDelta, 0.005, accuracy: 0.000_001)
    }

    func testBindingRejectsCrossGenerationAndExcessiveDelta() {
        let generation = UUID()
        var timeline = UltrawidePoseTimeline(capacity: 4)
        timeline.append(sample(timestamp: 1.0, generation: UUID()))
        XCTAssertNil(
            UltrawidePoseBinding.bind(
                observation: observation(timestamp: 1.0),
                referenceTransform: matrix_identity_float4x4,
                timeline: timeline,
                captureGeneration: generation
            )
        )

        timeline.append(sample(timestamp: 1.0, generation: generation))
        XCTAssertNil(
            UltrawidePoseBinding.bind(
                observation: observation(timestamp: 1.1),
                referenceTransform: matrix_identity_float4x4,
                timeline: timeline,
                captureGeneration: generation
            )
        )
    }

    func testTimelineIsBoundedAndIgnoresBackwardSamples() {
        let generation = UUID()
        var timeline = UltrawidePoseTimeline(capacity: 2)
        timeline.append(sample(timestamp: 1, generation: generation))
        timeline.append(sample(timestamp: 2, generation: generation))
        timeline.append(sample(timestamp: 3, generation: generation))
        timeline.append(sample(timestamp: 2.5, generation: generation))

        XCTAssertEqual(timeline.samples.map(\.timestamp), [2, 3])
    }

    private var validIntrinsics: simd_float3x3 {
        var value = matrix_identity_float3x3
        value[0][0] = 240
        value[1][1] = 240
        value[2][0] = 320
        value[2][1] = 240
        return value
    }

    private func observation(
        timestamp: TimeInterval
    ) -> UltrawideObservationSample {
        UltrawideObservationSample(
            timestamp: timestamp,
            width: 640,
            height: 480,
            intrinsics: validIntrinsics,
            worldTransform: matrix_identity_float4x4
        )
    }

    private func sample(
        timestamp: TimeInterval,
        generation: UUID,
        referenceRelativeTransform: simd_float4x4 =
            matrix_identity_float4x4
    ) -> ARKitMetricPoseSample {
        ARKitMetricPoseSample(
            timestamp: timestamp,
            rawWorldTransform: matrix_identity_float4x4,
            referenceRelativeTransform: referenceRelativeTransform,
            captureGeneration: generation
        )
    }

    private func translated(
        x: Float,
        y: Float,
        z: Float
    ) -> simd_float4x4 {
        var value = matrix_identity_float4x4
        value[3] = SIMD4<Float>(x, y, z, 1)
        return value
    }
}
