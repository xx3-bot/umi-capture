import Foundation

struct RGBRecordingConfiguration {
    let format: SelectedARVideoFormat
    let iPhoneModel: String
    let captureStartInterfaceOrientation: String
    let empiricalCalibration: CameraCalibrationProfile
    let umiPreprocessing: UMIImagePreprocessing
    let recordingFrameRate: RGBRecordingFrameRate
    let recordingQuality: RGBRecordingQuality
    let includeRawRGBVideo: Bool
    let includeProcessedRGBVideo: Bool
    let includeUltrawideObservation: Bool
    let captureProfile: CaptureProfileSnapshot?
    let captureCoordination: ActiveCaptureCoordination?

    init(
        format: SelectedARVideoFormat,
        iPhoneModel: String,
        captureStartInterfaceOrientation: String,
        empiricalCalibration: CameraCalibrationProfile,
        umiPreprocessing: UMIImagePreprocessing,
        recordingFrameRate: RGBRecordingFrameRate = .fps60,
        recordingQuality: RGBRecordingQuality = .high,
        includeRawRGBVideo: Bool = true,
        includeProcessedRGBVideo: Bool = true,
        includeUltrawideObservation: Bool = true,
        captureProfile: CaptureProfileSnapshot? = nil,
        captureCoordination: ActiveCaptureCoordination? = nil
    ) {
        self.format = format
        self.iPhoneModel = iPhoneModel
        self.captureStartInterfaceOrientation =
            captureStartInterfaceOrientation
        self.empiricalCalibration = empiricalCalibration
        self.umiPreprocessing = umiPreprocessing
        self.recordingFrameRate = recordingFrameRate
        self.recordingQuality = recordingQuality
        self.includeRawRGBVideo = includeRawRGBVideo
        self.includeProcessedRGBVideo = includeProcessedRGBVideo
        self.includeUltrawideObservation = includeUltrawideObservation
        self.captureProfile = captureProfile
        self.captureCoordination = captureCoordination
    }
}

enum RGBRecordingFrameRate: Int, Codable, CaseIterable, Identifiable {
    case fps20 = 20
    case fps30 = 30
    case fps60 = 60

    var id: Int { rawValue }

    var displayLabel: String {
        "\(rawValue) FPS"
    }

    func effectiveFramesPerSecond(sourceFramesPerSecond: Int) -> Int {
        max(1, min(rawValue, sourceFramesPerSecond))
    }

    func admits(
        timestamp: TimeInterval,
        lastEncodedTimestamp: TimeInterval?,
        sourceFramesPerSecond: Int
    ) -> Bool {
        guard let lastEncodedTimestamp else {
            return true
        }
        let framesPerSecond = effectiveFramesPerSecond(
            sourceFramesPerSecond: sourceFramesPerSecond
        )
        let minimumInterval = 1.0 / Double(framesPerSecond)
        return timestamp - lastEncodedTimestamp
            >= minimumInterval - 0.000_5
    }
}

enum RGBRecordingQuality: String, Codable, CaseIterable, Identifiable {
    case compact
    case balanced
    case high

    var id: String { rawValue }

    var rawVideoBitRate: Int {
        switch self {
        case .compact:
            return 15_000_000
        case .balanced:
            return 30_000_000
        case .high:
            return 60_000_000
        }
    }

    var umiVideoBitRate: Int {
        switch self {
        case .compact:
            return 700_000
        case .balanced:
            return 1_200_000
        case .high:
            return 2_000_000
        }
    }

    var ultrawideVideoBitRate: Int {
        switch self {
        case .compact:
            return 2_000_000
        case .balanced:
            return 4_000_000
        case .high:
            return 8_000_000
        }
    }

    var bitRateSummary: String {
        "\(rawVideoBitRate / 1_000_000) Mbps"
    }
}

