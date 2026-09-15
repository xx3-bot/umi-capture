import Foundation

enum CaptureFinalizationStage: String, Equatable {
    case idle
    case recording
    case draining
    case finishingWriters = "finishing_writers"
    case packaging
    case waitingUploadAuthorization = "waiting_upload_authorization"
    case uploading
    case completed
    case failed
}

enum CaptureFinalizationDeadlines {
    static let writerSeconds: TimeInterval = 12
    static let packageSeconds: TimeInterval = 30
}

enum CaptureFrameWorkPolicy {
    static func shouldProcess(
        isCalibrating: Bool,
        isStarting: Bool,
        isStreaming: Bool,
        synchronizedPhase: SynchronizedCapturePhase
    ) -> Bool {
        if isCalibrating || isStarting || isStreaming {
            return true
        }
        switch synchronizedPhase {
        case .requesting, .preparing, .armed, .starting, .running,
             .stopping:
            return true
        case .inactive, .finalizing, .finalized, .failed:
            return false
        }
    }
}

final class CaptureCompletionGate {
    private let lock = NSLock()
    private var completed = false

    @discardableResult
    func performOnce(_ body: () -> Void) -> Bool {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return false
        }
        completed = true
        lock.unlock()
        body()
        return true
    }
}

enum CapturePackageCancellationError: Error {
    case cancelled
}

final class CapturePackageCancellationToken {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    func throwIfCancelled() throws {
        lock.lock()
        let isCancelled = cancelled
        lock.unlock()
        if isCancelled {
            throw CapturePackageCancellationError.cancelled
        }
    }
}
