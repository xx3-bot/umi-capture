import ARKit
import AVFoundation
import CoreImage
import Foundation
import VideoToolbox

final class RGBVideoRecorder {
    var onStatusChange: ((RGBRecorderStatus) -> Void)?
    var onRecordingFinalized: ((URL) -> Void)?

    private struct WriterComponents {
        let writer: AVAssetWriter
        let input: AVAssetWriterInput
        let adaptor: AVAssetWriterInputPixelBufferAdaptor
    }

    private struct RecordingContext {
        let recordingUUID: UUID
        let startedAtUnixMs: Int64
        let directoryURL: URL
        let videoURL: URL
        let umiVideoURL: URL
        let infoURL: URL
        let framesURL: URL
        let framesHandle: FileHandle
        let configuration: RGBRecordingConfiguration
        let writer: AVAssetWriter?
        let writerInput: AVAssetWriterInput?
        let adaptor: AVAssetWriterInputPixelBufferAdaptor?
        let umiWriter: AVAssetWriter?
        let umiWriterInput: AVAssetWriterInput?
        let umiAdaptor: AVAssetWriterInputPixelBufferAdaptor?
        var hasStartedSession = false
        var firstFrameTimestamp: TimeInterval?
        var lastPresentationTime = CMTime.invalid
        var firstFrameIntrinsics: [[Float]]?
        var firstFrameUMIIntrinsics: [[Float]]?
        var lastEncodedFrameTimestamp: TimeInterval?
        var frameIndex = 0
        var umiEncodedFrames = 0
        var umiDroppedFrames = 0
        var ultrawideWriter: UltrawideRecordingWriter?
    }

    private final class UltrawideSummaryBox {
        var value: UltrawideRecordingSummary = .unavailable
    }

    private enum WriterState {
        case idle
        case recording(RecordingContext)
        case finishing
    }

    private let writerQueue = DispatchQueue(
        label: "com.umicapture.rgb-video-writer",
        qos: .userInitiated
    )
    private let frameSlot = DispatchSemaphore(value: 1)
    private let admissionLock = NSLock()
    private let metricsLock = NSLock()
    private let ciContext = CIContext(options: [
        .cacheIntermediates: false
    ])
    private let frameEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private var writerState: WriterState = .idle
    private var pendingStartConfiguration:
        RGBRecordingConfiguration?
    private var acceptingFrames = false
    private var frameAdmissionState: RGBFrameAdmissionState?
    private var encodedFrames = 0
    private var droppedFrames = 0
    private var latestVideoURL: URL?
    private var latestErrorMessage: String?
    private var finishCompletions: [(URL?) -> Void] = []
    private var activeFinishDeadline: DispatchWorkItem?

    func start(
        configuration: RGBRecordingConfiguration
    ) {
        writerQueue.async { [weak self] in
            self?.startOnWriterQueue(
                configuration: configuration
            )
        }
    }

    func append(
        frame: ARFrame,
        cameraPose: simd_float4x4,
        trackingState: String,
        interfaceOrientation: String,
        ultrawideFrame: UltrawideRecordingFrame? = nil
    ) {
        guard let retainMainImage = reserveMainImageIfAccepting(
            timestamp: frame.timestamp
        ) else {
            return
        }

        let input = RGBFrameInput(
            pixelBuffer: retainMainImage ? frame.capturedImage : nil,
            descriptor: RGBFrameDescriptor(
                timestamp: frame.timestamp,
                intrinsics: frame.camera.intrinsics,
                cameraPose: cameraPose,
                trackingState: trackingState,
                interfaceOrientation: interfaceOrientation
            ),
            ultrawideFrame: ultrawideFrame
        )

        guard frameSlot.wait(timeout: .now()) == .success else {
            incrementDroppedFrames()
            // Never enqueue an unbounded backlog of ARFrame-owned buffers.
            // The aggregate dropped-frame count already records overload; a
            // delayed metadata row is not worth keeping an ARFrame-owned
            // CVPixelBuffer alive until the writer queue catches up.
            return
        }

        writerQueue.async { [weak self] in
            defer {
                self?.frameSlot.signal()
            }
            autoreleasepool {
                self?.appendOnWriterQueue(input: input)
            }
        }
    }

    func finish(
        reason: RGBRecordingFinishReason,
        completion: ((URL?) -> Void)? = nil
    ) {
        setAcceptingFrames(false)
        writerQueue.async { [weak self] in
            guard let self else {
                DispatchQueue.main.async {
                    completion?(nil)
                }
                return
            }
            if let completion {
                self.finishCompletions.append(completion)
            }
            self.finishOnWriterQueue(reason: reason)
        }
    }

    func releaseTransientCaches() {
        writerQueue.async { [weak self] in
            self?.releaseTransientResourcesOnWriterQueue()
        }
    }

