import Foundation

enum RecorderStreamKind: Equatable {
    case rawRGB
    case processed224
    case ultrawide
}

struct RecorderStreamPlan: Equatable {
    let rawRGB: Bool
    let processed224: Bool
    let ultrawide: Bool

    init(
        rawRGB: Bool,
        processed224: Bool,
        ultrawide: Bool
    ) {
        self.rawRGB = rawRGB
        self.processed224 = processed224
        self.ultrawide = ultrawide
    }

    init(configuration: RGBRecordingConfiguration) {
        self.init(
            rawRGB: configuration.includeRawRGBVideo,
            processed224: configuration.includeProcessedRGBVideo,
            ultrawide: configuration.includeUltrawideObservation
        )
    }

    var requiresRawWriter: Bool { rawRGB }
    var requiresProcessedWriter: Bool { processed224 }
    var retainsMainCameraImage: Bool { rawRGB || processed224 }

    var packageKinds: [RecorderStreamKind] {
        var result: [RecorderStreamKind] = []
        if rawRGB { result.append(.rawRGB) }
        if processed224 { result.append(.processed224) }
        if ultrawide { result.append(.ultrawide) }
        return result
    }
}

struct RGBFrameAdmissionState {
    let targetFramesPerSecond: Int
    let sourceFramesPerSecond: Int
    let retainsMainCameraImage: Bool
    private(set) var lastReservedTimestamp: TimeInterval?

    init(
        targetFramesPerSecond: Int,
        sourceFramesPerSecond: Int,
        retainsMainCameraImage: Bool = true
    ) {
        self.targetFramesPerSecond = max(1, targetFramesPerSecond)
        self.sourceFramesPerSecond = max(1, sourceFramesPerSecond)
        self.retainsMainCameraImage = retainsMainCameraImage
    }

    mutating func reserveMainImage(timestamp: TimeInterval) -> Bool {
        guard retainsMainCameraImage else { return false }
        guard let lastReservedTimestamp else {
            self.lastReservedTimestamp = timestamp
            return true
        }
        let effectiveFPS = max(
            1,
            min(targetFramesPerSecond, sourceFramesPerSecond)
        )
        let interval = 1.0 / Double(effectiveFPS)
        guard timestamp - lastReservedTimestamp >= interval - 0.000_5 else {
            return false
        }
        self.lastReservedTimestamp = timestamp
        return true
    }
}
