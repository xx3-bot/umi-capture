import Foundation
import simd

struct UltrawidePoseTimeline {
    private(set) var samples: [ARKitMetricPoseSample] = []
    let capacity: Int

    init(capacity: Int = 180) {
        self.capacity = max(2, capacity)
    }

    mutating func append(_ sample: ARKitMetricPoseSample) {
        if let last = samples.last,
           sample.timestamp <= last.timestamp {
            if sample.timestamp == last.timestamp {
                samples[samples.count - 1] = sample
            }
            return
        }
        samples.append(sample)
        if samples.count > capacity {
            samples.removeFirst(samples.count - capacity)
        }
    }

    func nearest(
        to timestamp: TimeInterval,
        captureGeneration: UUID
    ) -> ARKitMetricPoseSample? {
        samples
            .filter { $0.captureGeneration == captureGeneration }
            .min { lhs, rhs in
                let leftDelta = abs(lhs.timestamp - timestamp)
                let rightDelta = abs(rhs.timestamp - timestamp)
                if leftDelta == rightDelta {
                    return lhs.timestamp < rhs.timestamp
                }
                return leftDelta < rightDelta
            }
    }
}

enum UltrawidePoseBinding {
    static let initialMaximumMatchDelta: TimeInterval = 1.0 / 30.0

    static func bind(
        observation: UltrawideObservationSample,
        referenceTransform: simd_float4x4,
        timeline: UltrawidePoseTimeline,
        captureGeneration: UUID,
        maximumMatchDelta: TimeInterval = initialMaximumMatchDelta
    ) -> BoundUltrawideObservation? {
        guard observation.timestamp.isFinite,
              observation.timestamp > 0,
              observation.width > 0,
              observation.height > 0,
              UltrawideObservationMath.isFinite(
                  observation.intrinsics
              ),
              UltrawideObservationMath.isFinite(
                  observation.worldTransform
              ),
              UltrawideObservationMath.isFinite(referenceTransform),
              observation.intrinsics[0][0] > 0,
              observation.intrinsics[1][1] > 0,
              maximumMatchDelta.isFinite,
              maximumMatchDelta >= 0,
              let matched = timeline.nearest(
                  to: observation.timestamp,
                  captureGeneration: captureGeneration
              ) else {
            return nil
        }
        let delta = abs(matched.timestamp - observation.timestamp)
        guard delta <= maximumMatchDelta else {
            return nil
        }
        // iPhUMI treats the ultrawide image as a timestamped observation
        // alongside the ARKit pose stream. The private ultrawide ARCamera
        // transform is not a motion estimate on current iOS builds (it can be
        // identity for every frame), so bind the observation to the matched
        // authoritative ARKit metric pose instead.
        let cameraPose = matched.referenceRelativeTransform
        guard UltrawideObservationMath.isFinite(cameraPose) else {
            return nil
        }
        return BoundUltrawideObservation(
            observation: observation,
            cameraPose: cameraPose,
            matchedARKitTimestamp: matched.timestamp,
            poseMatchDelta: delta,
            captureGeneration: captureGeneration
        )
    }
}
