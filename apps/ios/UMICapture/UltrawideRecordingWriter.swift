import AVFoundation
import CoreImage
import Foundation
import UIKit

struct UltrawideRecordingFrame {
    let pixelBuffer: CVPixelBuffer
    let boundObservation: BoundUltrawideObservation
    let interfaceOrientation: String
}

struct UltrawideRecordingSummary: Equatable {
    let videoFilename: String?
    let framesMetadataFilename: String?
    let previewFilename: String?
    let width: Int?
    let height: Int?
    let encodedFrameCount: Int
    let droppedFrameCount: Int
    let firstFrameIntrinsics: [[Float]]?
    let errorMessage: String?

    static let unavailable = UltrawideRecordingSummary(
        videoFilename: nil,
        framesMetadataFilename: nil,
        previewFilename: nil,
        width: nil,
        height: nil,
        encodedFrameCount: 0,
        droppedFrameCount: 0,
        firstFrameIntrinsics: nil,
        errorMessage: "No synchronized 0.5x observation was recorded."
    )

    static func failed(reason: String) -> UltrawideRecordingSummary {
        UltrawideRecordingSummary(
            videoFilename: nil,
            framesMetadataFilename: nil,
            previewFilename: nil,
            width: nil,
            height: nil,
            encodedFrameCount: 0,
            droppedFrameCount: 0,
            firstFrameIntrinsics: nil,
            errorMessage: reason
        )
    }
}

struct UltrawideFrameMetadata: Codable, Equatable {
    let schemaVersion: Int
    let frameIndex: Int
    let dataKey: String
    let width: Int
    let height: Int
    let ultrawideTimestampSeconds: Double
    let matchedARKitTimestampSeconds: Double
    let poseMatchDeltaSeconds: Double
    let mp4PresentationTimeSeconds: Double
    let cameraIntrinsics: [[Float]]
    let cameraPose: [[Float]]
    let cameraWorldTransform: [[Float]]
    let interfaceOrientation: String
    let encoded: Bool
    let dropReason: String?

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case frameIndex = "frame_index"
        case dataKey = "data_key"
        case width
        case height
        case ultrawideTimestampSeconds = "ultrawide_timestamp_s"
        case matchedARKitTimestampSeconds = "matched_arkit_timestamp_s"
        case poseMatchDeltaSeconds = "pose_match_delta_s"
        case mp4PresentationTimeSeconds = "mp4_pts_s"
        case cameraIntrinsics = "camera_intrinsics"
        case cameraPose = "camera_pose"
        case cameraWorldTransform = "camera_world_transform"
        case interfaceOrientation = "interface_orientation"
        case encoded
        case dropReason = "drop_reason"
    }
}

final class UltrawideRecordingWriter {
    static let videoFilename = "ultrawide_rgb.mp4"
    static let framesFilename = "ultrawide_frames.jsonl"
    static let previewFilename = "ultrawide_preview.jpg"

    private let directoryURL: URL
    private let nominalFramesPerSecond: Int
    private let bitRate: Int
    private let dataKey: String
    private let videoWritingURL: URL
    private let framesWritingURL: URL
    private let previewWritingURL: URL
    private let framesHandle: FileHandle
    private let encoder: JSONEncoder
    private let ciContext = CIContext(options: [.cacheIntermediates: false])

    private var writer: AVAssetWriter?
    private var writerInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var firstTimestamp: TimeInterval?
    private var lastPresentationTime = CMTime.invalid
    private var width: Int?
    private var height: Int?
    private var firstFrameIntrinsics: [[Float]]?
    private var frameIndex = 0
    private(set) var encodedFrameCount = 0
    private(set) var droppedFrameCount = 0
    private var previewWasWritten = false
    private var errorMessage: String?
    private let finalizationGate = CaptureCompletionGate()
    private var finishCompletion:
        ((UltrawideRecordingSummary) -> Void)?

    init(
        directoryURL: URL,
        nominalFramesPerSecond: Int,
        bitRate: Int = 8_000_000,
        dataKey: String
    ) throws {
        self.directoryURL = directoryURL
        self.nominalFramesPerSecond = max(1, nominalFramesPerSecond)
        self.bitRate = max(1, bitRate)
        self.dataKey = dataKey
        videoWritingURL = directoryURL.appendingPathComponent(
            Self.videoFilename + ".writing"
        )
        framesWritingURL = directoryURL.appendingPathComponent(
            Self.framesFilename + ".writing"
        )
        previewWritingURL = directoryURL.appendingPathComponent(
            Self.previewFilename + ".writing"
        )
        FileManager.default.createFile(
            atPath: framesWritingURL.path,
            contents: nil
        )
        framesHandle = try FileHandle(forWritingTo: framesWritingURL)
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
    }

