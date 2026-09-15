import Foundation
import simd

struct TrackingReadinessConfiguration: Equatable {
    let minimumTrackedTime: TimeInterval
    let requiredStableConfidence: TimeInterval
    let maximumSampleContribution: TimeInterval
    let maximumValidFrameInterval: TimeInterval
    let baseTranslationRate: Double
    let sparseTranslationRate: Double
    let baseAngularRateDegrees: Double
    let sparseAngularRateDegrees: Double
    let sparseFrameIntervalStart: TimeInterval
    let sparseFrameIntervalEnd: TimeInterval
    let unstableDecayRate: Double
    let nonNormalDecayRate: Double

    static let standard = TrackingReadinessConfiguration(
        minimumTrackedTime: 2.0,
        requiredStableConfidence: 1.5,
        maximumSampleContribution: 0.25,
        maximumValidFrameInterval: 1.0,
        baseTranslationRate: 0.45,
        sparseTranslationRate: 0.55,
        baseAngularRateDegrees: 90.0,
        sparseAngularRateDegrees: 105.0,
        sparseFrameIntervalStart: 0.05,
        sparseFrameIntervalEnd: 0.25,
        unstableDecayRate: 0.35,
        nonNormalDecayRate: 0.25
    )
}

enum TrackingReadinessPhase: Equatable {
    case waitingForNormalTracking
    case evaluatingTracking
    case holdingNaturally
    case reduceMovement
    case ready
}

struct TrackingReadinessResult: Equatable {
    let phase: TrackingReadinessPhase
    let progressPercent: Int
    let trackedTime: TimeInterval
    let stableConfidence: TimeInterval
    let translationRate: Double?
    let angularRateDegrees: Double?

    var isReady: Bool {
        phase == .ready
    }
}

final class TrackingReadinessEvaluator {
    let configuration: TrackingReadinessConfiguration

    private let lock = NSLock()
    private var previousTimestamp: TimeInterval?
    private var previousTransform: simd_float4x4?
    private var trackedTime: TimeInterval = 0
    private var stableConfidence: TimeInterval = 0

    init(
        configuration: TrackingReadinessConfiguration = .standard
    ) {
        self.configuration = configuration
    }

    func reset() {
        lock.lock()
        defer {
            lock.unlock()
        }
        previousTimestamp = nil
        previousTransform = nil
        trackedTime = 0
        stableConfidence = 0
    }

    func update(
        transform: simd_float4x4,
        timestamp: TimeInterval,
        trackingIsNormal: Bool
    ) -> TrackingReadinessResult {
        lock.lock()
        defer {
            lock.unlock()
        }

        let delta = previousTimestamp.map {
            timestamp - $0
        }
        previousTimestamp = timestamp

        guard trackingIsNormal else {
            if let effectiveDelta = validContribution(from: delta) {
                // Keep already-observed normal-tracking time. Brief ARKit
                // state flicker should reduce confidence, not erase valid
                // history accumulated while the phone was held naturally.
                stableConfidence = max(
                    0,
                    stableConfidence
                        - effectiveDelta
                        * configuration.nonNormalDecayRate
                )
            }
            previousTransform = nil
            return result(
                phase: .waitingForNormalTracking
            )
        }

        guard let delta,
              delta.isFinite,
              delta > 0,
              delta < configuration.maximumValidFrameInterval,
              let previousTransform
        else {
            self.previousTransform = transform
            return result(phase: .evaluatingTracking)
        }

        self.previousTransform = transform
        let effectiveDelta = min(
            delta,
            configuration.maximumSampleContribution
        )
        trackedTime += effectiveDelta

        let translationRate = translationRate(
            from: previousTransform,
            to: transform,
            delta: delta
        )
        let angularRate = angularRateDegrees(
            from: previousTransform,
            to: transform,
            delta: delta
        )
        let thresholds = motionThresholds(for: delta)
        let sampleIsStable =
            translationRate.isFinite
            && angularRate.isFinite
            && translationRate <= thresholds.translation
            && angularRate <= thresholds.angularDegrees

        if sampleIsStable {
            stableConfidence += effectiveDelta
        } else {
            stableConfidence = max(
                0,
                stableConfidence
                    - effectiveDelta
                    * configuration.unstableDecayRate
            )
        }

        let phase: TrackingReadinessPhase
        if trackedTime >= configuration.minimumTrackedTime,
           stableConfidence
            >= configuration.requiredStableConfidence {
            phase = .ready
        } else {
            phase = sampleIsStable
                ? .holdingNaturally
                : .reduceMovement
        }

        return result(
            phase: phase,
            translationRate: translationRate,
            angularRateDegrees: angularRate
        )
    }

