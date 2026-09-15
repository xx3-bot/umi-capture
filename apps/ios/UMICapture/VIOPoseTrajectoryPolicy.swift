import Foundation
import simd

struct TrajectoryDisplayFrame: Equatable {
    let xAxisInReference: SIMD3<Float>
    let yAxisInReference: SIMD3<Float>
    let zAxisInReference: SIMD3<Float>
}

enum FrameDirectionAlignmentPolicy {
    static let identifier = "initial_camera_forward_gravity_up_v1"

    static func displayFrame(
        referenceTransform: simd_float4x4,
        profileID: CaptureProfileID
    ) -> TrajectoryDisplayFrame {
        // Direction-only alignment deliberately uses the same local
        // gravity/initial-camera rule for both roles. The profile parameter is
        // retained so callers cannot accidentally substitute a mount frame.
        _ = profileID
        return VIOPoseTrajectoryPolicy.makeTrajectoryDisplayFrame(
            referenceTransform: referenceTransform
        )
    }
}

enum ReferenceRelativePose {
    static func make(
        reference: simd_float4x4,
        current: simd_float4x4
    ) -> simd_float4x4 {
        simd_inverse(reference) * current
    }
}

enum VIOPoseTrajectoryPolicy {
    static let initialPhysicalTCPDisplayFrame =
        "Initial physical FastUMI TCP frame"

    static func physicalTCPRelativePose(
        referenceCamera: simd_float4x4,
        currentCamera: simd_float4x4,
        cameraToTCP: simd_float4x4
    ) -> simd_float4x4 {
        simd_inverse(cameraToTCP)
            * simd_inverse(referenceCamera)
            * currentCamera
            * cameraToTCP
    }

    static func physicalTCPRelativePose(
        referenceRelativeCamera: simd_float4x4,
        cameraToTCP: simd_float4x4
    ) -> simd_float4x4 {
        simd_inverse(cameraToTCP)
            * referenceRelativeCamera
            * cameraToTCP
    }

    static func transformPosition(
        _ transform: simd_float4x4
    ) -> SIMD3<Float> {
        SIMD3<Float>(
            transform.columns.3.x,
            transform.columns.3.y,
            transform.columns.3.z
        )
    }

    static func transformXAxis(
        _ transform: simd_float4x4
    ) -> SIMD3<Float> {
        normalized(
            SIMD3<Float>(
                transform.columns.0.x,
                transform.columns.0.y,
                transform.columns.0.z
            ),
            fallback: SIMD3<Float>(1, 0, 0)
        )
    }

    static func transformOrientationXYZW(
        _ transform: simd_float4x4
    ) -> SIMD4<Float> {
        let rotation = simd_float3x3(columns: (
            SIMD3<Float>(transform.columns.0.x, transform.columns.0.y, transform.columns.0.z),
            SIMD3<Float>(transform.columns.1.x, transform.columns.1.y, transform.columns.1.z),
            SIMD3<Float>(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z)
        ))
        return simd_normalize(simd_quatf(rotation)).vector
    }

    static func cameraForward(
        from transform: simd_float4x4
    ) -> SIMD3<Float> {
        let direction = -SIMD3<Float>(
            transform.columns.2.x,
            transform.columns.2.y,
            transform.columns.2.z
        )
        let length = simd_length(direction)
        guard length > 0.0001 else {
            return SIMD3<Float>(0, 0, -1)
        }
        return direction / length
    }

