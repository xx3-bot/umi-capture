import Foundation

enum CaptureStorageMode: String {
    case ordinaryVIO

    var requiredBytes: Int64 {
        1_073_741_824
    }
}

enum CaptureStorageOutcome: String {
    case allowed
    case lowCapacity
    case capacityUnavailable
}

struct CaptureStorageDecision: Equatable {
    let mode: CaptureStorageMode
    let outcome: CaptureStorageOutcome
    let availableBytes: Int64?
    let requiredBytes: Int64

    var isAllowed: Bool {
        outcome == .allowed
    }

    var userMessage: String {
        switch outcome {
        case .allowed:
            "Storage is available"
        case .lowCapacity:
            "Capture not started — free at least \(Self.format(requiredBytes)) of device storage"
        case .capacityUnavailable:
            "Capture not started — available device storage could not be verified"
        }
    }

    private static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(
            fromByteCount: bytes,
            countStyle: .binary
        )
    }
}

enum CaptureStoragePreflight {
    static func evaluate(
        mode: CaptureStorageMode,
        importantCapacityBytes: Int64?,
        fallbackCapacityBytes: Int64?
    ) -> CaptureStorageDecision {
        let requiredBytes = mode.requiredBytes
        guard let reportedBytes =
            importantCapacityBytes ?? fallbackCapacityBytes
        else {
            return CaptureStorageDecision(
                mode: mode,
                outcome: .capacityUnavailable,
                availableBytes: nil,
                requiredBytes: requiredBytes
            )
        }

        let availableBytes = max(0, reportedBytes)
        return CaptureStorageDecision(
            mode: mode,
            outcome:
                availableBytes >= requiredBytes
                    ? .allowed
                    : .lowCapacity,
            availableBytes: availableBytes,
            requiredBytes: requiredBytes
        )
    }

    static func evaluateCurrent(
        for mode: CaptureStorageMode
    ) -> CaptureStorageDecision {
        guard let documentsURL = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first else {
            return evaluate(
                mode: mode,
                importantCapacityBytes: nil,
                fallbackCapacityBytes: nil
            )
        }

        let values = try? documentsURL.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey
        ])
        return evaluate(
            mode: mode,
            importantCapacityBytes:
                values?.volumeAvailableCapacityForImportantUsage,
            fallbackCapacityBytes:
                values?.volumeAvailableCapacity.map(Int64.init)
        )
    }
}