    func resetAndReleaseTransientResources() {
        setAcceptingFrames(false)
        writerQueue.async { [weak self] in
            guard let self else { return }
            // A Reset supersedes any Start that was queued while the previous
            // AVAssetWriter was still finishing. A later operator Start will
            // enqueue a fresh configuration after this reset barrier.
            self.pendingStartConfiguration = nil
            self.releaseTransientResourcesOnWriterQueue()
        }
    }

    private func startOnWriterQueue(
        configuration: RGBRecordingConfiguration
    ) {
        switch writerState {
        case .recording:
            return
        case .finishing:
            pendingStartConfiguration = configuration
            return
        case .idle:
            break
        }

        // This runs on the same serial queue that owns every writer. It is a
        // hard ordering barrier: no new AVAssetWriter or pixel-buffer pool is
        // created until transient resources from the previous capture have
        // been released.
        releaseTransientResourcesOnWriterQueue()
        resetMetrics()
        latestErrorMessage = nil
        let recordingUUID = UUID()
        var failedDirectoryURL: URL?
        var openedFramesHandle: FileHandle?
        var writersToCancel: [AVAssetWriter] = []

        do {
            let directoryURL = try makeRecordingDirectory(
                recordingUUID: recordingUUID
            )
            failedDirectoryURL = directoryURL
            let videoURL = directoryURL.appendingPathComponent(
                "rgb.mp4"
            )
            let umiVideoURL = directoryURL.appendingPathComponent(
                "ego_rgb_224.mp4"
            )
            let infoURL = directoryURL.appendingPathComponent(
                "recording_info.json"
            )
            let framesURL = directoryURL.appendingPathComponent(
                "frames.jsonl"
            )
            FileManager.default.createFile(
                atPath: framesURL.path,
                contents: nil
            )
            let framesHandle = try FileHandle(
                forWritingTo: framesURL
            )
            openedFramesHandle = framesHandle
            let effectiveFPS = configuration.recordingFrameRate
                .effectiveFramesPerSecond(
                    sourceFramesPerSecond:
                        configuration.format.framesPerSecond
                )
            let streamPlan = RecorderStreamPlan(
                configuration: configuration
            )
            let rawComponents: WriterComponents?
            if streamPlan.requiresRawWriter {
                rawComponents = try makeWriterComponents(
                    outputURL: videoURL,
                    width: configuration.format.width,
                    height: configuration.format.height,
                    framesPerSecond: effectiveFPS,
                    bitRate: configuration.recordingQuality
                        .rawVideoBitRate,
                    pixelBufferAttributes: nil,
                    trackTransform: configuration
                        .umiPreprocessing.rawVideoTrackTransform
                )
                writersToCancel.append(rawComponents!.writer)
            } else {
                rawComponents = nil
            }
            let umiComponents: WriterComponents?
            if streamPlan.requiresProcessedWriter {
                let umiAttributes: [String: Any] = [
                    kCVPixelBufferPixelFormatTypeKey as String:
                        kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey as String: 224,
                    kCVPixelBufferHeightKey as String: 224,
                    kCVPixelBufferIOSurfacePropertiesKey as String: [:]
                ]
                umiComponents = try makeWriterComponents(
                    outputURL: umiVideoURL,
                    width: 224,
                    height: 224,
                    framesPerSecond: effectiveFPS,
                    bitRate: configuration.recordingQuality
                        .umiVideoBitRate,
                    pixelBufferAttributes: umiAttributes,
                    trackTransform: .identity
                )
                writersToCancel.append(umiComponents!.writer)
            } else {
                umiComponents = nil
            }

            if let rawComponents,
               !rawComponents.writer.startWriting() {
                throw rawComponents.writer.error
                    ?? RecorderError.cannotStartWriting
            }
            if let umiComponents,
               !umiComponents.writer.startWriting() {
                rawComponents?.writer.cancelWriting()
                throw umiComponents.writer.error
                    ?? RecorderError.cannotStartUMIWriting
            }
            writerState = .recording(
                RecordingContext(
                    recordingUUID: recordingUUID,
                    startedAtUnixMs:
                        CaptureLibraryDate.unixMilliseconds(),
                    directoryURL: directoryURL,
                    videoURL: videoURL,
                    umiVideoURL: umiVideoURL,
                    infoURL: infoURL,
                    framesURL: framesURL,
                    framesHandle: framesHandle,
                    configuration: configuration,
                    writer: rawComponents?.writer,
                    writerInput: rawComponents?.input,
                    adaptor: rawComponents?.adaptor,
                    umiWriter: umiComponents?.writer,
                    umiWriterInput: umiComponents?.input,
                    umiAdaptor: umiComponents?.adaptor,
                    ultrawideWriter: nil
                )
            )
            failedDirectoryURL = nil
            openedFramesHandle = nil
            writersToCancel.removeAll()
            beginAcceptingFrames(
                targetFramesPerSecond: effectiveFPS,
                sourceFramesPerSecond:
                    configuration.format.framesPerSecond,
                retainsMainCameraImage:
                    streamPlan.retainsMainCameraImage
            )
            publishStatus(phase: .recording)
        } catch {
            writersToCancel.forEach {
                $0.cancelWriting()
            }
            try? openedFramesHandle?.close()
            if let failedDirectoryURL {
                try? FileManager.default.removeItem(
                    at: failedDirectoryURL
                )
            }
            latestErrorMessage = error.localizedDescription
            writerState = .idle
            setAcceptingFrames(false)
            publishStatus(phase: .failed)
        }
    }