    private func validContribution(
        from delta: TimeInterval?
    ) -> TimeInterval? {
        guard let delta,
              delta.isFinite,
              delta > 0,
              delta < configuration.maximumValidFrameInterval
        else {
            return nil
        }
        return min(
            delta,
            configuration.maximumSampleContribution
        )
    }

    private func motionThresholds(
        for delta: TimeInterval
    ) -> (
        translation: Double,
        angularDegrees: Double
    ) {
        let intervalRange = max(
            0.000_001,
            configuration.sparseFrameIntervalEnd
                - configuration.sparseFrameIntervalStart
        )
        let sparseAllowance = min(
            1,
            max(
                0,
                (
                    delta
                        - configuration.sparseFrameIntervalStart
                ) / intervalRange
            )
        )
        return (
            configuration.baseTranslationRate
                + (
                    configuration.sparseTranslationRate
                        - configuration.baseTranslationRate
                )
                * sparseAllowance,
            configuration.baseAngularRateDegrees
                + (
                    configuration.sparseAngularRateDegrees
                        - configuration.baseAngularRateDegrees
                )
                * sparseAllowance
        )
    }

    private func translationRate(
        from previous: simd_float4x4,
        to current: simd_float4x4,
        delta: TimeInterval
    ) -> Double {
        let previousPosition = SIMD3<Float>(
            previous.columns.3.x,
            previous.columns.3.y,
            previous.columns.3.z
        )
        let currentPosition = SIMD3<Float>(
            current.columns.3.x,
            current.columns.3.y,
            current.columns.3.z
        )
        return Double(
            simd_distance(previousPosition, currentPosition)
        ) / delta
    }

    private func angularRateDegrees(
        from previous: simd_float4x4,
        to current: simd_float4x4,
        delta: TimeInterval
    ) -> Double {
        let previousRotation = simd_float3x3(
            columns: (
                SIMD3<Float>(
                    previous.columns.0.x,
                    previous.columns.0.y,
                    previous.columns.0.z
                ),
                SIMD3<Float>(
                    previous.columns.1.x,
                    previous.columns.1.y,
                    previous.columns.1.z
                ),
                SIMD3<Float>(
                    previous.columns.2.x,
                    previous.columns.2.y,
                    previous.columns.2.z
                )
            )
        )
        let currentRotation = simd_float3x3(
            columns: (
                SIMD3<Float>(
                    current.columns.0.x,
                    current.columns.0.y,
                    current.columns.0.z
                ),
                SIMD3<Float>(
                    current.columns.1.x,
                    current.columns.1.y,
                    current.columns.1.z
                ),
                SIMD3<Float>(
                    current.columns.2.x,
                    current.columns.2.y,
                    current.columns.2.z
                )
            )
        )
        let relativeRotation =
            simd_transpose(previousRotation) * currentRotation
        let quaternion = simd_quatf(relativeRotation)
        let clampedReal = min(
            1,
            max(0, abs(Double(quaternion.real)))
        )
        let angleRadians = 2 * acos(clampedReal)
        return angleRadians * 180 / .pi / delta
    }

    private func result(
        phase: TrackingReadinessPhase,
        translationRate: Double? = nil,
        angularRateDegrees: Double? = nil
    ) -> TrackingReadinessResult {
        let trackedProgress = min(
            1,
            trackedTime / configuration.minimumTrackedTime
        )
        let stableProgress = min(
            1,
            stableConfidence
                / configuration.requiredStableConfidence
        )
        let progress = Int(
            floor(100 * min(trackedProgress, stableProgress))
        )
        return TrackingReadinessResult(
            phase: phase,
            progressPercent: progress,
            trackedTime: trackedTime,
            stableConfidence: stableConfidence,
            translationRate: translationRate,
            angularRateDegrees: angularRateDegrees
        )
    }
}
