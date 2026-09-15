import CoreGraphics
import simd

struct TrajectoryPresentationMath {
    let yaw: CGFloat
    let pitch: CGFloat

    func project(
        _ point: SIMD3<Double>,
        screenCenter: CGPoint,
        scale: CGFloat
    ) -> CGPoint {
        let rotated = rotate(point)
        return CGPoint(
            x: screenCenter.x + CGFloat(rotated.x) * scale,
            y: screenCenter.y - CGFloat(rotated.y) * scale
        )
    }

    func rotate(
        _ point: SIMD3<Double>
    ) -> SIMD3<Double> {
        let displayPoint = SIMD3<Double>(
            point.x,
            point.z,
            point.y
        )
        let yawCos = cos(Double(yaw))
        let yawSin = sin(Double(yaw))
        let pitchCos = cos(Double(pitch))
        let pitchSin = sin(Double(pitch))

        let yawX = yawCos * displayPoint.x
            + yawSin * displayPoint.z
        let yawZ = -yawSin * displayPoint.x
            + yawCos * displayPoint.z
        let pitchY = pitchCos * displayPoint.y
            - pitchSin * yawZ
        let pitchZ = pitchSin * displayPoint.y
            + pitchCos * yawZ
        return SIMD3<Double>(yawX, pitchY, pitchZ)
    }

    func plotPoint(
        _ point: SIMD3<Float>
    ) -> SIMD3<Double> {
        SIMD3<Double>(
            Double(point.x),
            Double(point.y),
            Double(point.z)
        )
    }
}