    private func makeWriterComponents(
        outputURL: URL,
        width: Int,
        height: Int,
        framesPerSecond: Int,
        bitRate: Int,
        pixelBufferAttributes: [String: Any]?,
        trackTransform: CGAffineTransform
    ) throws -> WriterComponents {
        let writer = try AVAssetWriter(
            outputURL: outputURL,
            fileType: .mp4
        )
        let outputSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitRate,
                AVVideoExpectedSourceFrameRateKey:
                    framesPerSecond,
                AVVideoMaxKeyFrameIntervalKey:
                    framesPerSecond,
                AVVideoAllowFrameReorderingKey: false,
                AVVideoProfileLevelKey:
                    kVTProfileLevel_HEVC_Main_AutoLevel
            ]
        ]
        guard writer.canApply(
            outputSettings: outputSettings,
            forMediaType: .video
        ) else {
            throw RecorderError.unsupportedHEVCSettings
        }

        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: outputSettings
        )
        input.transform = trackTransform
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else {
            throw RecorderError.cannotAddWriterInput
        }
        writer.add(input)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: pixelBufferAttributes
        )
        return WriterComponents(
            writer: writer,
            input: input,
            adaptor: adaptor
        )
    }

    private func appendOnWriterQueue(
        input: RGBFrameInput
    ) {
        guard case .recording(var context) = writerState else {
            return
        }

        if let writer = context.writer,
           writer.status != .writing {
            handleWriterFailure(
                context: context,
                error: writer.error
                    ?? RecorderError.writerNotWriting
            )
            return
        }
        if let umiWriter = context.umiWriter,
           umiWriter.status != .writing {
            handleWriterFailure(
                context: context,
                error: umiWriter.error
                    ?? RecorderError.writerNotWriting
            )
            return
        }

        if let pixelBuffer = input.pixelBuffer {
            let actualWidth = CVPixelBufferGetWidth(pixelBuffer)
            let actualHeight = CVPixelBufferGetHeight(pixelBuffer)
            guard actualWidth
                    == context.configuration.format.width,
                  actualHeight
                    == context.configuration.format.height
            else {
                handleWriterFailure(
                    context: context,
                    error:
                        RecorderError.pixelBufferDimensionMismatch(
                            expectedWidth:
                                context.configuration.format.width,
                            expectedHeight:
                                context.configuration.format.height,
                            actualWidth: actualWidth,
                            actualHeight: actualHeight
                        )
                )
                return
            }
        }

        startSessionsIfNeeded(
            context: &context,
            input: input
        )
        if context.configuration.includeUltrawideObservation {
            appendUltrawideIfPresent(
                input.ultrawideFrame,
                context: &context
            )
        }
        let presentationTime = makePresentationTime(
            context: context,
            timestamp: input.descriptor.timestamp
        )

        guard !context.lastPresentationTime.isValid
                || CMTimeCompare(
                    presentationTime,
                    context.lastPresentationTime
                ) > 0
        else {
            incrementDroppedFrames()
            context.umiDroppedFrames += 1
            writeFrameMetadata(
                context: &context,
                descriptor: input.descriptor,
                presentationTime: presentationTime,
                encoded: false,
                umiEncoded: false,
                dropReason: "non_increasing_pts"
            )
            writerState = .recording(context)
            return
        }

        guard let pixelBuffer = input.pixelBuffer else {
            writeFrameMetadata(
                context: &context,
                descriptor: input.descriptor,
                presentationTime: presentationTime,
                encoded: false,
                umiEncoded: false,
                dropReason: "recording_frame_rate_limit"
            )
            writerState = .recording(context)
            return
        }

        let rawReady = context.writerInput?.isReadyForMoreMediaData
            ?? true
        let umiReady = context.umiWriterInput?.isReadyForMoreMediaData
            ?? true
        guard rawReady, umiReady
        else {
            incrementDroppedFrames()
            context.umiDroppedFrames += 1
            context.lastPresentationTime = presentationTime
            writeFrameMetadata(
                context: &context,
                descriptor: input.descriptor,
                presentationTime: presentationTime,
                encoded: false,
                umiEncoded: false,
                dropReason: "writer_not_ready"
            )
            writerState = .recording(context)
            return
        }

        let encoded = context.adaptor?.append(
            pixelBuffer,
            withPresentationTime: presentationTime
        ) ?? false
        let umiEncoded: Bool
        if let umiAdaptor = context.umiAdaptor {
            guard let umiPixelBuffer = makeUMIPixelBuffer(
                pixelBuffer,
                context: context
            ) else {
                incrementDroppedFrames()
                context.umiDroppedFrames += 1
                context.lastPresentationTime = presentationTime
                writeFrameMetadata(
                    context: &context,
                    descriptor: input.descriptor,
                    presentationTime: presentationTime,
                    encoded: encoded,
                    umiEncoded: false,
                    dropReason: "umi_preprocessing_failed"
                )
                writerState = .recording(context)
                return
            }
            umiEncoded = umiAdaptor.append(
                umiPixelBuffer,
                withPresentationTime: presentationTime
            )
        } else {
            umiEncoded = false
        }

        if context.writer != nil {
            if encoded {
                incrementEncodedFrames()
            } else {
                incrementDroppedFrames()
            }
        }
        if context.umiWriter == nil || umiEncoded {
            if umiEncoded {
                context.umiEncodedFrames += 1
            }
        } else {
            context.umiDroppedFrames += 1
        }
        let enabledWritersSucceeded =
            (context.writer == nil || encoded)
            && (context.umiWriter == nil || umiEncoded)
        if enabledWritersSucceeded {
            context.lastEncodedFrameTimestamp =
                input.descriptor.timestamp
        }

        context.lastPresentationTime = presentationTime
        writeFrameMetadata(
            context: &context,
            descriptor: input.descriptor,
            presentationTime: presentationTime,
            encoded: encoded,
            umiEncoded: umiEncoded,
            dropReason: enabledWritersSucceeded
                ? nil
                : "asset_writer_append_failed"
        )

        if let writer = context.writer,
           !encoded,
           writer.status == .failed {
            handleWriterFailure(
                context: context,
                error: writer.error
                    ?? RecorderError.cannotAppendPixelBuffer
            )
            return
        }
        if let umiWriter = context.umiWriter,
           !umiEncoded,
           umiWriter.status == .failed {
            handleWriterFailure(
                context: context,
                error: umiWriter.error
                    ?? RecorderError.cannotAppendPixelBuffer
            )
            return
        }
        writerState = .recording(context)
    }

    private func appendUltrawideIfPresent(
        _ frame: UltrawideRecordingFrame?,
        context: inout RecordingContext
    ) {
        guard let frame else {
            return
        }
        if context.ultrawideWriter == nil {
            do {
                context.ultrawideWriter = try UltrawideRecordingWriter(
                    directoryURL: context.directoryURL,
                    nominalFramesPerSecond: min(
                        10,
                        context.configuration.recordingFrameRate
                            .effectiveFramesPerSecond(
                                sourceFramesPerSecond:
                                    context.configuration.format
                                        .framesPerSecond
                            )
                    ),
                    bitRate: context.configuration.recordingQuality
                        .ultrawideVideoBitRate,
                    dataKey: CaptureDataKey.ultrawide(
                        for: context.configuration.captureProfile
                    )
                )
            } catch {
                latestErrorMessage =
                    "Could not prepare 0.5x recording: "
                    + error.localizedDescription
                return
            }
        }
        context.ultrawideWriter?.append(frame)
    }

    private func startSessionsIfNeeded(
        context: inout RecordingContext,
        input: RGBFrameInput
    ) {
        startSessionsIfNeeded(
            context: &context,
            descriptor: input.descriptor
        )
    }

    private func startSessionsIfNeeded(
        context: inout RecordingContext,
        descriptor: RGBFrameDescriptor
    ) {
        guard context.firstFrameTimestamp == nil else {
            return
        }
        context.firstFrameTimestamp = descriptor.timestamp
        context.firstFrameIntrinsics = intrinsicsRows(
            descriptor.intrinsics
        )
        context.firstFrameUMIIntrinsics =
            context.configuration.umiPreprocessing
                .transformedIntrinsics(descriptor.intrinsics)
        context.writer?.startSession(atSourceTime: .zero)
        context.umiWriter?.startSession(atSourceTime: .zero)
        context.hasStartedSession = true
    }

    private func makePresentationTime(
        context: RecordingContext,
        timestamp: TimeInterval
    ) -> CMTime {
        CMTime(
            seconds: max(
                0,
                timestamp
                    - (context.firstFrameTimestamp ?? timestamp)
            ),
            preferredTimescale: 60_000
        )
    }

    private func makeUMIPixelBuffer(
        _ source: CVPixelBuffer,
        context: RecordingContext
    ) -> CVPixelBuffer? {
        guard let pool = context.umiAdaptor?.pixelBufferPool else {
            latestErrorMessage =
                RecorderError.missingUMIPixelBufferPool
                    .localizedDescription
            return nil
        }
        var output: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(
            nil,
            pool,
            &output
        ) == kCVReturnSuccess,
        let output
        else {
            return nil
        }

        let preprocessing =
            context.configuration.umiPreprocessing
        let cropRect = CGRect(
            x: preprocessing.cropX,
            y: preprocessing.cropY,
            width: preprocessing.cropWidth,
            height: preprocessing.cropHeight
        )
        let scaledImage = CIImage(cvPixelBuffer: source)
            .cropped(to: cropRect)
            .transformed(
                by: CGAffineTransform(
                    translationX: -cropRect.minX,
                    y: -cropRect.minY
                )
            )
            .transformed(
                by: CGAffineTransform(
                    scaleX: CGFloat(preprocessing.outputWidth)
                        / cropRect.width,
                    y: CGFloat(preprocessing.outputHeight)
                        / cropRect.height
                )
            )
        let orientedImage = scaledImage.oriented(
            preprocessing.imageOrientation
        )
        let image = orientedImage
            .transformed(
                by: CGAffineTransform(
                    translationX: -orientedImage.extent.minX,
                    y: -orientedImage.extent.minY
                )
            )
            .cropped(
                to: CGRect(
                    x: 0,
                    y: 0,
                    width: preprocessing.outputWidth,
                    height: preprocessing.outputHeight
                )
            )
        ciContext.render(
            image,
            to: output,
            bounds: CGRect(
                x: 0,
                y: 0,
                width: preprocessing.outputWidth,
                height: preprocessing.outputHeight
            ),
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        return output
    }

    private func writeFrameMetadata(
        context: inout RecordingContext,
        descriptor: RGBFrameDescriptor,
        presentationTime: CMTime,
        encoded: Bool,
        umiEncoded: Bool,
        dropReason: String?
    ) {
        let record = RGBFrameMetadata(
            schemaVersion: 2,
            frameIndex: context.frameIndex,
            dataKey: CaptureDataKey.main(
                for: context.configuration.captureProfile
            ),
            lensMode:
                context.configuration.format.cameraMode,
            physicalCameraType:
                context.configuration.format.physicalCameraType,
            width: context.configuration.format.width,
            height: context.configuration.format.height,
            arkitTimestampSeconds: descriptor.timestamp,
            mp4PresentationTimeSeconds:
                presentationTime.seconds,
            arkitCameraIntrinsics:
                intrinsicsRows(descriptor.intrinsics),
            umi224CameraIntrinsics:
                context.configuration.umiPreprocessing
                    .transformedIntrinsics(
                        descriptor.intrinsics
                    ),
            empiricalCalibrationProfileID:
                context.configuration
                    .empiricalCalibration.profileID,
            empiricalCalibration:
                context.configuration.empiricalCalibration,
            cameraPose: matrixRows(descriptor.cameraPose),
            trackingState: descriptor.trackingState,
            interfaceOrientation:
                descriptor.interfaceOrientation,
            encoded: encoded,
            umi224Encoded: umiEncoded,
            dropReason: dropReason
        )
        context.frameIndex += 1
        do {
            var data = try frameEncoder.encode(record)
            data.append(0x0A)
            try context.framesHandle.write(
                contentsOf: data
            )
        } catch {
            latestErrorMessage =
                "Could not append frames.jsonl: "
                + error.localizedDescription
        }
    }

    private func finishOnWriterQueue(
        reason: RGBRecordingFinishReason
    ) {
        guard case .recording(let context) = writerState else {
            if case .idle = writerState {
                runFinishCompletions(videoURL: nil)
            }
            return
        }
        writerState = .finishing
        publishStatus(phase: .finishing)

        guard context.hasStartedSession else {
            context.writer?.cancelWriting()
            context.umiWriter?.cancelWriting()
            finishUltrawide(context: context) { [weak self] summary in
                self?.finalize(
                    context: context,
                    reason: reason.rawValue + "_no_frames",
                    videoIsPlayable: false,
                    umiVideoIsPlayable: false,
                    ultrawideSummary: summary,
                    error: nil
                )
            }
            return
        }

        context.writerInput?.markAsFinished()
        context.umiWriterInput?.markAsFinished()
        let group = DispatchGroup()
        if context.writer?.status == .writing {
            group.enter()
            context.writer?.finishWriting {
                group.leave()
            }
        }
        if context.umiWriter?.status == .writing {
            group.enter()
            context.umiWriter?.finishWriting {
                group.leave()
            }
        }
        let ultrawideSummary = UltrawideSummaryBox()
        if let ultrawideWriter = context.ultrawideWriter {
            group.enter()
            ultrawideWriter.finish { summary in
                ultrawideSummary.value = summary
                group.leave()
            }
        }
        let completionGate = CaptureCompletionGate()
        let deadline = DispatchWorkItem { [weak self] in
            guard let self else { return }
            completionGate.performOnce {
                if context.writer?.status == .writing {
                    context.writer?.cancelWriting()
                }
                if context.umiWriter?.status == .writing {
                    context.umiWriter?.cancelWriting()
                }
                context.ultrawideWriter?.cancelAndFinish(
                    reason: "writer_finish_timeout"
                )
                self.activeFinishDeadline = nil
                self.finalize(
                    context: context,
                    reason: "writer_finish_timeout",
                    videoIsPlayable:
                        context.writer?.status == .completed,
                    umiVideoIsPlayable:
                        context.umiWriter?.status == .completed,
                    ultrawideSummary: .failed(
                        reason: "writer_finish_timeout"
                    ),
                    error: RecorderError.writerFinishTimedOut
                )
            }
        }
        activeFinishDeadline?.cancel()
        activeFinishDeadline = deadline
        writerQueue.asyncAfter(
            deadline: .now()
                + CaptureFinalizationDeadlines.writerSeconds,
            execute: deadline
        )
        group.notify(queue: writerQueue) { [weak self] in
            guard let self else {
                return
            }
            completionGate.performOnce {
                deadline.cancel()
                self.activeFinishDeadline = nil
                let rawSucceeded =
                    context.writer == nil
                    || context.writer?.status == .completed
                let umiSucceeded =
                    context.umiWriter == nil
                    || context.umiWriter?.status == .completed
                let rawPlayable = context.writer?.status == .completed
                let umiPlayable = context.umiWriter?.status == .completed
                self.finalize(
                    context: context,
                    reason: rawSucceeded && umiSucceeded
                        ? reason.rawValue
                        : RGBRecordingFinishReason
                            .writerFailure.rawValue,
                    videoIsPlayable: rawPlayable,
                    umiVideoIsPlayable: umiPlayable,
                    ultrawideSummary: ultrawideSummary.value,
                    error: rawSucceeded
                        ? (
                            umiSucceeded
                                ? nil
                                : context.umiWriter?.error
                        )
                        : context.writer?.error
                )
            }
        }
    }

    private func handleWriterFailure(
        context: RecordingContext,
        error: Error
    ) {
        setAcceptingFrames(false)
        context.writer?.cancelWriting()
        context.umiWriter?.cancelWriting()
        writerState = .finishing
        finishUltrawide(context: context) { [weak self] summary in
            self?.finalize(
                context: context,
                reason:
                    RGBRecordingFinishReason.writerFailure.rawValue,
                videoIsPlayable: false,
                umiVideoIsPlayable: false,
                ultrawideSummary: summary,
                error: error
            )
        }
    }

    private func finishUltrawide(
        context: RecordingContext,
        completion: @escaping (UltrawideRecordingSummary) -> Void
    ) {
        guard let ultrawideWriter = context.ultrawideWriter else {
            completion(.unavailable)
            return
        }
        let completionGate = CaptureCompletionGate()
        ultrawideWriter.finish { [weak self] summary in
            self?.writerQueue.async {
                completionGate.performOnce {
                    completion(summary)
                }
            }
        }
        writerQueue.asyncAfter(
            deadline: .now()
                + CaptureFinalizationDeadlines.writerSeconds
        ) {
            completionGate.performOnce {
                ultrawideWriter.cancelAndFinish(
                    reason: "writer_finish_timeout"
                )
                completion(.failed(reason: "writer_finish_timeout"))
            }
        }
    }

    private func finalize(
        context: RecordingContext,
        reason: String,
        videoIsPlayable: Bool,
        umiVideoIsPlayable: Bool,
        ultrawideSummary: UltrawideRecordingSummary,
        error: Error?
    ) {
        activeFinishDeadline?.cancel()
        activeFinishDeadline = nil
        setAcceptingFrames(false)
        try? context.framesHandle.synchronize()
        try? context.framesHandle.close()
        let counts = metricCounts()
        let endedAtUnixMs =
            CaptureLibraryDate.unixMilliseconds()
        let info = RGBRecordingInfo(
            schemaVersion: 6,
            recordingUUID: context.recordingUUID.uuidString,
            width: context.configuration.format.width,
            height: context.configuration.format.height,
            nominalFPS:
                context.configuration.recordingFrameRate
                    .effectiveFramesPerSecond(
                        sourceFramesPerSecond:
                            context.configuration.format.framesPerSecond
                    ),
            codec: "HEVC/H.265",
            container: "MP4",
            encodedFrameCount: counts.encoded,
            droppedFrameCount: counts.dropped,
            finishReason: reason,
            firstFrameCameraIntrinsics:
                context.firstFrameIntrinsics,
            displayName: CaptureLibraryDate.displayRange(
                startUnixMs: context.startedAtUnixMs,
                endUnixMs: endedAtUnixMs
            ),
            startedAtUnixMs: context.startedAtUnixMs,
            endedAtUnixMs: endedAtUnixMs,
            dataKey: CaptureDataKey.main(
                for: context.configuration.captureProfile
            ),
            cameraRole: context.configuration.captureProfile?.captureRole
                == .wristUMI ? "wrist_umi_camera" : "chest_ego_camera",
            iPhoneModel:
                context.configuration.iPhoneModel,
            lensMode:
                context.configuration.format.cameraMode,
            physicalCameraType:
                context.configuration.format.physicalCameraType,
            fixedInterfaceOrientation:
                context.configuration
                    .captureStartInterfaceOrientation,
            captureStartInterfaceOrientation:
                context.configuration
                    .captureStartInterfaceOrientation,
            empiricalCalibration:
                context.configuration.empiricalCalibration,
            umiPreprocessing:
                context.configuration.umiPreprocessing,
            umiVideoFilename: umiVideoIsPlayable
                ? context.umiVideoURL.lastPathComponent
                : nil,
            framesMetadataFilename:
                context.framesURL.lastPathComponent,
            umiEncodedFrameCount:
                context.umiEncodedFrames,
            umiDroppedFrameCount:
                context.umiDroppedFrames,
            firstFrameUMI224Intrinsics:
                context.firstFrameUMIIntrinsics,
            umiPixelsPhysicallyUpright:
                UMICaptureOrientation.uprightRotationDegrees(
                    forMetadataValue: context.configuration
                        .captureStartInterfaceOrientation
                ) == context.configuration
                    .umiPreprocessing.rotationDegrees,
            rawVideoDisplayRotationDegrees:
                UMICaptureOrientation.uprightRotationDegrees(
                    forMetadataValue: context.configuration
                        .captureStartInterfaceOrientation
                ),
            ultrawideVideoFilename:
                ultrawideSummary.videoFilename,
            ultrawideFramesMetadataFilename:
                ultrawideSummary.framesMetadataFilename,
            ultrawidePreviewFilename:
                ultrawideSummary.previewFilename,
            ultrawideWidth: ultrawideSummary.width,
            ultrawideHeight: ultrawideSummary.height,
            ultrawideEncodedFrameCount:
                ultrawideSummary.encodedFrameCount,
            ultrawideDroppedFrameCount:
                ultrawideSummary.droppedFrameCount,
            firstFrameUltrawideIntrinsics:
                ultrawideSummary.firstFrameIntrinsics,
            ultrawideError: ultrawideSummary.errorMessage,
            gripperMarkerLayout:
                context.configuration.captureProfile?
                    .gripperMarkerLayout,
            captureProfile: context.configuration.captureProfile,
            captureCoordination: context.configuration.captureCoordination
        )

        var metadataWasWritten = false
        do {
            try writeRecordingInfo(
                info,
                to: context.infoURL
            )
            metadataWasWritten = true
        } catch {
            latestErrorMessage =
                "Could not write recording_info.json: "
                + error.localizedDescription
        }

        if videoIsPlayable,
           context.configuration.includeRawRGBVideo {
            latestVideoURL = context.videoURL
        }
        if let error {
            latestErrorMessage = error.localizedDescription
        }
        if !umiVideoIsPlayable {
            try? FileManager.default.removeItem(
                at: context.umiVideoURL
            )
        }

        if let pool = context.umiAdaptor?.pixelBufferPool {
            CVPixelBufferPoolFlush(pool, .excessBuffers)
        }
        releaseTransientResourcesOnWriterQueue()
        writerState = .idle
        publishStatus(
            phase: latestErrorMessage == nil
                ? .idle
                : .failed
        )
        runFinishCompletions(
            videoURL: videoIsPlayable
                && context.configuration.includeRawRGBVideo
                ? context.videoURL
                : (metadataWasWritten ? context.infoURL : nil)
        )
        if metadataWasWritten {
            DispatchQueue.main.async { [weak self] in
                self?.onRecordingFinalized?(
                    videoIsPlayable
                        && context.configuration.includeRawRGBVideo
                        ? context.videoURL
                        : context.infoURL
                )
            }
        }

        if let pendingStartConfiguration {
            self.pendingStartConfiguration = nil
            startOnWriterQueue(
                configuration: pendingStartConfiguration
            )
        }
    }

    private func releaseTransientResourcesOnWriterQueue() {
        ciContext.clearCaches()
    }

    private func makeRecordingDirectory(
        recordingUUID: UUID
    ) throws -> URL {
        let documentsURL = try FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let capturesURL = documentsURL.appendingPathComponent(
            "RGBCaptures",
            isDirectory: true
        )
        let directoryURL = capturesURL.appendingPathComponent(
            recordingUUID.uuidString,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        return directoryURL
    }

    private func writeRecordingInfo(
        _ info: RGBRecordingInfo,
        to url: URL
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(info)
        try data.write(to: url, options: .atomic)
    }

    private func intrinsicsRows(
        _ matrix: simd_float3x3
    ) -> [[Float]] {
        (0..<3).map { row in
            (0..<3).map { column in
                matrix[column][row]
            }
        }
    }

    private func matrixRows(
        _ matrix: simd_float4x4
    ) -> [[Float]] {
        (0..<4).map { row in
            (0..<4).map { column in
                matrix[column][row]
            }
        }
    }

    private func reserveMainImageIfAccepting(
        timestamp: TimeInterval
    ) -> Bool? {
        admissionLock.lock()
        defer {
            admissionLock.unlock()
        }
        guard acceptingFrames,
              var frameAdmissionState else {
            return nil
        }
        let result = frameAdmissionState.reserveMainImage(
            timestamp: timestamp
        )
        self.frameAdmissionState = frameAdmissionState
        return result
    }

    private func beginAcceptingFrames(
        targetFramesPerSecond: Int,
        sourceFramesPerSecond: Int,
        retainsMainCameraImage: Bool
    ) {
        admissionLock.lock()
        frameAdmissionState = RGBFrameAdmissionState(
            targetFramesPerSecond: targetFramesPerSecond,
            sourceFramesPerSecond: sourceFramesPerSecond,
            retainsMainCameraImage: retainsMainCameraImage
        )
        acceptingFrames = true
        admissionLock.unlock()
    }

    private func setAcceptingFrames(_ value: Bool) {
        admissionLock.lock()
        acceptingFrames = value
        if !value {
            frameAdmissionState = nil
        }
        admissionLock.unlock()
    }

    private func resetMetrics() {
        metricsLock.lock()
        encodedFrames = 0
        droppedFrames = 0
        metricsLock.unlock()
    }

    private func incrementEncodedFrames() {
        let shouldPublish: Bool
        metricsLock.lock()
        encodedFrames += 1
        shouldPublish = encodedFrames.isMultiple(of: 15)
        metricsLock.unlock()
        if shouldPublish {
            publishStatus(phase: .recording)
        }
    }

    private func incrementDroppedFrames() {
        let shouldPublish: Bool
        metricsLock.lock()
        droppedFrames += 1
        shouldPublish = droppedFrames.isMultiple(of: 5)
        metricsLock.unlock()
        if shouldPublish {
            publishStatus(phase: .recording)
        }
    }

    private func metricCounts() -> (
        encoded: Int,
        dropped: Int
    ) {
        metricsLock.lock()
        defer {
            metricsLock.unlock()
        }
        return (encodedFrames, droppedFrames)
    }

    private func publishStatus(
        phase: RGBRecorderPhase
    ) {
        let counts = metricCounts()
        let status = RGBRecorderStatus(
            phase: phase,
            encodedFrames: counts.encoded,
            droppedFrames: counts.dropped,
            latestVideoURL: latestVideoURL,
            errorMessage: latestErrorMessage
        )
        DispatchQueue.main.async { [weak self] in
            self?.onStatusChange?(status)
        }
    }

    private func runFinishCompletions(videoURL: URL?) {
        let completions = finishCompletions
        finishCompletions.removeAll()
        guard !completions.isEmpty else {
            return
        }
        DispatchQueue.main.async {
            completions.forEach { $0(videoURL) }
        }
    }
}

private enum RecorderError: LocalizedError {
    case unsupportedHEVCSettings
    case cannotAddWriterInput
    case cannotStartWriting
    case cannotStartUMIWriting
    case writerNotWriting
    case cannotAppendPixelBuffer
    case missingUMIPixelBufferPool
    case pixelBufferDimensionMismatch(
        expectedWidth: Int,
        expectedHeight: Int,
        actualWidth: Int,
        actualHeight: Int
    )
    case writerFinishTimedOut

    var errorDescription: String? {
        switch self {
        case .unsupportedHEVCSettings:
            return "This device cannot apply the requested HEVC settings."
        case .cannotAddWriterInput:
            return "AVAssetWriter rejected a HEVC video input."
        case .cannotStartWriting:
            return "AVAssetWriter could not start the raw MP4."
        case .cannotStartUMIWriting:
            return "AVAssetWriter could not start ego_rgb_224.mp4."
        case .writerNotWriting:
            return "The raw video writer stopped accepting frames."
        case .cannotAppendPixelBuffer:
            return "Could not append the ARKit camera pixel buffer."
        case .missingUMIPixelBufferPool:
            return "The 224×224 UMI pixel buffer pool is unavailable."
        case .pixelBufferDimensionMismatch(
            let expectedWidth,
            let expectedHeight,
            let actualWidth,
            let actualHeight
        ):
            return """
            ARKit pixel buffer is \(actualWidth)×\(actualHeight); \
            selected physical-lens format is \
            \(expectedWidth)×\(expectedHeight).
            """
        case .writerFinishTimedOut:
            return "Video writer finalization exceeded 12 seconds."
        }
    }
}