    static func makeTrajectoryDisplayFrame(
        referenceTransform: simd_float4x4
    ) -> TrajectoryDisplayFrame {
        var upInReference = SIMD3<Float>(
            referenceTransform.columns.0.y,
            referenceTransform.columns.1.y,
            referenceTransform.columns.2.y
        )
        upInReference = normalized(
            upInReference,
            fallback: SIMD3<Float>(0, 1, 0)
        )

        let initialCameraForward = SIMD3<Float>(0, 0, -1)
        var forwardOnGround = initialCameraForward
            - simd_dot(initialCameraForward, upInReference)
            * upInReference
        if simd_length(forwardOnGround) < 0.01 {
            let initialCameraRight = SIMD3<Float>(1, 0, 0)
            forwardOnGround = initialCameraRight
                - simd_dot(initialCameraRight, upInReference)
                * upInReference
        }
        forwardOnGround = normalized(
            forwardOnGround,
            fallback: SIMD3<Float>(0, 0, -1)
        )

        // Robot-standard right-handed display frame:
        // +X forward, +Y left, +Z up.
        let displayX = forwardOnGround
        let displayZ = upInReference
        let displayY = normalized(
            simd_cross(displayZ, displayX),
            fallback: SIMD3<Float>(-1, 0, 0)
        )

        return TrajectoryDisplayFrame(
            xAxisInReference: displayX,
            yAxisInReference: displayY,
            zAxisInReference: displayZ
        )
    }

    static func trajectoryDisplayPosition(
        _ position: SIMD3<Float>,
        frame: TrajectoryDisplayFrame?
    ) -> SIMD3<Float> {
        trajectoryDisplayDirection(position, frame: frame)
    }

    static func trajectoryDisplayDirection(
        _ direction: SIMD3<Float>,
        frame: TrajectoryDisplayFrame?
    ) -> SIMD3<Float> {
        guard let frame else {
            return direction
        }
        return SIMD3<Float>(
            simd_dot(direction, frame.xAxisInReference),
            simd_dot(direction, frame.yAxisInReference),
            simd_dot(direction, frame.zAxisInReference)
        )
    }

    static func trajectoryDisplayOrientationXYZW(
        from transform: simd_float4x4,
        frame: TrajectoryDisplayFrame?
    ) -> SIMD4<Float> {
        let rotation = simd_float3x3(
            trajectoryDisplayDirection(
                SIMD3<Float>(
                    transform.columns.0.x,
                    transform.columns.0.y,
                    transform.columns.0.z
                ),
                frame: frame
            ),
            trajectoryDisplayDirection(
                SIMD3<Float>(
                    transform.columns.1.x,
                    transform.columns.1.y,
                    transform.columns.1.z
                ),
                frame: frame
            ),
            trajectoryDisplayDirection(
                SIMD3<Float>(
                    transform.columns.2.x,
                    transform.columns.2.y,
                    transform.columns.2.z
                ),
                frame: frame
            )
        )
        let quaternion = simd_normalize(simd_quatf(rotation))
        return SIMD4<Float>(
            quaternion.imag.x,
            quaternion.imag.y,
            quaternion.imag.z,
            quaternion.real
        )
    }

    static func shouldSeedOrigin(sampleCount: Int) -> Bool {
        sampleCount == 0
    }

    static func captureRelativeTrajectoryPosition(
        _ position: SIMD3<Float>,
        captureOrigin: SIMD3<Float>
    ) -> SIMD3<Float> {
        position - captureOrigin
    }

    static func shouldSkipTrajectorySample(
        lastTimestamp: TimeInterval?,
        timestamp: TimeInterval,
        interval: TimeInterval,
        force: Bool
    ) -> Bool {
        guard !force, let lastTimestamp else {
            return false
        }
        return timestamp - lastTimestamp < interval
    }

    static func shouldDecimateTrajectory(
        sampleCount: Int,
        maximumPointCount: Int
    ) -> Bool {
        sampleCount >= maximumPointCount
    }

    static func activeClockDelta(
        previousTimestamp: TimeInterval?,
        timestamp: TimeInterval
    ) -> TimeInterval? {
        guard let previousTimestamp else {
            return nil
        }
        let delta = timestamp - previousTimestamp
        guard delta.isFinite, delta > 0 else {
            return nil
        }
        return delta
    }

    private static func normalized(
        _ vector: SIMD3<Float>,
        fallback: SIMD3<Float>
    ) -> SIMD3<Float> {
        let length = simd_length(vector)
        guard length > 0.0001 else {
            return fallback
        }
        return vector / length
    }
}