    func append(_ frame: UltrawideRecordingFrame) {
        let observation = frame.boundObservation.observation
        do {
            try configureIfNeeded(frame: frame)
        } catch {
            recordDrop(frame: frame, reason: "writer_setup_failed")
            errorMessage = error.localizedDescription
            return
        }

        guard let writer,
              let writerInput,
              let adaptor,
              writer.status == .writing else {
            recordDrop(frame: frame, reason: "writer_not_writing")
            errorMessage = writer?.error?.localizedDescription
                ?? "0.5x video writer is not accepting frames."
            return
        }
        guard observation.width == width,
              observation.height == height else {
            recordDrop(frame: frame, reason: "dimension_changed")
            return
        }

        let presentationTime = makePresentationTime(
            timestamp: observation.timestamp
        )
        guard !lastPresentationTime.isValid
                || CMTimeCompare(presentationTime, lastPresentationTime) > 0
        else {
            recordDrop(
                frame: frame,
                presentationTime: presentationTime,
                reason: "non_increasing_pts"
            )
            return
        }
        guard writerInput.isReadyForMoreMediaData else {
            lastPresentationTime = presentationTime
            recordDrop(
                frame: frame,
                presentationTime: presentationTime,
                reason: "writer_not_ready"
            )
            return
        }

        let encoded = adaptor.append(
            frame.pixelBuffer,
            withPresentationTime: presentationTime
        )
        lastPresentationTime = presentationTime
        if encoded {
            encodedFrameCount += 1
            if !previewWasWritten {
                writePreview(frame.pixelBuffer)
            }
        } else {
            droppedFrameCount += 1
        }
        writeMetadata(
            frame: frame,
            presentationTime: presentationTime,
            encoded: encoded,
            dropReason: encoded ? nil : "asset_writer_append_failed"
        )
        if !encoded, writer.status == .failed {
            errorMessage = writer.error?.localizedDescription
        }
    }

    func finish(
        completion: @escaping (UltrawideRecordingSummary) -> Void
    ) {
        finishCompletion = completion
        guard let writer, let writerInput else {
            completeFinalization(completed: false)
            return
        }
        guard firstTimestamp != nil else {
            writer.cancelWriting()
            completeFinalization(completed: false)
            return
        }
        writerInput.markAsFinished()
        guard writer.status == .writing else {
            completeFinalization(completed: false)
            return
        }
        writer.finishWriting { [weak self] in
            guard let self else {
                completion(.unavailable)
                return
            }
            let completed = writer.status == .completed
                && self.encodedFrameCount > 0
            if completed {
                do {
                    try self.promoteCompletedArtifacts()
                } catch {
                    self.completeFinalization(
                        completed: false,
                        errorOverride: error.localizedDescription
                    )
                    return
                }
            }
            self.completeFinalization(
                completed: completed,
                errorOverride: completed
                    ? nil
                    : writer.error?.localizedDescription
                        ?? "0.5x video did not finalize."
            )
        }
    }

    func cancelAndFinish(reason: String) {
        if writer?.status == .writing {
            writer?.cancelWriting()
        }
        completeFinalization(
            completed: false,
            errorOverride: reason
        )
    }

    private func completeFinalization(
        completed: Bool,
        errorOverride: String? = nil
    ) {
        finalizationGate.performOnce { [self] in
            if let errorOverride {
                errorMessage = errorOverride
            }
            closeFramesHandle()
            if let pool = adaptor?.pixelBufferPool {
                CVPixelBufferPoolFlush(pool, .excessBuffers)
            }
            ciContext.clearCaches()
            writerInput = nil
            adaptor = nil
            writer = nil
            let completion = finishCompletion
            finishCompletion = nil
            completion?(summary(completed: completed))
        }
    }

