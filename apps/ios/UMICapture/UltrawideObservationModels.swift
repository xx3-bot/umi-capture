import Foundation
import simd

enum UltrawideObservationStatus: Equatable {
    case checking
    case privateAPIUnavailable
    case waitingForMetricPose(width: Int, height: Int)
    case invalid
    case available(UltrawideObservationMetrics)
}

struct UltrawideObservationMetrics: Equatable {
    let width: Int
    let height: Int
    let horizontalFieldOfViewDegrees: Double
    let poseMatchDeltaMilliseconds: Double
}

struct UltrawideObservationSample {
    let timestamp: TimeInterval
    let width: Int
    let height: Int
    let intrinsics: simd_float3x3
    let worldTransform: simd_float4x4
}

struct ARKitMetricPoseSample {
    let timestamp: TimeInterval
    let rawWorldTransform: simd_float4x4
    let referenceRelativeTransform: simd_float4x4
    let captureGeneration: UUID
}

struct BoundUltrawideObservation {
    let observation: UltrawideObservationSample
    let cameraPose: simd_float4x4
    let matchedARKitTimestamp: TimeInterval
    let poseMatchDelta: TimeInterval
    let captureGeneration: UUID
}

enum UltrawideObservationMath {
    static func isFinite(_ matrix: simd_float3x3) -> Bool {
        matrix.columns.0.allFinite
            && matrix.columns.1.allFinite
            && matrix.columns.2.allFinite
    }

    static func isFinite(_ matrix: simd_float4x4) -> Bool {
        matrix.columns.0.allFinite
            && matrix.columns.1.allFinite
            && matrix.columns.2.allFinite
            && matrix.columns.3.allFinite
    }

    static func horizontalFieldOfViewDegrees(
        width: Int,
        intrinsics: simd_float3x3
    ) -> Double? {
        let focalLength = Double(intrinsics[0][0])
        guard width > 0,
              focalLength.isFinite,
              focalLength > 0 else {
            return nil
        }
        return 2 * atan(Double(width) / (2 * focalLength))
            * 180 / .pi
    }
}

private extension SIMD3 where Scalar == Float {
    var allFinite: Bool {
        x.isFinite && y.isFinite && z.isFinite
    }
}

private extension SIMD4 where Scalar == Float {
    var allFinite: Bool {
        x.isFinite && y.isFinite && z.isFinite && w.isFinite
    }
}