struct RGBRecordingInfo: Codable, Equatable {
    let schemaVersion: Int
    let recordingUUID: String
    let width: Int
    let height: Int
    let nominalFPS: Int
    let codec: String
    let container: String
    let encodedFrameCount: Int
    let droppedFrameCount: Int
    let finishReason: String
    let firstFrameCameraIntrinsics: [[Float]]?
    let displayName: String?
    let startedAtUnixMs: Int64?
    let endedAtUnixMs: Int64?
    let dataKey: String?
    let cameraRole: String?
    let iPhoneModel: String?
    let lensMode: RGBCameraMode?
    let physicalCameraType: String?
    let fixedInterfaceOrientation: String?
    let captureStartInterfaceOrientation: String?
    let empiricalCalibration: CameraCalibrationProfile?
    let umiPreprocessing: UMIImagePreprocessing?
    let umiVideoFilename: String?
    let framesMetadataFilename: String?
    let umiEncodedFrameCount: Int?
    let umiDroppedFrameCount: Int?
    let firstFrameUMI224Intrinsics: [[Float]]?
    var umiPixelsPhysicallyUpright: Bool? = nil
    var rawVideoDisplayRotationDegrees: Int? = nil
    var ultrawideVideoFilename: String? = nil
    var ultrawideFramesMetadataFilename: String? = nil
    var ultrawidePreviewFilename: String? = nil
    var ultrawideWidth: Int? = nil
    var ultrawideHeight: Int? = nil
    var ultrawideEncodedFrameCount: Int? = nil
    var ultrawideDroppedFrameCount: Int? = nil
    var firstFrameUltrawideIntrinsics: [[Float]]? = nil
    var ultrawideError: String? = nil
    var gripperMarkerLayout: String? = nil
    var captureProfile: CaptureProfileSnapshot? = nil
    var captureCoordination: ActiveCaptureCoordination? = nil

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case recordingUUID = "recording_uuid"
        case width
        case height
        case nominalFPS = "nominal_fps"
        case codec
        case container
        case encodedFrameCount = "encoded_frame_count"
        case droppedFrameCount = "dropped_frame_count"
        case finishReason = "finish_reason"
        case firstFrameCameraIntrinsics = "first_frame_camera_intrinsics"
        case displayName = "display_name"
        case startedAtUnixMs = "started_at_unix_ms"
        case endedAtUnixMs = "ended_at_unix_ms"
        case dataKey = "data_key"
        case cameraRole = "camera_role"
        case iPhoneModel = "iphone_model"
        case lensMode = "lens_mode"
        case physicalCameraType = "physical_camera_type"
        case fixedInterfaceOrientation =
            "fixed_interface_orientation"
        case captureStartInterfaceOrientation =
            "capture_start_interface_orientation"
        case empiricalCalibration =
            "empirical_calibration"
        case umiPreprocessing = "umi_preprocessing"
        case umiVideoFilename = "umi_video_filename"
        case framesMetadataFilename =
            "frames_metadata_filename"
        case umiEncodedFrameCount =
            "umi_encoded_frame_count"
        case umiDroppedFrameCount =
            "umi_dropped_frame_count"
        case firstFrameUMI224Intrinsics =
            "first_frame_umi_224_intrinsics"
        case umiPixelsPhysicallyUpright =
            "umi_pixels_physically_upright"
        case rawVideoDisplayRotationDegrees =
            "raw_video_display_rotation_degrees"
        case ultrawideVideoFilename =
            "ultrawide_video_filename"
        case ultrawideFramesMetadataFilename =
            "ultrawide_frames_metadata_filename"
        case ultrawidePreviewFilename =
            "ultrawide_preview_filename"
        case ultrawideWidth = "ultrawide_width"
        case ultrawideHeight = "ultrawide_height"
        case ultrawideEncodedFrameCount =
            "ultrawide_encoded_frame_count"
        case ultrawideDroppedFrameCount =
            "ultrawide_dropped_frame_count"
        case firstFrameUltrawideIntrinsics =
            "first_frame_ultrawide_intrinsics"
        case ultrawideError = "ultrawide_error"
        case gripperMarkerLayout = "gripper_marker_layout"
        case captureProfile = "capture_profile"
        case captureCoordination = "capture_coordination"
    }
}

enum RGBRecordingFinishReason: String {
    case stop
    case trackingLost = "tracking_lost"
    case appBackground = "app_background"
    case sessionInterrupted = "session_interrupted"
    case sessionFailure = "session_failure"
    case viewDisappeared = "view_disappeared"
    case userDisabled = "user_disabled"
    case reset
    case orientationChanged = "orientation_changed"
    case writerFailure = "writer_failure"
    case memoryPressure = "memory_pressure"
    case thermalCritical = "thermal_critical"
}

enum RGBRecorderPhase: String, Equatable {
    case idle
    case recording
    case finishing
    case failed
}

struct RGBRecorderStatus: Equatable {
    let phase: RGBRecorderPhase
    let encodedFrames: Int
    let droppedFrames: Int
    let latestVideoURL: URL?
    let errorMessage: String?

    static let idle = RGBRecorderStatus(
        phase: .idle,
        encodedFrames: 0,
        droppedFrames: 0,
        latestVideoURL: nil,
        errorMessage: nil
    )
}