    private func configureIfNeeded(
        frame: UltrawideRecordingFrame
    ) throws {
        guard writer == nil else {
            return
        }
        let observation = frame.boundObservation.observation
        let configuredWriter = try AVAssetWriter(
            outputURL: videoWritingURL,
            fileType: .mp4
        )
        let outputSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: observation.width,
            AVVideoHeightKey: observation.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitRate,
                AVVideoExpectedSourceFrameRateKey:
                    nominalFramesPerSecond,
                AVVideoMaxKeyFrameIntervalKey:
                    nominalFramesPerSecond
            ]
        ]
        let configuredInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: outputSettings
        )
        configuredInput.expectsMediaDataInRealTime = true
        guard configuredWriter.canAdd(configuredInput) else {
            throw UltrawideWriterError.cannotAddInput
        }
        configuredWriter.add(configuredInput)
        let configuredAdaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: configuredInput,
            sourcePixelBufferAttributes: nil
        )
        guard configuredWriter.startWriting() else {
            throw configuredWriter.error
                ?? UltrawideWriterError.cannotStartWriting
        }
        configuredWriter.startSession(atSourceTime: .zero)
        writer = configuredWriter
        writerInput = configuredInput
        adaptor = configuredAdaptor
        firstTimestamp = observation.timestamp
        width = observation.width
        height = observation.height
        firstFrameIntrinsics = matrixRows(observation.intrinsics)
    }

    private func makePresentationTime(timestamp: TimeInterval) -> CMTime {
        CMTime(
            seconds: max(0, timestamp - (firstTimestamp ?? timestamp)),
            preferredTimescale: 60_000
        )
    }

    private func recordDrop(
        frame: UltrawideRecordingFrame,
        presentationTime: CMTime? = nil,
        reason: String
    ) {
        droppedFrameCount += 1
        writeMetadata(
            frame: frame,
            presentationTime: presentationTime
                ?? makePresentationTime(
                    timestamp: frame.boundObservation
                        .observation.timestamp
                ),
            encoded: false,
            dropReason: reason
        )
    }

    private func writeMetadata(
        frame: UltrawideRecordingFrame,
        presentationTime: CMTime,
        encoded: Bool,
        dropReason: String?
    ) {
        let bound = frame.boundObservation
        let observation = bound.observation
        let row = UltrawideFrameMetadata(
            schemaVersion: 1,
            frameIndex: frameIndex,
            dataKey: dataKey,
            width: observation.width,
            height: observation.height,
            ultrawideTimestampSeconds: observation.timestamp,
            matchedARKitTimestampSeconds: bound.matchedARKitTimestamp,
            poseMatchDeltaSeconds: bound.poseMatchDelta,
            mp4PresentationTimeSeconds: presentationTime.seconds,
            cameraIntrinsics: matrixRows(observation.intrinsics),
            cameraPose: matrixRows(bound.cameraPose),
            cameraWorldTransform: matrixRows(
                observation.worldTransform
            ),
            interfaceOrientation: frame.interfaceOrientation,
            encoded: encoded,
            dropReason: dropReason
        )
        frameIndex += 1
        do {
            var data = try encoder.encode(row)
            data.append(0x0A)
            try framesHandle.write(contentsOf: data)
        } catch {
            errorMessage = "Could not append ultrawide_frames.jsonl: "
                + error.localizedDescription
        }
    }

    private func writePreview(_ pixelBuffer: CVPixelBuffer) {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = ciContext.createCGImage(
            image,
            from: image.extent
        ),
        let data = UIImage(cgImage: cgImage)
            .jpegData(compressionQuality: 0.92) else {
            errorMessage = "Could not render 0.5x preview image."
            return
        }
        do {
            try data.write(to: previewWritingURL, options: .atomic)
            previewWasWritten = true
        } catch {
            errorMessage = "Could not write 0.5x preview image: "
                + error.localizedDescription
        }
    }

    private func promoteCompletedArtifacts() throws {
        let fileManager = FileManager.default
        let videoURL = directoryURL.appendingPathComponent(
            Self.videoFilename
        )
        let framesURL = directoryURL.appendingPathComponent(
            Self.framesFilename
        )
        try fileManager.moveItem(at: videoWritingURL, to: videoURL)
        try fileManager.moveItem(at: framesWritingURL, to: framesURL)
        if previewWasWritten {
            let previewURL = directoryURL.appendingPathComponent(
                Self.previewFilename
            )
            try fileManager.moveItem(
                at: previewWritingURL,
                to: previewURL
            )
        }
    }

    private func closeFramesHandle() {
        try? framesHandle.synchronize()
        try? framesHandle.close()
    }

    private func summary(completed: Bool) -> UltrawideRecordingSummary {
        UltrawideRecordingSummary(
            videoFilename: completed ? Self.videoFilename : nil,
            framesMetadataFilename: completed
                ? Self.framesFilename
                : nil,
            previewFilename: completed && previewWasWritten
                ? Self.previewFilename
                : nil,
            width: width,
            height: height,
            encodedFrameCount: encodedFrameCount,
            droppedFrameCount: droppedFrameCount,
            firstFrameIntrinsics: firstFrameIntrinsics,
            errorMessage: errorMessage
        )
    }

    private func matrixRows(_ matrix: simd_float3x3) -> [[Float]] {
        (0..<3).map { row in
            (0..<3).map { column in matrix[column][row] }
        }
    }

    private func matrixRows(_ matrix: simd_float4x4) -> [[Float]] {
        (0..<4).map { row in
            (0..<4).map { column in matrix[column][row] }
        }
    }
}

private enum UltrawideWriterError: LocalizedError {
    case cannotAddInput
    case cannotStartWriting

    var errorDescription: String? {
        switch self {
        case .cannotAddInput:
            return "AVAssetWriter rejected the 0.5x video input."
        case .cannotStartWriting:
            return "AVAssetWriter could not start ultrawide_rgb.mp4."
        }
    }
}
