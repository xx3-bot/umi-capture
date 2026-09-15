import Foundation
import ARKit
import AVFoundation
import AVKit
import Combine
import CoreImage
import CryptoKit
import SceneKit
import simd

private enum CaptureStartOrigin: Equatable {
    case local
    case remote
}

private enum CoordinatedPreparationPhase: Equatable {
    case inactive
    case waitingForTracking
    case ready
}

private struct PendingFrameBoundaryTransition {
    let command: GroupCaptureCommand
    let localDeadlineNs: UInt64
}

private struct PendingCoordinatedCaptureUpload {
    let retryID: UUID
    let command: GroupCaptureCommand
    let actualLocalNs: UInt64
    let artifacts: CompletedCaptureArtifacts
    let references: [[String: Any]]
    let packageURL: URL
    let coordinationSnapshot: ActiveCaptureCoordination?
    let host: String
    let port: Int
    let pairingToken: String?
}

private struct CoordinatedCaptureUploadAuthorization: Equatable {
    let sessionID: String
    let generation: Int
}

struct CoordinatedCaptureUploadFileIdentity: Equatable {
    let filename: String
    let deviceID: String
    let platform: String
    let sizeBytes: UInt64
    let sha256: String

    init?(
        artifactReference: [String: Any],
        deviceID: String
    ) {
        guard let filename = artifactReference["name"] as? String,
              !filename.isEmpty,
              !filename.contains("/"),
              !filename.contains("\\"),
              !deviceID.isEmpty,
              let platform = artifactReference["platform"] as? String,
              platform == "iOS",
              let sizeBytes = Self.unsignedInteger(
                  artifactReference["size_bytes"]
              ),
              sizeBytes > 0,
              let sha256 = artifactReference["sha256"] as? String,
              sha256.range(
                  of: "^[0-9a-f]{64}$",
                  options: .regularExpression
              ) != nil
        else { return nil }
        self.filename = filename
        self.deviceID = deviceID
        self.platform = platform
        self.sizeBytes = sizeBytes
        self.sha256 = sha256
    }

    fileprivate init?(wireIdentity: [String: Any]) {
        guard Set(wireIdentity.keys) == Set([
            "filename", "device_id", "platform", "size_bytes", "sha256"
        ]),
              let filename = wireIdentity["filename"] as? String,
              !filename.isEmpty,
              !filename.contains("/"),
              !filename.contains("\\"),
              let deviceID = wireIdentity["device_id"] as? String,
              !deviceID.isEmpty,
              let platform = wireIdentity["platform"] as? String,
              platform == "iOS",
              let sizeBytes = Self.unsignedInteger(
                  wireIdentity["size_bytes"]
              ),
              sizeBytes > 0,
              let sha256 = wireIdentity["sha256"] as? String,
              sha256.range(
                  of: "^[0-9a-f]{64}$",
                  options: .regularExpression
              ) != nil
        else { return nil }
        self.filename = filename
        self.deviceID = deviceID
        self.platform = platform
        self.sizeBytes = sizeBytes
        self.sha256 = sha256
    }

    fileprivate static func unsignedInteger(_ value: Any?) -> UInt64? {
        if value is Bool { return nil }
        if let value = value as? UInt64 { return value }
        if let value = value as? UInt { return UInt64(value) }
        if let value = value as? Int, value >= 0 { return UInt64(value) }
        guard let number = value as? NSNumber else { return nil }
        return UInt64(number.stringValue)
    }
}

enum FrozenCoordinatedUploadGrantReplayPolicy {
    static func authorizes(
        grant: [String: Any],
        expectedSessionID: String,
        expectedGeneration: Int,
        expectedIdentity: CoordinatedCaptureUploadFileIdentity
    ) -> Bool {
        guard integer(grant["schema_version"]) == 1,
              grant["session_id"] as? String == expectedSessionID,
              integer(grant["generation"]) == expectedGeneration,
              grant["device_id"] as? String == expectedIdentity.deviceID,
              let wireIdentity = grant["file_identity"] as? [String: Any],
              let identity = CoordinatedCaptureUploadFileIdentity(
                  wireIdentity: wireIdentity
              )
        else { return false }
        return identity == expectedIdentity
    }

    private static func integer(_ value: Any?) -> Int? {
        if value is Bool { return nil }
        if let value = value as? Int { return value }
        guard let number = value as? NSNumber else { return nil }
        return Int(number.stringValue)
    }
}

class ViewController: UIViewController, ARSessionDelegate, ObservableObject {
    @Published var displayString: String = ""
    @Published var calibrationStatus: String = "Waiting for ARKit"
    @Published var isCalibrationReady: Bool = false
    @Published var isCalibrating: Bool = false
    @Published var isStarting: Bool = false
    @Published var isStreaming: Bool = false
    @Published var connectionState: SocketConnectionState = .disconnected
    @Published private(set) var captureProfileID: CaptureProfileID = {
        guard let raw = UserDefaults.standard.string(
            forKey: "UMICapture.captureProfileID"
        ) else { return .chestEGO }
        return CaptureProfileID(rawValue: raw) ?? .chestEGO
    }()
    @Published private(set) var captureRoleLocked = false
    @Published private(set) var groupCoordinationStatus = "Single-device mode"
    @Published private(set) var synchronizedCapturePhase:
        SynchronizedCapturePhase = .inactive {
        didSet {
            if oldValue != synchronizedCapturePhase,
               !EgoPreviewThumbnailPolicy.sessionAcceptsFrames(
                    phase: synchronizedCapturePhase
               ) {
                clearEgoPreviewState()
            }
        }
    }
    @Published private(set) var synchronizedMembershipInterrupted = false
    @Published private(set) var isSynchronizedCaptureController = false
    private var synchronizedCaptureUsesSharedDeviceControl = false
    @Published private(set) var synchronizedCaptureFallbackArtifacts:
        CompletedCaptureArtifacts?
    @Published private(set) var completedStandaloneCaptureArtifacts:
        CompletedCaptureArtifacts?
    @Published private(set) var captureUploadSuccessNotice:
        CaptureUploadSuccessNotice?
    @Published private(set) var egoPreviewImage: UIImage?
    @Published private(set) var egoPreviewLastReceivedLocalNs: UInt64?
    @Published private(set) var receiverIdentity: String?
    @Published var gripperID: String = UserDefaults.standard.string(
        forKey: "UMICapture.gripperID"
    ) ?? ""
    @Published var calibrationID: String = UserDefaults.standard.string(
        forKey: "UMICapture.captureCalibrationID"
    ) ?? ""
    // Every iOS capture client participates in group coordination. Keeping
    // this automatic prevents an old local preference from silently excluding
    // one phone; the Ubuntu bridge remains distinguishable because it reports
    // controller_capable=false in its own registration.
    @Published private(set) var controllerCapable: Bool = true
    @Published var autoRearmAfterCapture: Bool = false
    @Published var axisDirections: VIOAxisDirections?
    @Published var trajectorySamples: [TrajectoryPoseSample] = []
    @Published var rgbRecorderStatus: RGBRecorderStatus = .idle
    @Published private(set) var physicalMemoryMB = 0
    @Published private(set) var availableMemoryMB = 0
    @Published private(set) var safeGrowthBudgetMB = 0
    @Published private(set) var peakPhysicalMemoryMB = 0
    @Published private(set) var captureLoadLevel: CaptureLoadLevel = .normal
    @Published private(set) var thermalStateText = "Normal"
    @Published private(set) var captureFinalizationStage:
        CaptureFinalizationStage = .idle
    @Published var rgbVideoFormatDescription: String = "Selecting RGB format"
    @Published var rgbVideoFormatError: String?
    @Published private(set) var rgbRecordingFrameRate:
        RGBRecordingFrameRate = {
            let value = UserDefaults.standard.integer(
                forKey: "UMICapture.rgbRecordingFrameRate"
            )
            return RGBRecordingFrameRate(rawValue: value) ?? .fps60
        }()
    @Published private(set) var rgbRecordingQuality:
        RGBRecordingQuality = {
            guard let value = UserDefaults.standard.string(
                forKey: "UMICapture.rgbRecordingQuality"
            ) else {
                return .high
            }
            return RGBRecordingQuality(rawValue: value) ?? .high
        }()
    @Published private(set) var ultrawideObservationStatus:
        UltrawideObservationStatus = .checking
    @Published private(set) var availableRGBCameraModes: [RGBCameraMode] = [
        .wide1x
    ]
    @Published private(set) var rgbCameraMode: RGBCameraMode = {
        guard let rawValue = UserDefaults.standard.string(
            forKey: "UMICapture.rgbCameraMode"
        ),
        let mode = RGBCameraMode(rawValue: rawValue)
        else {
            return .wide1x
        }
        return mode
    }()
    @Published private(set) var currentInterfaceOrientation:
        UIInterfaceOrientation = .unknown
    @Published private(set) var captureInterfaceOrientationLock:
        UIInterfaceOrientation?
    @Published private(set) var currentCaptureVideoURL: URL?
    @Published var rgbRecordingEnabled: Bool = UserDefaults.standard.object(
        forKey: "UMICapture.rgbRecordingEnabled"
    ) as? Bool ?? true {
        didSet {
            guard rgbRecordingEnabled != oldValue else {
                return
            }
            UserDefaults.standard.set(
                rgbRecordingEnabled,
                forKey: "UMICapture.rgbRecordingEnabled"
            )
            if rgbRecordingEnabled {
                if isStreaming {
                    startRGBRecording()
                }
            } else {
                finishCurrentRGBSegment(reason: .userDisabled)
            }
        }
    }
    @Published var captureExportSelection = CaptureExportSelection(
        includeRawRGBVideo: UserDefaults.standard.object(
            forKey: "UMICapture.export.includeRawRGBVideo"
        ) as? Bool ?? true,
        includeProcessedRGBVideo: UserDefaults.standard.object(
            forKey: "UMICapture.export.includeProcessedRGBVideo"
        ) as? Bool ?? true,
        includeUltrawideObservation: UserDefaults.standard.object(
            forKey: "UMICapture.export.includeUltrawideObservation"
        ) as? Bool ?? true
    ) {
        didSet {
            UserDefaults.standard.set(
                captureExportSelection.includeRawRGBVideo,
                forKey: "UMICapture.export.includeRawRGBVideo"
            )
            UserDefaults.standard.set(
                captureExportSelection.includeProcessedRGBVideo,
                forKey: "UMICapture.export.includeProcessedRGBVideo"
            )
            UserDefaults.standard.set(
                captureExportSelection.includeUltrawideObservation,
                forKey: "UMICapture.export.includeUltrawideObservation"
            )
        }
    }

    private let sceneView = ARSCNView(frame: .zero)
    private var session: ARSession {
        sceneView.session
    }
    let socketClient = SocketClient()
    private let rgbVideoRecorder = RGBVideoRecorder()
    private let ultrawideObservationSource =
        ARFrameUltrawideObservationSource()
    private var ultrawidePoseTimeline = UltrawidePoseTimeline()
    private var lastUltrawideObservationTimestamp: TimeInterval?
    private var lastUltrawideStatusPublishTimestamp: TimeInterval?
    private let readinessEvaluator = TrackingReadinessEvaluator()
    private let localStartCueController = LocalStartCueController()
    private let synchronizedBoundaryFeedbackController =
        SynchronizedBoundaryFeedbackController()
    private let performanceMonitor = CapturePerformanceMonitor()
    private let captureExportPackageBuilder =
        CaptureExportPackageBuilder()
    let captureLibrary = CaptureLibrary.shared
    private var selectedRGBVideoFormat: SelectedARVideoFormat?
    var hostIP: String = UserDefaults.standard.string(
        forKey: "UMICapture.hostIP"
    ) ?? "127.0.0.1"
    var hostPort: Int = Int(
        UserDefaults.standard.string(forKey: "UMICapture.hostPort") ?? ""
    ) ?? 5555
    var prevTimestamp: Double = 0.0

    private var referenceTransform: simd_float4x4?
    // Trajectory/world origin and the prepared mounting attitude are different
    // contracts. Synchronized capture intentionally keeps a per-phone identity
    // trajectory origin, so it must never be used as the runtime tilt baseline.
    private var captureTiltReferenceTransform: simd_float4x4?
    private var latestRawTransform: simd_float4x4?
    private var lastTrajectoryTimestamp: TimeInterval?
    private var lastTrajectoryFrameTimestamp: TimeInterval?
    private var trajectoryCaptureOrigin: SIMD3<Float>?
    private var trajectoryActiveElapsedTime: TimeInterval = 0
    private var latestOutputTransform: simd_float4x4?
    private var latestOutputPosition = SIMD3<Float>.zero
    private var latestCameraForward = SIMD3<Float>(0, 0, -1)
    private var latestCameraOrientationXYZW =
        SIMD4<Float>(0, 0, 0, 1)
    private var trajectoryDisplayFrame: TrajectoryDisplayFrame?
    private var pendingRemoteStartCommand: RemoteCaptureCommand?
    private var shouldAutoStartAfterCalibration = true
    private var shouldUseLocalStartCueAfterCalibration = true
    private var needsNewRecordingOnStart = false
    private var latestTrackingIsNormal = false
    private var captureEventInteraction: AVCaptureEventInteraction?
    private var hardwareCaptureCameraReady = false
    private var isARSessionRunning = false
    private var rgbBackgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var isVIOSuspendedForCaptureShare = false
    private var currentCaptureGeneration = UUID()
    private var currentCaptureRGBSegmentURLs: [URL] = []
    private var lastPerformanceUpdateTimestamp: TimeInterval = 0
    private var lastPresentationUpdateTimestamp: TimeInterval = 0
    private var activePackageCancellationToken:
        CapturePackageCancellationToken?
    private var activePackageDeadline: DispatchWorkItem?
    private var resourcePressureStopInProgress = false
    private var logicalCaptureStartedAtUnixMs: Int64?
    private var isFinalizingLogicalCapture = false
    private let captureDeviceID = CaptureDeviceIdentity.stableDeviceID()
    private var selectedReceiverID: String?
    private var selectedReceiverDisplayName: String?
    private var receiverPairingToken: String?
    private var captureUploadNoticeGeneration = 0
    private var latestClockSample: CaptureClockMappingSample?
    private var commandLedger = CaptureCommandLedger()
    private var acknowledgementPayloadByCommandKey: [String: [String: Any]] = [:]
    private let capturePackageUploader = CapturePackageUploader()
    private let egoPreviewCIContext = CIContext(options: [
        .cacheIntermediates: false
    ])
    private let egoPreviewEncodingQueue = DispatchQueue(
        label: "umi_capture.ego-preview.encode",
        qos: .utility
    )
    private let egoPreviewDecodingQueue = DispatchQueue(
        label: "umi_capture.ego-preview.decode",
        qos: .utility
    )
    private var egoPreviewEncodingInFlight = false
    private var egoPreviewLastCandidateLocalNs: UInt64?
    private var egoPreviewLastAcceptedSequence: UInt64?
    private var expectedEgoPreviewDeviceID: String?
    private var egoPreviewLifecycleToken = UUID()
    private var scheduledGroupTransition: DispatchWorkItem?
    private var pendingFrameBoundaryTransition:
        PendingFrameBoundaryTransition?
    private var pendingGroupPrepareCommand: GroupCaptureCommand?
    private var pendingUltrawidePreparationDeadline: DispatchWorkItem?
    private var pendingStopCommitTransition: PendingFrameBoundaryTransition?
    private var pendingCoordinatedCaptureUpload:
        PendingCoordinatedCaptureUpload?
    private var coordinatedCaptureUploadInProgress = false
    private var coordinatedCaptureUploadAuthorization:
        CoordinatedCaptureUploadAuthorization?
    private var coordinatedCaptureUploadRetryWorkItem: DispatchWorkItem?
    private var synchronizedPreparationRequestID: UUID?
    private var latchedGroupFailureSessionID: String?
    private var latchedGroupFailureMessage: String?
    private var lockedCaptureProfile: CaptureProfileSnapshot?
    private var activeCaptureCoordination: ActiveCaptureCoordination?
    private var coordinatedPreparationPhase: CoordinatedPreparationPhase = .inactive

    var trajectoryArchiveDisplayFrame: String {
        captureProfileID == .handheldUMI
            && PhysicalTCPProfile.resolve(calibrationID: calibrationID) != nil
            ? TrajectoryArchive.physicalTCPDisplayFrame
            : TrajectoryArchive.robotDisplayFrame
    }
    private var cancellables: Set<AnyCancellable> = []

    private let trajectorySampleInterval: TimeInterval = 0.1
    private let maximumTrajectoryPointCount = 5_000

    var canSwitchRGBCamera: Bool {
        CaptureConfigurationPolicy.canSwitchCamera(
            isCalibrating: isCalibrating,
            isStarting: isStarting,
            isStreaming: isStreaming,
            isCalibrationReady: isCalibrationReady,
            isFinalizing: isFinalizingLogicalCapture,
            hasLogicalCapture:
                logicalCaptureStartedAtUnixMs != nil,
            recorderPhase: rgbRecorderStatus.phase
        )
    }

    var canChangeRGBRecordingSettings: Bool {
        canSwitchRGBCamera
    }

    var storageStatusText: String {
        let decision = CaptureStoragePreflight.evaluateCurrent(
            for: .ordinaryVIO
        )
        guard let available = decision.availableBytes else {
            return "Storage availability could not be verified"
        }
        let formatted = ByteCountFormatter.string(
            fromByteCount: available,
            countStyle: .binary
        )
        var bitRate = 0
        if captureExportSelection.includeRawRGBVideo {
            bitRate += rgbRecordingQuality.rawVideoBitRate
        }
        if captureExportSelection.includeProcessedRGBVideo {
            bitRate += rgbRecordingQuality.umiVideoBitRate
        }
        if captureExportSelection.includeUltrawideObservation,
           activeCaptureProfileID == .handheldUMI {
            bitRate += rgbRecordingQuality.ultrawideVideoBitRate
        }
        guard rgbRecordingEnabled, bitRate > 0 else {
            return "\(formatted) free · VIO-only duration varies"
        }
        let estimatedMinutes = max(
            0,
            Int((Double(available) * 0.8 * 8) / Double(bitRate) / 60)
        )
        return "\(formatted) free · about \(estimatedMinutes) min at current RGB settings"
    }

    var canChangeCaptureProfile: Bool {
        !captureRoleLocked && canSwitchRGBCamera
    }

    var activeCaptureRole: CaptureRole? {
        activeCaptureCoordination?.profile.captureRole
    }

    private var activeCaptureProfileID: CaptureProfileID? {
        activeCaptureCoordination?.profile.profileID
    }

    private var enforcesRuntimeInterfaceOrientationLock: Bool {
        activeCaptureProfileID?.enforcesRuntimeInterfaceOrientationLock
            ?? true
    }

    private var enforcesRuntimeTiltLimit: Bool {
        activeCaptureProfileID?.enforcesRuntimeTiltLimit ?? true
    }

    var hasLogicalCapture: Bool {
        logicalCaptureStartedAtUnixMs != nil
            || isStreaming
            || isStarting
            || isCalibrating
            || isFinalizingLogicalCapture
    }

    var isSynchronizedCaptureActive: Bool {
        synchronizedCapturePhase.isSessionActive
    }

    var shouldShowEgoPreview: Bool {
        EgoPreviewThumbnailPolicy.shouldDisplayOnHand(
            role: activeCaptureCoordination?.profile.captureRole
                ?? captureProfileID.role,
            phase: synchronizedCapturePhase,
            hasActiveCoordination: activeCaptureCoordination != nil,
            hasImage: egoPreviewImage != nil
        )
    }

    func isEgoPreviewStale(nowNs: UInt64) -> Bool {
        EgoPreviewThumbnailPolicy.isStale(
            lastReceivedNs: egoPreviewLastReceivedLocalNs,
            nowNs: nowNs
        )
    }

    var canRequestSynchronizedCapture: Bool {
        let canBeginNormally = synchronizedCapturePhase.allowsNewSessionRequest
            && Self.canBeginGroupPreparation(
                isStreaming: isStreaming,
                isStarting: isStarting,
                isCalibrating: isCalibrating,
                isCalibrationReady: isCalibrationReady,
                isFinalizing: isFinalizingLogicalCapture,
                hasLogicalCapture: logicalCaptureStartedAtUnixMs != nil,
                hasActiveCoordination: activeCaptureCoordination != nil,
                captureRoleLocked: captureRoleLocked
            )
        let hasRecoverableCoordination =
            activeCaptureCoordination != nil
            || captureRoleLocked
            || synchronizedCapturePhase.isSessionActive
            || synchronizedCapturePhase == .failed
            || synchronizedCapturePhase == .finalized
        return connectionState == .connected
            && controllerCapable
            && (canBeginNormally
                || (hasRecoverableCoordination
                    && canResetWithoutDiscardingCapture))
    }

    var canResetWithoutDiscardingCapture: Bool {
        SynchronizedSessionLifecyclePolicy.canResetWithoutDiscardingCapture(
            isStreaming: isStreaming,
            isFinalizing: isFinalizingLogicalCapture,
            hasLogicalCapture: logicalCaptureStartedAtUnixMs != nil,
            recorderPhase: rgbRecorderStatus.phase
        )
    }

    var primaryCaptureSurfaceAction: CaptureSurfaceAction {
        SynchronizedCaptureControlPolicy.primaryAction(
            phase: synchronizedCapturePhase,
            isController: hasEffectiveGroupControl
        )
    }

    var endCaptureSurfaceAction: CaptureSurfaceAction {
        SynchronizedCaptureControlPolicy.endAction(
            phase: synchronizedCapturePhase,
            isController: hasEffectiveGroupControl
        )
    }

    var hardwareCaptureSurfaceAction: CaptureSurfaceAction {
        SynchronizedCaptureControlPolicy.hardwareToggleAction(
            phase: synchronizedCapturePhase,
            isController: hasEffectiveGroupControl
        )
    }

    private var hasEffectiveGroupControl: Bool {
        SynchronizedCaptureControlPolicy.effectiveController(
            cachedController: isSynchronizedCaptureController,
            sharedDeviceControl: synchronizedCaptureUsesSharedDeviceControl,
            controllerCapable: controllerCapable
        )
    }

    var canResetFromControlSurface: Bool {
        if synchronizedCapturePhase.isSessionActive,
           !isStreaming,
           !isFinalizingLogicalCapture,
           logicalCaptureStartedAtUnixMs == nil {
            return true
        }
        return canResetWithoutDiscardingCapture
    }

    static func canBeginGroupPreparation(
        isStreaming: Bool,
        isStarting: Bool,
        isCalibrating: Bool,
        isCalibrationReady: Bool,
        isFinalizing: Bool,
        hasLogicalCapture: Bool,
        hasActiveCoordination: Bool,
        captureRoleLocked: Bool
    ) -> Bool {
        !isStreaming
            && !isFinalizing
            && !hasLogicalCapture
            && !hasActiveCoordination
            && !captureRoleLocked
    }

    func requestCaptureProfile(_ profileID: CaptureProfileID) {
        guard canChangeCaptureProfile else { return }
        if captureProfileID != profileID {
            clearEgoPreviewState()
        }
        captureProfileID = profileID
        UserDefaults.standard.set(
            profileID.rawValue,
            forKey: "UMICapture.captureProfileID"
        )
        refreshCoordinationRegistration()
    }

    func persistCaptureIdentityFields() {
        UserDefaults.standard.set(gripperID, forKey: "UMICapture.gripperID")
        UserDefaults.standard.set(
            calibrationID,
            forKey: "UMICapture.captureCalibrationID"
        )
        refreshCoordinationRegistration()
    }

    func configureReceiverCredential(
        receiverID: String?,
        pairingToken: String?,
        receiverDisplayName: String? = nil
    ) {
        selectedReceiverID = receiverID
        receiverPairingToken = pairingToken
        selectedReceiverDisplayName = receiverDisplayName
    }

    func requestSynchronizedCapture() {
        let retriesPendingRequest =
            synchronizedCapturePhase == .requesting
            && connectionState == .connected
            && controllerCapable
            && !isStreaming
            && !isFinalizingLogicalCapture
            && logicalCaptureStartedAtUnixMs == nil
        guard canRequestSynchronizedCapture || retriesPendingRequest else {
            groupCoordinationStatus = connectionState == .connected
                ? "Synchronization unavailable — finish the current capture first"
                : "Connect to the receiver before synchronized capture"
            return
        }
        if retriesPendingRequest {
            guard ensureARSessionRunning() else {
                synchronizedCapturePhase = .failed
                groupCoordinationStatus =
                    "Camera unavailable — cannot prepare synchronized capture"
                return
            }
            socketClient.clearPendingGroupPreparationRequest()
            let requestID = UUID()
            synchronizedPreparationRequestID = requestID
            groupCoordinationStatus =
                "Re-sending two-device synchronization request"
            socketClient.sendGroupRequest(
                .prepare,
                autoRearmAfterCapture: autoRearmAfterCapture
            )
            scheduleSynchronizedPreparationRequestTimeout(
                requestID: requestID
            )
            return
        }
        let recoverPreviousSession =
            activeCaptureCoordination != nil
            || captureRoleLocked
            || synchronizedCapturePhase.isSessionActive
            || synchronizedCapturePhase == .failed
            || synchronizedCapturePhase == .finalized
        if recoverPreviousSession {
            // Recovery may discard stale coordination state, never capture
            // data. The guard above proves no recorder or package finalizer is
            // active before this reset is allowed.
            resetCalibration()
            releaseSynchronizedSessionOwnership(
                matching: activeCaptureCoordination
            )
        }
        socketClient.clearPendingTerminalGroupRequest()
        socketClient.clearPendingGroupTransitionRequest()
        latchedGroupFailureSessionID = nil
        latchedGroupFailureMessage = nil
        synchronizedMembershipInterrupted = false
        let requestID = UUID()
        synchronizedPreparationRequestID = requestID
        synchronizedCapturePhase = .requesting
        guard ensureARSessionRunning() else {
            synchronizedPreparationRequestID = nil
            synchronizedCapturePhase = .failed
            groupCoordinationStatus =
                "Camera unavailable — cannot prepare synchronized capture"
            return
        }
        isSynchronizedCaptureController = false
        groupCoordinationStatus = recoverPreviousSession
            ? "Rebuilding both-device synchronization"
            : "Requesting two-device synchronization"
        socketClient.sendGroupRequest(
            .prepare,
            recoverPreviousSession: recoverPreviousSession,
            autoRearmAfterCapture: autoRearmAfterCapture
        )
        scheduleSynchronizedPreparationRequestTimeout(
            requestID: requestID
        )
    }

    private func scheduleSynchronizedPreparationRequestTimeout(
        requestID: UUID
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self,
                  self.synchronizedPreparationRequestID == requestID,
                  self.synchronizedCapturePhase == .requesting
            else { return }
            self.synchronizedPreparationRequestID = nil
            self.socketClient.clearPendingGroupPreparationRequest()
            self.synchronizedCapturePhase = .failed
            self.groupCoordinationStatus =
                "Synchronization not confirmed — tap again to rebuild both devices"
            self.enterWarmIdle()
        }
    }

    func leaveSynchronizedMode() {
        guard canResetWithoutDiscardingCapture else {
            groupCoordinationStatus =
                "End the current capture before leaving synchronized mode"
            return
        }
        if synchronizedCapturePhase.isSessionActive
            || captureRoleLocked
            || activeCaptureCoordination != nil {
            socketClient.sendGroupResetRequest()
        }
        resetCalibration()
        releaseSynchronizedSessionOwnership(
            matching: activeCaptureCoordination
        )
        synchronizedCapturePhase = .inactive
        synchronizedMembershipInterrupted = false
        synchronizedCaptureUsesSharedDeviceControl = false
        isSynchronizedCaptureController = false
        groupCoordinationStatus = "Single-device mode"
        enterWarmIdle()
    }

    func requestGroupCommand(_ command: GroupCaptureCommandName) {
        if command == .prepare {
            requestSynchronizedCapture()
            return
        }
        guard canRequestGroupCommand(command)
        else {
            groupCoordinationStatus = "This phone is not the group controller"
            return
        }
        guard connectionState == .connected || command == .stop else {
            groupCoordinationStatus =
                "Connection interrupted — wait for reconnect before changing capture state"
            return
        }
        switch command {
        case .prepare:
            return
        case .start:
            synchronizedCapturePhase = .starting
        case .pause:
            groupCoordinationStatus =
                "Pause/Resume is not supported by UMI Capture"
            return
        case .resume:
            groupCoordinationStatus =
                "Pause/Resume is not supported by UMI Capture"
            return
        case .stop:
            synchronizedCapturePhase = .stopping
        }
        socketClient.sendGroupRequest(command)
        if command == .stop, connectionState != .connected {
            groupCoordinationStatus =
                "Stop queued — it will be delivered after Receiver reconnects"
        }
    }

    func canRequestGroupCommand(_ command: GroupCaptureCommandName) -> Bool {
        if command == .prepare {
            return canRequestSynchronizedCapture
        }
        guard hasEffectiveGroupControl,
              synchronizedCapturePhase.isSessionActive
        else { return false }
        if primaryCaptureSurfaceAction == .group(command) {
            return true
        }
        return endCaptureSurfaceAction == .group(command)
    }

    func performPrimaryCaptureSurfaceAction() {
        switch primaryCaptureSurfaceAction {
        case .localStart:
            startLocalCaptureFromControlSurface()
        case .group(let command):
            requestGroupCommand(command)
        case .localEnd, .disabled:
            break
        }
    }

    func requestResetFromControlSurface() {
        let hasGroupOwnership = activeCaptureCoordination != nil
            || captureRoleLocked
            || synchronizedCapturePhase.isSessionActive
            || synchronizedCapturePhase == .failed
            || synchronizedCapturePhase == .finalized
        guard hasGroupOwnership else {
            socketClient.sendCaptureControl("reset")
            resetCalibration()
            return
        }
        guard !isStreaming,
              !isFinalizingLogicalCapture,
              logicalCaptureStartedAtUnixMs == nil
        else {
            groupCoordinationStatus =
                "Reset unavailable — End the current capture first"
            return
        }
        socketClient.clearPendingGroupPreparationRequest()
        socketClient.clearPendingGroupTransitionRequest()
        latchedGroupFailureSessionID = nil
        latchedGroupFailureMessage = nil
        synchronizedCapturePhase = .requesting
        groupCoordinationStatus =
            "Resetting two-device synchronization"
        socketClient.sendGroupResetRequest()
    }

    func requestRGBRecordingFrameRate(
        _ frameRate: RGBRecordingFrameRate
    ) {
        guard canChangeRGBRecordingSettings else {
            return
        }
        rgbRecordingFrameRate = frameRate
        UserDefaults.standard.set(
            frameRate.rawValue,
            forKey: "UMICapture.rgbRecordingFrameRate"
        )
    }

    func requestRGBRecordingQuality(
        _ quality: RGBRecordingQuality
    ) {
        guard canChangeRGBRecordingSettings else {
            return
        }
        rgbRecordingQuality = quality
        UserDefaults.standard.set(
            quality.rawValue,
            forKey: "UMICapture.rgbRecordingQuality"
        )
    }

    var isCaptureOrientationSupported: Bool {
        UMICaptureOrientation.isValid(
            resolvedInterfaceOrientation()
        )
    }

    var captureStartPrerequisitesMet: Bool {
        selectedRGBVideoFormat != nil
            && CaptureOrientationPolicy.isCompatible(
                lockedOrientation: captureInterfaceOrientationLock,
                currentOrientation: resolvedInterfaceOrientation()
            )
            && isCaptureTiltWithinLimit
    }

    private var isCaptureTiltWithinLimit: Bool {
        guard let captureTiltReferenceTransform,
              let latestRawTransform
        else {
            return true
        }
        return !CaptureOrientationPolicy.exceedsTiltLimit(
            referenceTransform: captureTiltReferenceTransform,
            currentTransform: latestRawTransform
        )
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupCameraPreview()
        setupHardwareCaptureButtons()
        observeSocketConnection()
        setupRGBVideoRecorder()
        observeApplicationLifecycle()
        observeOrientation()
        setupARSession()
        subscribeToActionStream()
    }

    deinit {
        localStartCueController.cancel()
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        updateInterfaceOrientation(
            enforce: false,
            requestWindowRotation: true
        )
    }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        guard let captureInterfaceOrientationLock,
              let mask = UMICaptureOrientation.interfaceOrientationMask(
                for: captureInterfaceOrientationLock
              )
        else { return .allButUpsideDown }
        return mask
    }

    private func observeSocketConnection() {
        socketClient.onConnectionStateChange = { [weak self] state in
            DispatchQueue.main.async {
                guard let self else { return }
                self.connectionState = state
                if state == .connected {
                    self.retryAuthorizedCoordinatedCaptureUpload()
                }
                if state == .disconnected {
                    self.clearEgoPreviewState()
                }
                if state == .disconnected,
                   self.synchronizedCapturePhase.isSessionActive {
                    self.groupCoordinationStatus =
                        "Connection interrupted — local capture continues; pending commands recover after reconnect"
                }
            }
        }
        socketClient.onCaptureCommand = { [weak self] command in
            DispatchQueue.main.async {
                self?.handleRemoteCaptureCommand(command)
            }
        }
        socketClient.onRegistrationAck = { [weak self] payload in
            DispatchQueue.main.async {
                guard let self else { return }
                if payload["accepted"] as? Bool == true {
                    self.receiverIdentity = payload["receiver_id"] as? String
                    if let receiverID = self.receiverIdentity {
                        self.selectedReceiverID = receiverID
                        if let token = self.receiverPairingToken {
                            _ = ReceiverCredentialStore.store(
                                token: token,
                                receiverID: receiverID
                            )
                        }
                    }
                    self.groupCoordinationStatus = "Paired — waiting for group session"
                } else {
                    self.groupCoordinationStatus = "Pairing or role registration rejected"
                }
            }
        }
        socketClient.onClockSample = { [weak self] sample in
            DispatchQueue.main.async {
                self?.latestClockSample = sample
            }
        }
        socketClient.onGroupCommand = { [weak self] command in
            DispatchQueue.main.async {
                self?.handleGroupCaptureCommand(command)
            }
        }
        socketClient.onGroupState = { [weak self] payload in
            DispatchQueue.main.async {
                self?.handleGroupState(payload)
            }
        }
        socketClient.onEgoPreviewFrame = { [weak self] payload in
            self?.receiveEgoPreviewFrame(payload)
        }
    }

    private func maybeSendEgoPreview(
        frame: ARFrame,
        interfaceOrientation: UIInterfaceOrientation
    ) {
        let nowNs = DispatchTime.now().uptimeNanoseconds
        let role = activeCaptureCoordination?.profile.captureRole
            ?? captureProfileID.role
        guard EgoPreviewThumbnailPolicy.shouldAdmitEgoFrame(
            role: role,
            phase: synchronizedCapturePhase,
            hasActiveCoordination: activeCaptureCoordination != nil,
            socketReady: socketClient.ready,
            encoderBusy: egoPreviewEncodingInFlight,
            lastCandidateNs: egoPreviewLastCandidateLocalNs,
            nowNs: nowNs
        ),
        UMICaptureOrientation.isValid(interfaceOrientation),
        let coordination = activeCaptureCoordination
        else { return }

        egoPreviewEncodingInFlight = true
        egoPreviewLastCandidateLocalNs = nowNs
        let sequence = EgoPreviewThumbnailPolicy.sequence(
            senderMonotonicNs: nowNs
        )
        let lifecycleToken = egoPreviewLifecycleToken
        let pixelBuffer = frame.capturedImage
        let arFrameTimestampSeconds = frame.timestamp
        let orientationMetadata = UMICaptureOrientation.metadataValue(
            for: interfaceOrientation
        )
        let sessionID = coordination.sessionID
        let generation = coordination.generation
        let deviceID = coordination.profile.deviceID

        egoPreviewEncodingQueue.async { [weak self] in
            guard let self else { return }
            let jpegData = self.makeEgoPreviewJPEG(
                pixelBuffer: pixelBuffer,
                interfaceOrientation: interfaceOrientation
            )
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.egoPreviewEncodingInFlight = false
                guard self.egoPreviewLifecycleToken == lifecycleToken,
                      let jpegData,
                      jpegData.count
                        <= EgoPreviewThumbnailPolicy.maximumJPEGBytes,
                      let current = self.activeCaptureCoordination,
                      current.sessionID == sessionID,
                      current.generation == generation,
                      current.profile.captureRole == .ego,
                      EgoPreviewThumbnailPolicy.sessionAcceptsFrames(
                        phase: self.synchronizedCapturePhase
                      )
                else { return }
                self.socketClient.sendEgoPreviewFrame([
                    "protocol_version": CaptureCoordinationProtocol.version,
                    "session_id": sessionID,
                    "generation": generation,
                    "device_id": deviceID,
                    "capture_role": CaptureRole.ego.rawValue,
                    "sequence": String(sequence),
                    "arkit_timestamp_s": arFrameTimestampSeconds,
                    "sender_monotonic_ns": String(nowNs),
                    "orientation": orientationMetadata,
                    "jpeg_base64": jpegData.base64EncodedString()
                ])
            }
        }
    }

    private func makeEgoPreviewJPEG(
        pixelBuffer: CVPixelBuffer,
        interfaceOrientation: UIInterfaceOrientation
    ) -> Data? {
        guard let imageOrientation =
                UMICaptureOrientation.uprightImageOrientation(
                    for: interfaceOrientation
                )
        else { return nil }
        let oriented = CIImage(cvPixelBuffer: pixelBuffer)
            .oriented(imageOrientation)
        let extent = oriented.extent.integral
        guard extent.width > 0, extent.height > 0 else { return nil }
        let normalized = oriented.transformed(
            by: CGAffineTransform(
                translationX: -extent.minX,
                y: -extent.minY
            )
        )
        let scale = min(
            1,
            EgoPreviewThumbnailPolicy.maximumLongEdgePixels
                / max(extent.width, extent.height)
        )
        let scaled = normalized.transformed(
            by: CGAffineTransform(scaleX: scale, y: scale)
        )
        guard let cgImage = egoPreviewCIContext.createCGImage(
            scaled,
            from: scaled.extent.integral
        ) else { return nil }
        return UIImage(cgImage: cgImage).jpegData(
            compressionQuality:
                EgoPreviewThumbnailPolicy.JPEGCompressionQuality
        )
    }

    private func receiveEgoPreviewFrame(_ payload: [String: Any]) {
        guard let frame = EgoPreviewFramePayload.decode(payload),
              let coordination = activeCaptureCoordination,
              coordination.profile.captureRole == .wristUMI,
              EgoPreviewThumbnailPolicy.sessionAcceptsFrames(
                phase: synchronizedCapturePhase
              ),
              frame.sessionID == coordination.sessionID,
              frame.generation == coordination.generation,
              frame.deviceID == expectedEgoPreviewDeviceID,
              EgoPreviewThumbnailPolicy.acceptsSequence(
                frame.sequence,
                after: egoPreviewLastAcceptedSequence
              )
        else { return }

        egoPreviewLastAcceptedSequence = frame.sequence
        let lifecycleToken = egoPreviewLifecycleToken
        let sequence = frame.sequence
        let sessionID = frame.sessionID
        let generation = frame.generation
        egoPreviewDecodingQueue.async { [weak self] in
            guard let image = UIImage(data: frame.jpegData) else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.egoPreviewLifecycleToken == lifecycleToken,
                      self.egoPreviewLastAcceptedSequence == sequence,
                      let current = self.activeCaptureCoordination,
                      current.sessionID == sessionID,
                      current.generation == generation,
                      current.profile.captureRole == .wristUMI,
                      EgoPreviewThumbnailPolicy.sessionAcceptsFrames(
                        phase: self.synchronizedCapturePhase
                      )
                else { return }
                self.egoPreviewImage = image
                self.egoPreviewLastReceivedLocalNs =
                    DispatchTime.now().uptimeNanoseconds
            }
        }
    }

    private func clearEgoPreviewState(
        preservingExpectedDeviceID: Bool = false
    ) {
        egoPreviewLifecycleToken = UUID()
        egoPreviewImage = nil
        egoPreviewLastReceivedLocalNs = nil
        egoPreviewLastCandidateLocalNs = nil
        egoPreviewLastAcceptedSequence = nil
        if !preservingExpectedDeviceID {
            expectedEgoPreviewDeviceID = nil
        }
    }

    private func handleGroupState(_ payload: [String: Any]) {
        guard payload["protocol_version"] as? Int
                == CaptureCoordinationProtocol.version
        else { return }

        acceptFrozenCoordinatedUploadGrantReplay(from: payload)

        let coordinationError = payload["error"] as? String
        if let error = coordinationError, !error.isEmpty,
           payload["session"] == nil {
            if hasAuthorizedCoordinatedCaptureUpload {
                synchronizedCapturePhase = .finalizing
                groupCoordinationStatus =
                    "Authorized upload interrupted — local ZIP retained; retrying the frozen Receiver grant"
                scheduleAuthorizedCoordinatedCaptureUploadRetry()
                return
            }
            socketClient.clearPendingGroupPreparationRequest()
            synchronizedPreparationRequestID = nil
            synchronizedCapturePhase = .failed
            isSynchronizedCaptureController = false
            synchronizedMembershipInterrupted =
                error.contains("both wrist_umi and ego devices are required")
            groupCoordinationStatus = "Synchronization unavailable — \(error)"
            return
        }

        let devices = payload["devices"] as? [[String: Any]] ?? []
        expectedEgoPreviewDeviceID = devices.first {
            $0["capture_role"] as? String == CaptureRole.ego.rawValue
        }?["device_id"] as? String
        let roles = Set(devices.compactMap { $0["capture_role"] as? String })
        let bothRolesConnected = roles == Set(["wrist_umi", "ego"])
        guard let session = payload["session"] as? [String: Any] else {
            if hasAuthorizedCoordinatedCaptureUpload {
                synchronizedCapturePhase = .finalizing
                groupCoordinationStatus =
                    "Authorized upload interrupted — local ZIP retained; retrying the frozen Receiver grant"
                scheduleAuthorizedCoordinatedCaptureUploadRetry()
                return
            }
            // A Receiver restart or an operator Reset is authoritative: no
            // active session means neither phone may retain an old Ready or
            // interrupted badge. Preserve only capture data that is already
            // being recorded/finalized locally.
            if synchronizedCapturePhase == .requesting {
                groupCoordinationStatus =
                    "Requesting two-device synchronization"
                return
            }
            switch SynchronizedMissingSessionPolicy.action(
                isStreaming: isStreaming,
                isFinalizing: isFinalizingLogicalCapture,
                hasLogicalCapture: logicalCaptureStartedAtUnixMs != nil
            ) {
            case .preserveLocalCapture:
                socketClient.clearPendingGroupTransitionRequest()
                synchronizedMembershipInterrupted = true
                isSynchronizedCaptureController = false
                synchronizedCaptureUsesSharedDeviceControl = false
                synchronizedCapturePhase = isFinalizingLogicalCapture
                    ? .finalizing
                    : (isStreaming ? .running : .failed)
                groupCoordinationStatus =
                    "Receiver session unavailable — local capture preserved; End to save this phone"
            case .clearStaleState:
                latchedGroupFailureSessionID = nil
                latchedGroupFailureMessage = nil
                scheduledGroupTransition?.cancel()
                scheduledGroupTransition = nil
                pendingFrameBoundaryTransition = nil
                socketClient.clearPendingTerminalGroupRequest()
                socketClient.clearPendingGroupPreparationRequest()
                socketClient.clearPendingGroupTransitionRequest()
                socketClient.clearPendingGroupResetRequest()
                synchronizedPreparationRequestID = nil
                resetCalibration()
                releaseSynchronizedSessionOwnership(
                    matching: activeCaptureCoordination
                )
                synchronizedCapturePhase = .inactive
                synchronizedMembershipInterrupted = false
                isSynchronizedCaptureController = false
                synchronizedCaptureUsesSharedDeviceControl = false
                groupCoordinationStatus =
                    bothRolesConnected
                        ? "Two devices connected — tap Synchronized Capture"
                        : "Waiting for both devices — connect Ego and Hand"
            }
            return
        }

        let membershipValid = session["membership_valid"] as? Bool
            ?? bothRolesConnected
        let incomingPartialReasons =
            session["partial_reasons"] as? [String] ?? []
        let isOperatorReset = incomingPartialReasons.contains {
            $0.hasPrefix("operator_reset:")
        }
        if !isOperatorReset,
           hasAuthorizedCoordinatedCaptureUpload,
           (!bothRolesConnected || !membershipValid) {
            synchronizedCapturePhase = .finalizing
            groupCoordinationStatus =
                "Authorized upload interrupted — local ZIP retained; retrying the frozen Receiver grant"
            scheduleAuthorizedCoordinatedCaptureUploadRetry()
            return
        }
        switch SynchronizedMembershipRecoveryPolicy.action(
            bothRolesConnected: bothRolesConnected,
            membershipValid: membershipValid,
            isStreaming: isStreaming,
            isFinalizing: isFinalizingLogicalCapture,
            hasLogicalCapture: logicalCaptureStartedAtUnixMs != nil
        ) {
        case .healthy:
            synchronizedMembershipInterrupted = false
            break
        case .invalidateAndReprepare:
            scheduledGroupTransition?.cancel()
            scheduledGroupTransition = nil
            pendingFrameBoundaryTransition = nil
            socketClient.clearPendingGroupPreparationRequest()
            socketClient.clearPendingGroupTransitionRequest()
            synchronizedPreparationRequestID = nil
            synchronizedCapturePhase = .failed
            synchronizedMembershipInterrupted = true
            isSynchronizedCaptureController = false
            synchronizedCaptureUsesSharedDeviceControl = false
            releaseSynchronizedSessionOwnership(
                matching: activeCaptureCoordination
            )
            groupCoordinationStatus =
                "Two-device connection lost — synchronization revoked; reconnect and prepare both devices again"
            calibrationStatus =
                "Peer disconnected — prepare both local pose streams again"
            return
        case .preserveLocalCapture:
            socketClient.clearPendingGroupTransitionRequest()
            synchronizedMembershipInterrupted = true
            isSynchronizedCaptureController = false
            synchronizedCaptureUsesSharedDeviceControl = false
            synchronizedCapturePhase = isFinalizingLogicalCapture
                ? .finalizing
                : (isStreaming ? .running : .failed)
            groupCoordinationStatus =
                "Peer disconnected — local capture is preserved; End saves this phone, then re-prepare both devices"
            return
        }

        synchronizedPreparationRequestID = nil
        let sessionID = session["session_id"] as? String
        if latchedGroupFailureSessionID != sessionID {
            latchedGroupFailureSessionID = nil
            latchedGroupFailureMessage = nil
        }
        let controllerKind = session["controller_kind"] as? String
        let controllerDeviceID = session["controller_device_id"] as? String
        let sharedDeviceControl =
            session["shared_device_control"] as? Bool ?? false
        synchronizedCaptureUsesSharedDeviceControl = sharedDeviceControl
        isSynchronizedCaptureController =
            SynchronizedCaptureControlPolicy.deviceCanControl(
                controllerKind: controllerKind,
                initiatingDeviceID: controllerDeviceID,
                sharedDeviceControl: sharedDeviceControl,
                controllerCapable: controllerCapable,
                localDeviceID: captureDeviceID
            )

        if let error = coordinationError, !error.isEmpty {
            if error == "Synchronizing both device clocks before Start" {
                synchronizedCapturePhase = .starting
                groupCoordinationStatus =
                    "Synchronizing device clocks — Start will continue automatically"
                return
            }
            if error.hasPrefix("Start cancelled:") {
                scheduledGroupTransition?.cancel()
                scheduledGroupTransition = nil
                pendingFrameBoundaryTransition = nil
                socketClient.clearPendingGroupTransitionRequest()
                latchedGroupFailureSessionID = sessionID
                latchedGroupFailureMessage =
                    "Start failed — device clocks did not synchronize; keep both apps open and prepare both devices again"
                synchronizedCapturePhase = .failed
                synchronizedMembershipInterrupted = false
                isSynchronizedCaptureController = false
                groupCoordinationStatus = latchedGroupFailureMessage ?? error
                return
            }
        }
        if latchedGroupFailureSessionID == sessionID,
           let failureMessage = latchedGroupFailureMessage {
            synchronizedCapturePhase = .failed
            synchronizedMembershipInterrupted = false
            isSynchronizedCaptureController = false
            groupCoordinationStatus = failureMessage
            return
        }

        let completionState = session["completion_state"] as? String
        if completionState == "partial" {
            pendingStopCommitTransition = nil
            if hasAuthorizedCoordinatedCaptureUpload,
               !isOperatorReset {
                synchronizedCapturePhase = .finalizing
                groupCoordinationStatus =
                    "Authorized upload interrupted — local ZIP retained; retrying the frozen Receiver grant"
                scheduleAuthorizedCoordinatedCaptureUploadRetry()
                return
            }
            let withheldPendingUpload = pendingCoordinatedCaptureUpload != nil
            if let pendingUpload = pendingCoordinatedCaptureUpload {
                publishSynchronizedCaptureFallback(
                    pendingUpload.artifacts,
                    receiverUploadSucceeded: false
                )
                pendingCoordinatedCaptureUpload = nil
                coordinatedCaptureUploadAuthorization = nil
                cancelAuthorizedCoordinatedCaptureUploadRetry()
                captureUploadSuccessNotice = nil
            }
            let partialReasons = session["partial_reasons"] as? [String] ?? []
            if partialReasons.contains(where: {
                $0.hasPrefix("operator_reset:")
            }), !isStreaming,
               !isFinalizingLogicalCapture,
               logicalCaptureStartedAtUnixMs == nil {
                socketClient.clearPendingGroupResetRequest()
                resetCalibration()
                releaseSynchronizedSessionOwnership(
                    matching: activeCaptureCoordination
                )
                synchronizedCapturePhase = .failed
                synchronizedMembershipInterrupted = false
                groupCoordinationStatus =
                    "Two-device synchronization reset — tap Synchronized Capture to prepare again"
                return
            }
            if Self.shouldPreserveControlsForPartialGroupState(
                isStreaming: isStreaming,
                isFinalizing: isFinalizingLogicalCapture,
                hasLogicalCapture: logicalCaptureStartedAtUnixMs != nil
            ) {
                // Evidence quality may already be partial while both recorders
                // are still running. Keep the shared controller alive so End
                // remains a group Stop.
                synchronizedCapturePhase = isFinalizingLogicalCapture
                    ? .finalizing
                    : (isStreaming ? .running : .failed)
                groupCoordinationStatus =
                    "Two-device evidence is partial — End still stops both devices"
                return
            }
            scheduledGroupTransition?.cancel()
            scheduledGroupTransition = nil
            pendingFrameBoundaryTransition = nil
            synchronizedCapturePhase = .failed
            isSynchronizedCaptureController = false
            releaseSynchronizedSessionOwnershipIfSafe()
            groupCoordinationStatus = withheldPendingUpload
                ? "Synchronization failed — ZIP kept on phone and was not uploaded"
                : (activeCaptureCoordination == nil
                    ? "Two-device capture is partial — ready for a new session"
                    : "Two-device capture is partial — End locally to preserve data")
            return
        }
        if session["stop_commit_authorized"] as? Bool == true {
            authorizePendingStopCommit()
        }
        if session["upload_commit_authorized"] as? Bool == true,
           completionState != "completed" {
            if let sessionID = session["session_id"] as? String,
               let generation = session["generation"] as? Int {
                coordinatedCaptureUploadAuthorization =
                    CoordinatedCaptureUploadAuthorization(
                        sessionID: sessionID,
                        generation: generation
                    )
            }
            if pendingCoordinatedCaptureUpload != nil {
                commitPendingCoordinatedCaptureUpload(
                    sessionID: session["session_id"] as? String,
                    generation: session["generation"] as? Int
                )
            }
            synchronizedCapturePhase = .finalizing
            if !coordinatedCaptureUploadInProgress,
               pendingCoordinatedCaptureUpload == nil {
                groupCoordinationStatus =
                    "Local ZIP uploaded — waiting for peer upload confirmation"
            }
            return
        }
        if completionState == "completed" {
            synchronizedCapturePhase = .finalized
            captureFinalizationStage = .completed
            isSynchronizedCaptureController = false
            releaseSynchronizedSessionOwnershipIfSafe()
            // A completed session can be replayed by the Receiver after an app
            // reconnect. Never turn that replay into an implicit Prepare.
            groupCoordinationStatus = activeCaptureCoordination == nil
                ? "Two-device capture completed — tap Synchronized Capture for the next session"
                : "Two-device capture completed — finishing local files"
            return
        }

        guard SynchronizedSessionLifecyclePolicy
            .shouldApplyNonterminalGroupState(
                hasActiveCoordination: activeCaptureCoordination != nil,
                currentPhase: synchronizedCapturePhase
            )
        else {
            return
        }

        let transitions = session["planned_transitions"]
            as? [[String: Any]] ?? []
        guard let transition = transitions.last,
              let commandText = transition["command"] as? String,
              let command = GroupCaptureCommandName(rawValue: commandText)
        else {
            synchronizedCapturePhase = .preparing
            updateSynchronizedControllerStatus()
            return
        }

        let commandIDs = transition["command_ids"] as? [String: Any] ?? [:]
        let expectedIDs = Set(commandIDs.values.compactMap { $0 as? String })
        let acknowledgements = session["acknowledgements"]
            as? [[String: Any]] ?? []
        func allDevicesReached(_ state: String) -> Bool {
            expectedIDs.count == 2
                && expectedIDs.allSatisfy { expectedID in
                    acknowledgements.contains { acknowledgement in
                        acknowledgement["command_id"] as? String == expectedID
                            && acknowledgement["state"] as? String == state
                    }
                }
        }

        switch command {
        case .prepare:
            synchronizedCapturePhase = allDevicesReached("armed")
                ? .armed
                : .preparing
        case .start:
            synchronizedCapturePhase = allDevicesReached("started")
                ? .running
                : .starting
        case .pause:
            synchronizedCapturePhase = .failed
            groupCoordinationStatus =
                "Legacy Pause rejected — End and prepare a new capture"
            return
        case .resume:
            synchronizedCapturePhase = .failed
            groupCoordinationStatus =
                "Legacy Resume rejected — End and prepare a new capture"
            return
        case .stop:
            socketClient.acknowledgeGroupRequest(.stop)
            synchronizedCapturePhase = allDevicesReached("finalized")
                ? .finalized
                : .finalizing
        }
        updateSynchronizedControllerStatus()
        if let error = coordinationError, !error.isEmpty {
            if error == "Synchronizing both device clocks before Start" {
                groupCoordinationStatus =
                    "Synchronizing clocks — Start will continue automatically"
            } else {
                groupCoordinationStatus = "Synchronization unavailable — \(error)"
            }
        }
    }

    static func shouldPreserveControlsForPartialGroupState(
        isStreaming: Bool,
        isFinalizing: Bool,
        hasLogicalCapture: Bool
    ) -> Bool {
        isStreaming || isFinalizing || hasLogicalCapture
    }

    private func updateSynchronizedControllerStatus() {
        let owner: String
        if synchronizedCaptureUsesSharedDeviceControl {
            owner = "either phone controls"
        } else {
            owner = isSynchronizedCaptureController
                ? "this phone controls"
                : "controlled by Mac or the other phone"
        }
        switch synchronizedCapturePhase {
        case .preparing:
            groupCoordinationStatus = "Two-device mode — preparing; \(owner)"
        case .armed:
            groupCoordinationStatus = "Two-device mode — both armed; \(owner)"
        case .starting:
            groupCoordinationStatus = "Two-device mode — synchronized Start scheduled"
        case .running:
            groupCoordinationStatus = "Two-device mode — recording; \(owner)"
        case .stopping, .finalizing:
            groupCoordinationStatus = "Two-device mode — synchronized Stop in progress"
        case .requesting:
            groupCoordinationStatus = "Requesting two-device synchronization"
        case .finalized:
            groupCoordinationStatus = "Two-device capture finalized"
        case .failed:
            groupCoordinationStatus = "Two-device capture is partial"
        case .inactive:
            groupCoordinationStatus = "Paired — waiting for group session"
        }
    }

    private func setupCameraPreview() {
        sceneView.translatesAutoresizingMaskIntoConstraints = false
        sceneView.scene = SCNScene()
        sceneView.automaticallyUpdatesLighting = false
        view.addSubview(sceneView)

        NSLayoutConstraint.activate([
            sceneView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            sceneView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            sceneView.topAnchor.constraint(equalTo: view.topAnchor),
            sceneView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    private func setupHardwareCaptureButtons() {
        guard #available(iOS 17.2, *) else {
            return
        }

        if let captureEventInteraction {
            view.removeInteraction(captureEventInteraction)
        }
        let interaction = AVCaptureEventInteraction(
            primary: { [weak self] event in
                guard event.phase == .ended else { return }
                self?.performHardwareCaptureSurfaceAction()
            },
            secondary: { [weak self] event in
                guard event.phase == .ended else { return }
                self?.performHardwareCaptureSurfaceAction()
            }
        )
        // Apple delivers capture events only while the camera is actively
        // capturing. Keep the interaction disabled until ARKit supplies a new
        // frame, then re-enable it after every session restart lifecycle.
        interaction.isEnabled = false
        view.addInteraction(interaction)
        captureEventInteraction = interaction
        hardwareCaptureCameraReady = false
    }

    private func setHardwareCaptureCameraReady(_ ready: Bool) {
        hardwareCaptureCameraReady = ready
        guard #available(iOS 17.2, *) else { return }
        captureEventInteraction?.isEnabled = ready
            && UIApplication.shared.applicationState == .active
    }

    private func performHardwareCaptureSurfaceAction() {
        switch hardwareCaptureSurfaceAction {
        case .group(let command):
            requestGroupCommand(command)
        case .localEnd:
            if activeCaptureCoordination != nil {
                synchronizedCapturePhase = .finalizing
                groupCoordinationStatus = "Emergency local End — finalizing files"
                finalizeLogicalCapture(
                    rgbFinishReason: .stop
                ) { [weak self] artifacts in
                    guard let self else { return }
                    self.publishSynchronizedCaptureFallback(
                        artifacts,
                        receiverUploadSucceeded: false
                    )
                    self.synchronizedCapturePhase = .failed
                    self.groupCoordinationStatus =
                        "Ended locally — group capture is partial"
                    self.releaseSynchronizedSessionOwnership(
                        matching: self.activeCaptureCoordination
                    )
                }
            } else {
                endCurrentCapture { [weak self] artifacts in
                    self?.completedStandaloneCaptureArtifacts = artifacts
                }
            }
        case .localStart:
            if hasLogicalCapture {
                endCurrentCapture { [weak self] artifacts in
                    self?.completedStandaloneCaptureArtifacts = artifacts
                }
            } else {
                startLocalCaptureFromControlSurface()
            }
        case .disabled:
            groupCoordinationStatus =
                "Volume key received — waiting for synchronized state"
            print(
                "Hardware capture event ignored: phase="
                    + "\(synchronizedCapturePhase), controller="
                    + "\(isSynchronizedCaptureController), shared="
                    + "\(synchronizedCaptureUsesSharedDeviceControl)"
            )
        }
    }

    private func startLocalCaptureFromControlSurface() {
        guard !hasLogicalCapture else {
            calibrationStatus = "Capture already active — use End to save"
            return
        }
        guard ensureARSessionRunning() else {
            calibrationStatus = "Camera unavailable — cannot prepare capture"
            return
        }
        _ = startStreaming(origin: .local)
    }

    private func handleRemoteCaptureCommand(
        _ command: RemoteCaptureCommand
    ) {
        switch command.command {
        case "prepare":
            guard ensureARSessionRunning() else {
                sendRemoteCaptureStatus(
                    command,
                    state: "camera_unavailable"
                )
                return
            }
            guard validateCaptureStart(
                remoteCommand: command
            ) else {
                return
            }
            pendingRemoteStartCommand = command
            beginCalibration(
                autoStart: false,
                useLocalStartCue: false
            )
            sendRemoteCaptureStatus(
                command,
                state: "calibrating"
            )
        case "start":
            pendingRemoteStartCommand = command
            guard startStreaming(origin: .remote) else {
                pendingRemoteStartCommand = nil
                return
            }
            if isCalibrating {
                sendRemoteCaptureStatus(
                    command,
                    state: "calibrating"
                )
            } else if isStreaming {
                sendRemoteCaptureStatus(
                    command,
                    state: "streaming"
                )
                pendingRemoteStartCommand = nil
            }
        case "pause", "resume":
            sendRemoteCaptureStatus(
                command,
                state: "pause_resume_not_supported"
            )
            pendingRemoteStartCommand = nil
        case "stop":
            finalizeLogicalCapture(
                rgbFinishReason: .stop,
                commandID: command.commandID
            )
            sendRemoteCaptureStatus(command, state: "stopped")
            pendingRemoteStartCommand = nil
        case "reset":
            socketClient.sendCaptureControl(
                "reset",
                commandID: command.commandID
            )
            resetCalibration()
            sendRemoteCaptureStatus(command, state: "ready")
            pendingRemoteStartCommand = nil
        default:
            sendRemoteCaptureStatus(
                command,
                state: "unsupported_command"
            )
        }
    }

    private func handleGroupCaptureCommand(
        _ command: GroupCaptureCommand
    ) {
        guard command.targetDeviceID == captureDeviceID else { return }
        switch commandLedger.disposition(for: command) {
        case .duplicate(let previousState):
            let key = "\(command.sessionID):\(command.commandID)"
            if let payload = acknowledgementPayloadByCommandKey[key] {
                socketClient.sendGroupAcknowledgement(payload)
            } else {
                sendGroupAcknowledgement(command, state: previousState)
            }
            return
        case .staleGeneration:
            sendGroupAcknowledgement(command, state: "stale_generation")
            return
        case .conflictingCommandID:
            sendGroupAcknowledgement(command, state: "rejected")
            return
        case .execute:
            break
        }

        if command.command == .pause || command.command == .resume {
            sendGroupAcknowledgement(
                command,
                state: "rejected",
                partialReason: "pause_resume_not_supported"
            )
            groupCoordinationStatus =
                "Pause/Resume is unsupported — use End, then prepare again"
            return
        }

        if command.command == .prepare {
            clearEgoPreviewState(
                preservingExpectedDeviceID: true
            )
            if command.automaticRearm {
                guard AutomaticRearmAdmissionPolicy.canAdoptSuccessor(
                    isAutomaticRearm: true,
                    canResetWithoutDiscardingCapture:
                        canResetWithoutDiscardingCapture,
                    hasPreviousCoordination:
                        activeCaptureCoordination != nil,
                    uploadQueueIsEmpty:
                        pendingCoordinatedCaptureUpload == nil
                ) else {
                    synchronizedCapturePhase = .failed
                    isSynchronizedCaptureController = false
                    sendGroupAcknowledgement(
                        command,
                        state: "rejected",
                        partialReason:
                            "automatic_rearm_waiting_for_local_finalization"
                    )
                    return
                }
                releaseSynchronizedSessionOwnership(
                    matching: activeCaptureCoordination
                )
            }
            if command.recoveryReset {
                guard canResetWithoutDiscardingCapture else {
                    synchronizedCapturePhase = .failed
                    isSynchronizedCaptureController = false
                    sendGroupAcknowledgement(
                        command,
                        state: "rejected",
                        partialReason: "recovery_waiting_for_local_capture_finalize"
                    )
                    groupCoordinationStatus =
                        "Recovery blocked — finish preserving local files, then tap again"
                    return
                }
                // A fresh Receiver generation is the authoritative reset
                // boundary. Both phones execute this same path, so stale role
                // locks and scheduled commands cannot survive on either side.
                resetCalibration()
                releaseSynchronizedSessionOwnership(
                    matching: activeCaptureCoordination
                )
            }
            acknowledgementPayloadByCommandKey = acknowledgementPayloadByCommandKey
                .filter { $0.key.hasPrefix("\(command.sessionID):") }
            synchronizedCaptureFallbackArtifacts = nil
            synchronizedPreparationRequestID = nil
            synchronizedCapturePhase = .preparing
            synchronizedCaptureUsesSharedDeviceControl =
                command.sharedDeviceControl
            isSynchronizedCaptureController =
                SynchronizedCaptureControlPolicy.deviceCanControl(
                    controllerKind: command.controllerKind,
                    initiatingDeviceID: command.controllerDeviceID,
                    sharedDeviceControl: command.sharedDeviceControl,
                    controllerCapable: controllerCapable,
                    localDeviceID: captureDeviceID
                )
            guard ensureARSessionRunning() else {
                synchronizedCapturePhase = .failed
                isSynchronizedCaptureController = false
                sendGroupAcknowledgement(
                    command,
                    state: "rejected",
                    partialReason: "camera_unavailable"
                )
                groupCoordinationStatus =
                    "Camera unavailable — group preparation cancelled"
                return
            }
            let wasStarting = isStarting
            guard Self.canBeginGroupPreparation(
                isStreaming: isStreaming,
                isStarting: isStarting,
                isCalibrating: isCalibrating,
                isCalibrationReady: isCalibrationReady,
                isFinalizing: isFinalizingLogicalCapture,
                hasLogicalCapture: logicalCaptureStartedAtUnixMs != nil,
                hasActiveCoordination: activeCaptureCoordination != nil,
                captureRoleLocked: captureRoleLocked
            ) else {
                synchronizedCapturePhase = .failed
                isSynchronizedCaptureController = false
                sendGroupAcknowledgement(
                    command,
                    state: "rejected",
                    partialReason: "capture_flow_already_active"
                )
                return
            }
            guard validateCaptureStart(remoteCommand: nil) else {
                synchronizedCapturePhase = .failed
                isSynchronizedCaptureController = false
                sendGroupAcknowledgement(
                    command,
                    state: "rejected",
                    partialReason: "capture_prerequisites_failed"
                )
                return
            }
            if wasStarting {
                // A Mac-owned Prepare supersedes a local countdown before any
                // logical capture begins. This prevents an unscheduled start.
                cancelLocalStartCue()
            }
            beginCalibration(
                autoStart: false,
                useLocalStartCue: false
            )
            let profile = lockCaptureProfileIfNeeded()
            activeCaptureCoordination = ActiveCaptureCoordination(
                sessionID: command.sessionID,
                generation: command.generation,
                profile: profile,
                clockMappingAtStart: latestClockSample,
                plannedStartCoordinatorNs: nil,
                actualStartLocalNs: nil,
                plannedStopCoordinatorNs: nil,
                actualStopLocalNs: nil,
                firstARFrameTimestampSeconds: nil,
                lastARFrameTimestampSeconds: nil
            )
            pendingGroupPrepareCommand = command
            shouldAutoStartAfterCalibration = false
            shouldUseLocalStartCueAfterCalibration = false
            coordinatedPreparationPhase = .waitingForTracking
            groupCoordinationStatus =
                "Preparing independent local pose streams"
            sendGroupAcknowledgement(command, state: "received")
            return
        }

        guard let deadline = command.coordinatorDeadlineNs else {
            synchronizedCapturePhase = .failed
            isSynchronizedCaptureController = false
            sendGroupAcknowledgement(
                command,
                state: "unsynchronized",
                partialReason: "clock_mapping_unavailable_or_stale"
            )
            return
        }
        guard let sample = validClockSample(),
              let localDeadline = sample.localMonotonicNs(
                forCoordinator: deadline
              )
        else {
            let reason = "clock_mapping_unavailable_or_stale"
            switch SynchronizedCaptureControlPolicy.clockFailureAction(
                for: command.command
            ) {
            case .executeImmediatelyAndMarkUnsynchronized:
                if activeCaptureCoordination?.partialReasons.contains(
                    reason
                ) != true {
                    activeCaptureCoordination?.partialReasons.append(reason)
                }
                if command.command == .stop {
                    activeCaptureCoordination?.plannedStopCoordinatorNs =
                        deadline
                    activeCaptureCoordination?.plannedStopLocalNs = nil
                    synchronizedCapturePhase = .stopping
                }
                executeGroupTransition(
                    command,
                    localDeadlineNs: DispatchTime.now().uptimeNanoseconds,
                    forcedPartialReason: reason
                )
            case .reject:
                synchronizedCapturePhase = .failed
                isSynchronizedCaptureController = false
                sendGroupAcknowledgement(
                    command,
                    state: "unsynchronized",
                    partialReason: reason
                )
            }
            return
        }
        let now = DispatchTime.now().uptimeNanoseconds
        if CaptureCoordinationPolicy.missedDeadline(
            nowNs: now,
            deadlineNs: localDeadline
        ) {
            let reason = "command_arrived_after_deadline"
            switch SynchronizedCaptureControlPolicy.clockFailureAction(
                for: command.command
            ) {
            case .executeImmediatelyAndMarkUnsynchronized:
                if activeCaptureCoordination?.partialReasons.contains(
                    reason
                ) != true {
                    activeCaptureCoordination?.partialReasons.append(reason)
                }
                synchronizedCapturePhase = .stopping
                executeGroupTransition(
                    command,
                    localDeadlineNs: now,
                    forcedPartialReason: reason
                )
            case .reject:
                synchronizedCapturePhase = .failed
                isSynchronizedCaptureController = false
                sendGroupAcknowledgement(
                    command,
                    state: "unsynchronized",
                    partialReason: reason
                )
            }
            return
        }
        if command.command == .start {
            guard captureRoleLocked,
                  isCalibrationReady,
                  validateCaptureStart(remoteCommand: nil)
            else {
                synchronizedCapturePhase = .failed
                isSynchronizedCaptureController = false
                sendGroupAcknowledgement(
                    command,
                    state: "rejected",
                    partialReason: "device_not_armed"
                )
                return
            }
        }
        scheduledGroupTransition?.cancel()
        pendingFrameBoundaryTransition = nil
        if command.command == .start {
            synchronizedCapturePhase = .starting
            activeCaptureCoordination?.clockMappingAtStart = sample
            activeCaptureCoordination?.plannedStartCoordinatorNs = deadline
            activeCaptureCoordination?.plannedStartLocalNs = localDeadline
        } else if command.command == .stop {
            synchronizedCapturePhase = .stopping
            activeCaptureCoordination?.clockMappingAtStop = sample
            activeCaptureCoordination?.plannedStopCoordinatorNs = deadline
            activeCaptureCoordination?.plannedStopLocalNs = localDeadline
        }
        sendGroupAcknowledgement(command, state: "scheduled")
        let remaining = localDeadline > now ? localDeadline - now : 0
        if command.command == .stop {
            pendingStopCommitTransition = PendingFrameBoundaryTransition(
                command: command,
                localDeadlineNs: localDeadline
            )
            groupCoordinationStatus =
                "Stop requested — waiting for both devices to acknowledge the boundary"
            return
        }
        if SynchronizedFrameBoundaryPolicy.usesARFrameBoundary(
            for: command.command
        ) {
            pendingFrameBoundaryTransition = PendingFrameBoundaryTransition(
                command: command,
                localDeadlineNs: localDeadline
            )
            let fallback = DispatchWorkItem { [weak self] in
                guard let self,
                      self.pendingFrameBoundaryTransition?.command.commandID
                        == command.commandID
                else { return }
                self.pendingFrameBoundaryTransition = nil
                self.executeGroupTransition(
                    command,
                    localDeadlineNs: localDeadline
                )
            }
            scheduledGroupTransition = fallback
            let fallbackDelay = remaining
                + SynchronizedFrameBoundaryPolicy.missingFrameFallbackDelayNs
            DispatchQueue.main.asyncAfter(
                deadline: .now()
                    + .nanoseconds(Int(clamping: fallbackDelay)),
                execute: fallback
            )
            return
        }
        let work = DispatchWorkItem { [weak self] in
            self?.executeGroupTransition(
                command,
                localDeadlineNs: localDeadline
            )
        }
        scheduledGroupTransition = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + .nanoseconds(Int(clamping: remaining)),
            execute: work
        )
    }

    private func executeGroupTransition(
        _ command: GroupCaptureCommand,
        localDeadlineNs: UInt64,
        actualLocalNs: UInt64? = nil,
        isARFrameBoundary: Bool = false,
        forcedPartialReason: String? = nil
    ) {
        let actual = actualLocalNs
            ?? DispatchTime.now().uptimeNanoseconds
        let missedDeadline = CaptureCoordinationPolicy.missedDeadline(
            nowNs: actual,
            deadlineNs: localDeadlineNs
        )
        switch command.command {
        case .prepare:
            return
        case .start:
            guard !missedDeadline || isARFrameBoundary else {
                synchronizedCapturePhase = .failed
                isSynchronizedCaptureController = false
                sendGroupAcknowledgement(
                    command,
                    state: "unsynchronized",
                    actualLocalNs: actual,
                    partialReason: "scheduled_deadline_missed"
                )
                return
            }
            guard captureRoleLocked,
                  isCalibrationReady,
                  validateCaptureStart(remoteCommand: nil)
            else {
                synchronizedCapturePhase = .failed
                isSynchronizedCaptureController = false
                sendGroupAcknowledgement(
                    command,
                    state: "rejected",
                    partialReason: "device_not_armed"
                )
                return
            }
            activeCaptureCoordination?.plannedStartCoordinatorNs =
                command.coordinatorDeadlineNs
            activeCaptureCoordination?.actualStartLocalNs = actual
            startStreamingImmediately(origin: .remote)
            synchronizedCapturePhase = .running
            synchronizedBoundaryFeedbackController.play(
                command: .start,
                commandID: command.commandID
            )
            sendGroupAcknowledgement(
                command,
                state: "started",
                actualLocalNs: actual
            )
        case .pause, .resume:
            synchronizedCapturePhase = .failed
            sendGroupAcknowledgement(
                command,
                state: "rejected",
                actualLocalNs: actual,
                partialReason: "pause_resume_not_supported"
            )
        case .stop:
            let partialReason = SynchronizedStopBoundaryPolicy.partialReason(
                forcedPartialReason: forcedPartialReason,
                missedDeadline: missedDeadline,
                isARFrameBoundary: isARFrameBoundary
            )
            if let partialReason,
               activeCaptureCoordination?.partialReasons.contains(
                   partialReason
               ) != true {
                activeCaptureCoordination?.partialReasons.append(partialReason)
            }
            activeCaptureCoordination?.plannedStopCoordinatorNs =
                command.coordinatorDeadlineNs
            activeCaptureCoordination?.actualStopLocalNs = actual
            synchronizedCapturePhase = .finalizing
            groupCoordinationStatus = "Stop boundary reached — draining frames"
            if partialReason == nil {
                synchronizedBoundaryFeedbackController.play(
                    command: .stop,
                    commandID: command.commandID
                )
            }
            sendGroupAcknowledgement(
                command,
                state: "finalizing",
                actualLocalNs: actual,
                partialReason: partialReason
            )
            DispatchQueue.main.asyncAfter(
                deadline: .now() + .nanoseconds(
                    Int(clamping: CaptureCoordinationPolicy.frameDrainGraceNs)
                )
            ) { [weak self] in
                guard let self else { return }
                self.activeCaptureCoordination?
                    .stopFinalizationStartedLocalNs =
                        DispatchTime.now().uptimeNanoseconds
                self.groupCoordinationStatus = "Finalizing local artifacts"
                self.finalizeLogicalCapture(
                    rgbFinishReason: .stop,
                    commandID: command.commandID
                ) { [weak self] artifacts in
                    guard let self else { return }
                    let coordinationSnapshot = self.activeCaptureCoordination
                    let recordedPartialReason = partialReason
                        ?? coordinationSnapshot?.partialReasons.first
                    self.groupCoordinationStatus =
                        "Local files saved — verifying artifact hashes"
                    DispatchQueue.global(qos: .utility).async {
                        [weak controller = self, artifacts] in
                        let references = ViewController.artifactReferences(
                            from: artifacts
                        )
                        DispatchQueue.main.async { [weak controller] in
                            guard let controller,
                                  !references.isEmpty,
                                  let packageURL = artifacts.exportPackageURL
                            else {
                                controller?.publishSynchronizedCaptureFallback(
                                    artifacts,
                                    receiverUploadSucceeded: false
                                )
                                controller?.sendGroupAcknowledgement(
                                    command, state: "rejected", actualLocalNs: actual,
                                    artifacts: references,
                                    partialReason: "finalized_artifact_reference_missing"
                                )
                                controller?.groupCoordinationStatus =
                                    "Partial — local artifacts incomplete"
                                controller?.synchronizedCapturePhase = .failed
                                return
                            }
                            controller.sendGroupAcknowledgement(
                                command,
                                state: "finalized",
                                actualLocalNs: actual,
                                artifacts: references,
                                partialReason: recordedPartialReason
                            )
                            guard recordedPartialReason == nil else {
                                controller.pendingCoordinatedCaptureUpload = nil
                                controller.coordinatedCaptureUploadAuthorization = nil
                                controller.cancelAuthorizedCoordinatedCaptureUploadRetry()
                                controller.publishSynchronizedCaptureFallback(
                                    artifacts,
                                    receiverUploadSucceeded: false
                                )
                                controller.groupCoordinationStatus =
                                    "Synchronization failed — ZIP kept on this phone and was not uploaded"
                                controller.synchronizedCapturePhase = .failed
                                controller.isSynchronizedCaptureController = false
                                controller.releaseSynchronizedSessionOwnership(
                                    matching: coordinationSnapshot
                                )
                                return
                            }
                            controller.pendingCoordinatedCaptureUpload =
                                PendingCoordinatedCaptureUpload(
                                    retryID: UUID(),
                                    command: command,
                                    actualLocalNs: actual,
                                    artifacts: artifacts,
                                    references: references,
                                    packageURL: packageURL,
                                    coordinationSnapshot: coordinationSnapshot,
                                    host: controller.hostIP,
                                    port: controller.hostPort,
                                    pairingToken:
                                        controller.receiverPairingToken
                                )
                            controller.groupCoordinationStatus =
                                "Local ZIP saved — waiting for both Stop boundaries before upload"
                            controller.synchronizedCapturePhase = .finalizing
                            controller.retryAuthorizedCoordinatedCaptureUpload()
                        }
                    }
                }
            }
        }
    }

    private func authorizePendingStopCommit() {
        guard let pending = pendingStopCommitTransition else { return }
        pendingStopCommitTransition = nil
        let now = DispatchTime.now().uptimeNanoseconds
        let minimumCommitGuardNs: UInt64 = 250_000_000
        guard pending.localDeadlineNs > now + minimumCommitGuardNs else {
            synchronizedCapturePhase = .running
            groupCoordinationStatus =
                "Stop synchronization failed — commit arrived too late; capture continues and no ZIP will upload"
            sendGroupAcknowledgement(
                pending.command,
                state: "unsynchronized",
                actualLocalNs: now,
                partialReason: "stop_commit_arrived_too_late"
            )
            return
        }
        let remaining = pending.localDeadlineNs - now
        pendingFrameBoundaryTransition = pending
        let fallback = DispatchWorkItem { [weak self] in
            guard let self,
                  self.pendingFrameBoundaryTransition?.command.commandID
                    == pending.command.commandID
            else { return }
            self.pendingFrameBoundaryTransition = nil
            self.executeGroupTransition(
                pending.command,
                localDeadlineNs: pending.localDeadlineNs
            )
        }
        scheduledGroupTransition = fallback
        let fallbackDelay = remaining
            + SynchronizedFrameBoundaryPolicy.missingFrameFallbackDelayNs
        DispatchQueue.main.asyncAfter(
            deadline: .now()
                + .nanoseconds(Int(clamping: fallbackDelay)),
            execute: fallback
        )
        groupCoordinationStatus =
            "Both devices acknowledged Stop — synchronized boundary committed"
    }

    private func lockCaptureProfileIfNeeded() -> CaptureProfileSnapshot {
        if let lockedCaptureProfile { return lockedCaptureProfile }
        persistCaptureIdentityFields()
        let profile = CaptureProfileSnapshot.make(
            deviceID: captureDeviceID,
            profileID: captureProfileID,
            gripperID: gripperID,
            calibrationID: calibrationID,
            lockedAtLocalMonotonicNs: DispatchTime.now().uptimeNanoseconds
        )
        lockedCaptureProfile = profile
        captureRoleLocked = true
        return profile
    }

    private func validClockSample() -> CaptureClockMappingSample? {
        guard let latestClockSample else { return nil }
        let age = latestClockSample.ageNs(
            nowLocalMonotonicNs: DispatchTime.now().uptimeNanoseconds
        )
        guard age <= CaptureCoordinationPolicy.maximumClockSampleAgeNs,
              latestClockSample.uncertaintyNs
                <= CaptureCoordinationPolicy.maximumClockUncertaintyNs
        else { return nil }
        return latestClockSample
    }

    private func sendGroupAcknowledgement(
        _ command: GroupCaptureCommand,
        state: String,
        actualLocalNs: UInt64? = nil,
        artifacts: [[String: Any]]? = nil,
        partialReason: String? = nil,
        preparation: [String: Any]? = nil
    ) {
        commandLedger.record(state: state, for: command)
        var payload: [String: Any] = [
            "protocol_version": CaptureCoordinationProtocol.version,
            "command": command.command.rawValue,
            "command_id": command.commandID,
            "session_id": command.sessionID,
            "generation": command.generation,
            "device_id": captureDeviceID,
            "state": state
        ]
        if let deadline = command.coordinatorDeadlineNs {
            payload["planned_coordinator_monotonic_ns"] = String(deadline)
        }
        if let actualLocalNs {
            payload["actual_local_monotonic_ns"] = String(actualLocalNs)
            let mapping = validClockSample()
                ?? activeCaptureCoordination?.clockMappingAtStop
                ?? activeCaptureCoordination?.clockMappingAtStart
            if let actualCoordinatorNs = mapping?.coordinatorMonotonicNs(
                forLocal: actualLocalNs
            ) {
                payload["actual_coordinator_monotonic_ns"] =
                    String(actualCoordinatorNs)
            }
        }
        if let activeCaptureCoordination {
            payload["first_arkit_timestamp_s"] =
                activeCaptureCoordination.firstARFrameTimestampSeconds
            payload["last_arkit_timestamp_s"] =
                activeCaptureCoordination.lastARFrameTimestampSeconds
            payload["planned_start_local_ns"] =
                activeCaptureCoordination.plannedStartLocalNs.map(String.init)
            payload["planned_stop_local_ns"] =
                activeCaptureCoordination.plannedStopLocalNs.map(String.init)
            payload["first_frame_coordinator_monotonic_ns"] =
                activeCaptureCoordination.firstFrameCoordinatorNs.map(String.init)
            payload["last_frame_coordinator_monotonic_ns"] =
                activeCaptureCoordination.lastFrameCoordinatorNs.map(String.init)
            payload["rejected_frames_before_start"] =
                activeCaptureCoordination.rejectedFramesBeforeStart ?? 0
            payload["rejected_frames_at_or_after_stop"] =
                activeCaptureCoordination.rejectedFramesAtOrAfterStop ?? 0
        }
        if let sample = validClockSample() {
            payload["clock"] = [
                "offset_ns": String(sample.offsetNs),
                "rtt_ns": String(sample.rttNs),
                "uncertainty_ns": String(sample.uncertaintyNs),
                "sample_age_ns": String(
                    sample.ageNs(
                        nowLocalMonotonicNs:
                            DispatchTime.now().uptimeNanoseconds
                    )
                )
            ]
        }
        if let artifacts { payload["artifacts"] = artifacts }
        if let partialReason { payload["partial_reason"] = partialReason }
        if let preparation { payload["preparation"] = preparation }
        acknowledgementPayloadByCommandKey[
            "\(command.sessionID):\(command.commandID)"
        ] = payload
        socketClient.sendGroupAcknowledgement(payload)
    }

    private func recordSynchronizedPartialReason(_ reason: String) {
        guard activeCaptureCoordination != nil,
              activeCaptureCoordination?.partialReasons.contains(reason) != true
        else { return }
        activeCaptureCoordination?.partialReasons.append(reason)
    }

    private func publishSynchronizedCaptureFallback(
        _ artifacts: CompletedCaptureArtifacts,
        receiverUploadSucceeded: Bool?
    ) {
        guard CapturePackagePresentationPolicy.shouldPresentManualFallback(
            isCoordinatedCapture: true,
            receiverUploadSucceeded: receiverUploadSucceeded
        ) else { return }
        synchronizedCaptureFallbackArtifacts = artifacts
    }

    private func commitPendingCoordinatedCaptureUpload(
        sessionID: String?,
        generation: Int?
    ) {
        guard let pending = pendingCoordinatedCaptureUpload,
              pending.command.sessionID == sessionID,
              pending.command.generation == generation,
              !coordinatedCaptureUploadInProgress
        else { return }
        let authorization = CoordinatedCaptureUploadAuthorization(
            sessionID: pending.command.sessionID,
            generation: pending.command.generation
        )
        guard coordinatedCaptureUploadAuthorization == authorization else {
            return
        }
        cancelAuthorizedCoordinatedCaptureUploadRetry()
        coordinatedCaptureUploadInProgress = true
        captureFinalizationStage = .uploading
        groupCoordinationStatus =
            "Both Stop boundaries verified — uploading ZIP to Mac…"
        capturePackageUploader.upload(
            fileURL: pending.packageURL,
            expectedIdentity:
                pending.artifacts.exportPackageIdentity,
            host: pending.host,
            port: pending.port,
            deviceID: captureDeviceID,
            pairingToken: pending.pairingToken
        ) { [weak self] result in
            guard let self else { return }
            guard self.pendingCoordinatedCaptureUpload?.retryID
                    == pending.retryID
            else { return }
            coordinatedCaptureUploadInProgress = false
            var uploadedReferences = pending.references
            switch result {
            case .success(let receipt):
                captureFinalizationStage = .completed
                pendingCoordinatedCaptureUpload = nil
                coordinatedCaptureUploadAuthorization = nil
                cancelAuthorizedCoordinatedCaptureUploadRetry()
                publishCaptureUploadSuccess(
                    filename: pending.packageURL.lastPathComponent
                )
                synchronizedCaptureFallbackArtifacts = nil
                if let index = uploadedReferences.firstIndex(
                    where: {
                        $0["name"] as? String
                            == pending.packageURL.lastPathComponent
                    }
                ) {
                    uploadedReferences[index]["receiver_upload_complete"] = true
                    uploadedReferences[index]["upload_id"] = receipt.uploadID
                    if let path = receipt.storedPath {
                        uploadedReferences[index]["receiver_stored_path"] = path
                    }
                }
                sendGroupAcknowledgement(
                    pending.command,
                    state: "finalized",
                    actualLocalNs: pending.actualLocalNs,
                    artifacts: uploadedReferences
                )
                groupCoordinationStatus =
                    "ZIP uploaded after synchronized Stop verification — waiting for peer"
                synchronizedCapturePhase = .finalizing
            case .failure(let error):
                publishSynchronizedCaptureFallback(
                    pending.artifacts,
                    receiverUploadSucceeded: false
                )
                if CapturePackageUploadError
                    .isRetryableInterruption(error) {
                    captureFinalizationStage = .waitingUploadAuthorization
                    groupCoordinationStatus =
                        "Upload interrupted — ZIP kept on phone; retrying the authorized transfer"
                    synchronizedCapturePhase = .finalizing
                    scheduleAuthorizedCoordinatedCaptureUploadRetry()
                    return
                }
                pendingCoordinatedCaptureUpload = nil
                captureFinalizationStage = .failed
                coordinatedCaptureUploadAuthorization = nil
                cancelAuthorizedCoordinatedCaptureUploadRetry()
                recordSynchronizedPartialReason("capture_upload_failed")
                sendGroupAcknowledgement(
                    pending.command,
                    state: "rejected",
                    actualLocalNs: pending.actualLocalNs,
                    artifacts: pending.references,
                    partialReason: "capture_upload_failed"
                )
                groupCoordinationStatus =
                    "Upload failed — ZIP kept on phone: \(error.localizedDescription)"
                synchronizedCapturePhase = .failed
                isSynchronizedCaptureController = false
                releaseSynchronizedSessionOwnership(
                    matching: pending.coordinationSnapshot
                )
            }
        }
    }

    private func acceptFrozenCoordinatedUploadGrantReplay(
        from payload: [String: Any]
    ) {
        guard !hasAuthorizedCoordinatedCaptureUpload,
              let pending = pendingCoordinatedCaptureUpload,
              let grants = payload["frozen_upload_grants_by_device"]
                as? [String: Any],
              let grant = grants[captureDeviceID] as? [String: Any]
        else { return }
        let packageReferences = pending.references.filter {
            $0["name"] as? String == pending.packageURL.lastPathComponent
        }
        guard packageReferences.count == 1,
              let identity = CoordinatedCaptureUploadFileIdentity(
                  artifactReference: packageReferences[0],
                  deviceID: captureDeviceID
              ),
              FrozenCoordinatedUploadGrantReplayPolicy.authorizes(
                  grant: grant,
                  expectedSessionID: pending.command.sessionID,
                  expectedGeneration: pending.command.generation,
                  expectedIdentity: identity
              )
        else { return }
        coordinatedCaptureUploadAuthorization =
            CoordinatedCaptureUploadAuthorization(
                sessionID: pending.command.sessionID,
                generation: pending.command.generation
            )
        synchronizedCapturePhase = .finalizing
        groupCoordinationStatus =
            "Receiver restored the exact frozen ZIP grant — resuming upload"
        retryAuthorizedCoordinatedCaptureUpload()
    }

    private var hasAuthorizedCoordinatedCaptureUpload: Bool {
        guard let pending = pendingCoordinatedCaptureUpload else {
            return false
        }
        return coordinatedCaptureUploadAuthorization
            == CoordinatedCaptureUploadAuthorization(
                sessionID: pending.command.sessionID,
                generation: pending.command.generation
            )
    }

    private func retryAuthorizedCoordinatedCaptureUpload() {
        guard hasAuthorizedCoordinatedCaptureUpload,
              let pending = pendingCoordinatedCaptureUpload
        else { return }
        commitPendingCoordinatedCaptureUpload(
            sessionID: pending.command.sessionID,
            generation: pending.command.generation
        )
    }

    private func scheduleAuthorizedCoordinatedCaptureUploadRetry() {
        guard hasAuthorizedCoordinatedCaptureUpload,
              coordinatedCaptureUploadRetryWorkItem == nil
        else { return }
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.coordinatedCaptureUploadRetryWorkItem = nil
            self.retryAuthorizedCoordinatedCaptureUpload()
        }
        coordinatedCaptureUploadRetryWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + 15,
            execute: workItem
        )
    }

    private func cancelAuthorizedCoordinatedCaptureUploadRetry() {
        coordinatedCaptureUploadRetryWorkItem?.cancel()
        coordinatedCaptureUploadRetryWorkItem = nil
    }

    private func publishCaptureUploadSuccess(filename: String) {
        captureUploadNoticeGeneration += 1
        let generation = captureUploadNoticeGeneration
        captureUploadSuccessNotice = CaptureUploadSuccessNotice(
            destination: CaptureUploadSuccessNoticePolicy.destinationLabel(
                receiverDisplayName: selectedReceiverDisplayName,
                host: hostIP
            ),
            filename: filename
        )
        DispatchQueue.main.asyncAfter(
            deadline: .now()
                + CaptureUploadSuccessNoticePolicy.displayDuration
        ) { [weak self] in
            guard let self,
                  self.captureUploadNoticeGeneration == generation
            else { return }
            self.captureUploadSuccessNotice = nil
        }
    }

    static func artifactReferences(
        from artifacts: CompletedCaptureArtifacts
    ) -> [[String: Any]] {
        let urls: [URL]
        if let packageURL = artifacts.exportPackageURL {
            // The ZIP is the immutable upload unit and already contains the
            // trajectory, video, timestamps, and integrity manifest. Avoid
            // hashing every source artifact again after package creation.
            urls = [packageURL]
        } else {
            urls = [artifacts.trajectoryURL].compactMap { $0 }
                + artifacts.rgbVideoURLs
        }
        var paths: Set<String> = []
        return urls.compactMap { url in
            let standardizedPath = url.standardizedFileURL.path
            guard paths.insert(standardizedPath).inserted,
                  let attributes = try? FileManager.default
                    .attributesOfItem(atPath: url.path),
                  let size = attributes[.size] as? NSNumber
            else { return nil }
            let isExportPackage = artifacts.exportPackageURL?
                .standardizedFileURL.path == standardizedPath
            let cachedIdentity = isExportPackage
                ? artifacts.exportPackageIdentity
                : nil
            guard cachedIdentity == nil
                    || cachedIdentity?.sizeBytes == size.uint64Value,
                  let digest = cachedIdentity?.sha256
                    ?? streamSHA256(url: url)
            else { return nil }
            return [
                "artifact_id": url.deletingPathExtension().lastPathComponent,
                "name": url.lastPathComponent,
                "sha256": digest,
                "size_bytes": size.uint64Value,
                "platform": "iOS"
            ]
        }
    }

    private static func streamSHA256(url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }
        defer { try? handle.close() }
        var hasher = SHA256()
        do {
            while let data = try autoreleasepool(invoking: {
                try handle.read(upToCount: 1_048_576)
            }), !data.isEmpty {
                hasher.update(data: data)
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        } catch {
            return nil
        }
    }

    private func sendRemoteCaptureStatus(
        _ command: RemoteCaptureCommand,
        state: String
    ) {
        socketClient.sendCaptureStatus(
            command: command,
            state: state,
            arFrameTimestamp: prevTimestamp
        )
    }

    private func setupRGBVideoRecorder() {
        rgbVideoRecorder.onStatusChange = { [weak self] status in
            self?.rgbRecorderStatus = status
        }
        rgbVideoRecorder.onRecordingFinalized = { [weak self] videoURL in
            guard videoURL.lastPathComponent == "rgb.mp4" else {
                return
            }
            self?.captureLibrary.registerFinalizedRGB(
                videoURL: videoURL
            )
        }
    }

    private func observeApplicationLifecycle() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidReceiveMemoryWarning),
            name: UIApplication.didReceiveMemoryWarningNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(processThermalStateDidChange),
            name: ProcessInfo.thermalStateDidChangeNotification,
            object: nil
        )
    }

    @objc private func applicationDidReceiveMemoryWarning() {
        safelyStopForResourcePressure(
            reason: "memory_pressure",
            finishReason: .memoryPressure
        )
    }

    @objc private func processThermalStateDidChange() {
        guard ProcessInfo.processInfo.thermalState == .critical else {
            return
        }
        safelyStopForResourcePressure(
            reason: "thermal_critical",
            finishReason: .thermalCritical
        )
    }

    private func observeOrientation() {
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(deviceOrientationDidChange),
            name: UIDevice.orientationDidChangeNotification,
            object: nil
        )
    }

    @objc private func deviceOrientationDidChange() {
        DispatchQueue.main.asyncAfter(
            deadline: .now() + 0.1
        ) { [weak self] in
            self?.updateInterfaceOrientation(enforce: true)
        }
    }

    private func updateInterfaceOrientation(
        enforce: Bool,
        requestWindowRotation: Bool = true
    ) {
        let orientation = resolvedInterfaceOrientation()
        currentInterfaceOrientation = orientation
        if requestWindowRotation,
           captureInterfaceOrientationLock == nil,
           UMICaptureOrientation.isValid(orientation) {
            requestInterfaceOrientation(orientation)
        }
        if UMICaptureOrientation.isValid(orientation),
           let lockedOrientation = captureInterfaceOrientationLock,
           orientation != lockedOrientation {
            if isStreaming,
               !enforcesRuntimeInterfaceOrientationLock {
                return
            }
            handleCaptureOrientationMismatch()
            return
        }
        guard enforce,
              !UMICaptureOrientation.isValid(orientation)
        else {
            return
        }

        if isStreaming {
            guard enforcesRuntimeInterfaceOrientationLock
            else { return }
            recordSynchronizedPartialReason("unsupported_device_orientation")
            if synchronizedCapturePhase.isSessionActive {
                calibrationStatus =
                    "Recording — orientation changed; synchronized capture marked partial"
                return
            }
            interruptCapture(
                rgbFinishReason: .orientationChanged
            )
            calibrationStatus =
                "Capture interrupted — End to save"
        } else if isStarting || isCalibrating {
            interruptCapture()
            calibrationStatus =
                "Preparation cancelled — unsupported device orientation"
        }
    }

    private func handleCaptureOrientationMismatch() {
        if isStreaming {
            guard enforcesRuntimeInterfaceOrientationLock
            else { return }
            recordSynchronizedPartialReason("capture_orientation_changed")
            if synchronizedCapturePhase.isSessionActive {
                calibrationStatus =
                    "Recording — return phone to its prepared orientation"
                return
            }
            interruptCapture(
                rgbFinishReason: .orientationChanged
            )
            calibrationStatus =
                "Capture interrupted — End to save"
            return
        }

        if isStarting {
            beginCalibration(
                autoStart: true,
                useLocalStartCue: true
            )
            calibrationStatus =
                "Preparation restarted — phone orientation changed"
            return
        }

        if isCalibrationReady,
           logicalCaptureStartedAtUnixMs == nil {
            let autoStart = shouldAutoStartAfterCalibration
            let useLocalCue =
                shouldUseLocalStartCueAfterCalibration
            beginCalibration(
                autoStart: autoStart,
                useLocalStartCue: useLocalCue
            )
            calibrationStatus =
                "Preparation restarted — phone orientation changed"
            return
        }

        if logicalCaptureStartedAtUnixMs != nil {
            calibrationStatus =
                "Capture interrupted — End to save"
        }
    }

    private func resolvedInterfaceOrientation()
        -> UIInterfaceOrientation {
        let deviceOrientation =
            UMICaptureOrientation.captureOrientation(
                from: UIDevice.current.orientation
            )
        return UMICaptureOrientation.resolvedInterfaceOrientation(
            deviceOrientation: deviceOrientation,
            sceneOrientation:
                view.window?.windowScene?.interfaceOrientation,
            lockedOrientation: captureInterfaceOrientationLock
        )
    }

    private func requestInterfaceOrientation(
        _ orientation: UIInterfaceOrientation
    ) {
        guard let orientationMask =
                UMICaptureOrientation.interfaceOrientationMask(
                    for: orientation
                ),
              let windowScene = view.window?.windowScene
        else {
            return
        }

        guard windowScene.interfaceOrientation != orientation else {
            return
        }

        setNeedsUpdateOfSupportedInterfaceOrientations()
        if #available(iOS 16.0, *) {
            let preferences =
                UIWindowScene.GeometryPreferences.iOS(
                    interfaceOrientations: orientationMask
                )
            windowScene.requestGeometryUpdate(
                preferences
            ) { error in
                print(
                    "Interface orientation update failed: "
                        + error.localizedDescription
                )
            }
        } else {
            UIViewController.attemptRotationToDeviceOrientation()
        }
    }

    @objc private func applicationDidEnterBackground() {
        setHardwareCaptureCameraReady(false)
        let wasStarting = isStarting
        cancelLocalStartCue()
        beginRGBBackgroundFinalization()
        finishCurrentRGBSegment(
            reason: .appBackground
        ) { [weak self] _ in
            self?.endRGBBackgroundFinalization()
        }
        if isStreaming {
            recordSynchronizedPartialReason("app_background")
            isStreaming = false
            if activeCaptureCoordination != nil {
                synchronizedCapturePhase = .failed
            }
            calibrationStatus = "Capture interrupted — End to save"
        } else if wasStarting {
            calibrationStatus = "Capture interrupted — End to save"
        } else if isCalibrating {
            failPendingGroupPreparation(
                reason: "preparation_cancelled_in_background"
            )
            isCalibrating = false
            isCalibrationReady = false
            readinessEvaluator.reset()
            needsNewRecordingOnStart = false
            pendingRemoteStartCommand = nil
            calibrationStatus =
                "Preparation cancelled — app entered background"
        }
        suspendARSession()
    }

    @objc private func applicationDidBecomeActive() {
        // Wait for a fresh ARFrame instead of trusting session.currentFrame,
        // which can still refer to the last frame from a suspended session.
        setHardwareCaptureCameraReady(false)
        socketClient.ensureConnected()
        retryAuthorizedCoordinatedCaptureUpload()
        _ = ensureARSessionRunning()
    }

    func setupARSession() {
        connectSocketClient()
        session.delegateQueue = .main
        session.delegate = self
        applyCameraModeAndRestartSession()
    }

    private func connectSocketClient() {
        let registration = coordinationRegistrationPayload()
        socketClient.connect(
            hostIP: hostIP,
            hostPort: hostPort,
            pairingToken: receiverPairingToken,
            registrationPayload: registration
        )
    }

    private func refreshCoordinationRegistration() {
        guard !captureRoleLocked else { return }
        socketClient.updateCoordinationRegistration(
            coordinationRegistrationPayload()
        )
    }

    private func coordinationRegistrationPayload() -> [String: Any] {
        let profile = CaptureProfileSnapshot.make(
            deviceID: captureDeviceID,
            profileID: captureProfileID,
            gripperID: gripperID,
            calibrationID: calibrationID,
            lockedAtLocalMonotonicNs:
                DispatchTime.now().uptimeNanoseconds
        )
        var calibration: [String: Any] = [
            "kind": profile.calibration.kind.rawValue,
            "status": profile.calibration.status.rawValue
        ]
        if let calibrationID = profile.calibration.calibrationID {
            calibration["calibration_id"] = calibrationID
        }
        var registration: [String: Any] = [
            "protocol_version": CaptureCoordinationProtocol.version,
            "device_id": captureDeviceID,
            "display_name": coordinationDisplayName(),
            "capture_role": profile.captureRole.rawValue,
            "profile_id": profile.profileID.rawValue,
            "controller_capable": controllerCapable,
            "calibration": calibration,
            "client_metadata": SoftwareProvenance.current().clientMetadata
        ]
        if let gripperID = profile.gripperID {
            registration["gripper_id"] = gripperID
        }
        return registration
    }

    private func coordinationDisplayName() -> String {
        let base = "UMI Capture · " + UIDevice.current.name
        var scalars = String.UnicodeScalarView()
        for scalar in base.unicodeScalars
        where scalars.count < 128
            && !CharacterSet.controlCharacters.contains(scalar) {
            scalars.append(scalar)
        }
        return String(scalars)
    }

    func prepareVIOForCaptureShare() {
        guard !isStreaming,
              !isCalibrating,
              !isStarting,
              !isFinalizingLogicalCapture,
              !isVIOSuspendedForCaptureShare
        else { return }
        isVIOSuspendedForCaptureShare = true
        suspendARSession()
    }

    func restoreVIOAfterCaptureShare() {
        guard isVIOSuspendedForCaptureShare,
              isViewLoaded
        else { return }
        isVIOSuspendedForCaptureShare = false
        applyCameraModeAndRestartSession()
    }

    func requestRGBCameraMode(
        _ mode: RGBCameraMode
    ) {
        guard mode != rgbCameraMode else {
            return
        }
        guard availableRGBCameraModes.contains(mode) else {
            rgbVideoFormatError =
                "\(mode.shortLabel) is not exposed by ARKit world tracking "
                + "on this device."
            return
        }
        guard canSwitchRGBCamera else {
            rgbVideoFormatError =
                "Lens selection is locked until the current "
                + "capture is ended or reset."
            return
        }
        rgbCameraMode = mode
        UserDefaults.standard.set(
            mode.rawValue,
            forKey: "UMICapture.rgbCameraMode"
        )
        applyCameraModeAndRestartSession()
    }

    private func applyCameraModeAndRestartSession() {
        setHardwareCaptureCameraReady(false)
        session.pause()
        isARSessionRunning = false

        let supportedFormats =
            ARWorldTrackingConfiguration.supportedVideoFormats
        refreshAvailableRGBCameraModes(from: supportedFormats)
        if !availableRGBCameraModes.contains(rgbCameraMode),
           let fallbackMode = availableRGBCameraModes.first {
            let unavailableMode = rgbCameraMode
            rgbCameraMode = fallbackMode
            UserDefaults.standard.set(
                fallbackMode.rawValue,
                forKey: "UMICapture.rgbCameraMode"
            )
            print(
                "Saved \(unavailableMode.shortLabel) mode is unavailable to "
                    + "ARKit world tracking; using "
                    + "\(fallbackMode.shortLabel)."
            )
        }
        do {
            let selectedFormat = try ARVideoFormatSelector.select(
                from: supportedFormats,
                cameraMode: rgbCameraMode
            )
            selectedRGBVideoFormat = selectedFormat
            rgbVideoFormatDescription =
                selectedFormat.displayDescription
            rgbVideoFormatError = nil
            resetCalibration()
            guard ensureARSessionRunning() else {
                calibrationStatus =
                    "\(rgbCameraMode.shortLabel) physical lens unavailable"
                return
            }
        } catch {
            selectedRGBVideoFormat = nil
            rgbVideoFormatDescription =
                "\(rgbCameraMode.shortLabel) unavailable"
            rgbVideoFormatError = error.localizedDescription
            resetCalibration()
            calibrationStatus =
                "\(rgbCameraMode.shortLabel) physical lens unavailable"
        }
    }

    @discardableResult
    private func ensureARSessionRunning() -> Bool {
        guard !isVIOSuspendedForCaptureShare else { return false }
        guard !isARSessionRunning else { return true }
        guard let selectedRGBVideoFormat else { return false }

        let configuration = ARWorldTrackingConfiguration()
        configuration.worldAlignment = .gravity
        configuration.videoFormat = selectedRGBVideoFormat.format
        ultrawidePoseTimeline = UltrawidePoseTimeline()
        lastUltrawideObservationTimestamp = nil
        lastUltrawideStatusPublishTimestamp = nil
        ultrawideObservationStatus = .checking
        latestTrackingIsNormal = false
        setHardwareCaptureCameraReady(false)
        session.run(
            configuration,
            options: [
                .resetTracking,
                .removeExistingAnchors
            ]
        )
        isARSessionRunning = true
        return true
    }

    private func enterWarmIdle() {
        guard !isStreaming, !isCalibrating, !isStarting else { return }
        rgbVideoRecorder.releaseTransientCaches()
        ultrawidePoseTimeline = UltrawidePoseTimeline()
        lastUltrawideObservationTimestamp = nil
        lastUltrawideStatusPublishTimestamp = nil
        ultrawideObservationStatus = .checking
        latestTrackingIsNormal = false
        refreshPerformanceSnapshot()
    }

    private func suspendARSession() {
        setHardwareCaptureCameraReady(false)
        if isARSessionRunning {
            session.pause()
            isARSessionRunning = false
        }
        rgbVideoRecorder.releaseTransientCaches()
        ultrawidePoseTimeline = UltrawidePoseTimeline()
        lastUltrawideObservationTimestamp = nil
        lastUltrawideStatusPublishTimestamp = nil
        ultrawideObservationStatus = .checking
        latestTrackingIsNormal = false
        refreshPerformanceSnapshot()
    }

    private func refreshAvailableRGBCameraModes(
        from formats: [ARConfiguration.VideoFormat]
    ) {
        let usableModes = RGBCameraMode.allCases.filter { mode in
            (try? ARVideoFormatSelector.select(
                from: formats,
                cameraMode: mode
            )) != nil
        }
        availableRGBCameraModes = usableModes
    }

    func subscribeToActionStream() {
        CaptureActionBus.shared
            .publisher
            .sink { [weak self] action in
                DispatchQueue.main.async {
                    self?.handleLocalAction(action)
                }
            }
            .store(in: &cancellables)
    }

    private func handleLocalAction(_ action: ARAction) {
        switch action {
        case .update(let ip, let port):
            socketClient.disconnect()
            hostIP = ip
            hostPort = port
            UserDefaults.standard.set(
                ip,
                forKey: "UMICapture.hostIP"
            )
            UserDefaults.standard.set(
                String(port),
                forKey: "UMICapture.hostPort"
            )
            print(
                "Reconnecting Socket.IO client: "
                    + "\(hostIP):\(hostPort)"
            )
            connectSocketClient()
        case .resetCalibration:
            requestResetFromControlSurface()
        }
    }

    private func startStreaming(
        origin: CaptureStartOrigin
    ) -> Bool {
        guard logicalCaptureStartedAtUnixMs == nil,
              !isStreaming,
              !isFinalizingLogicalCapture
        else {
            calibrationStatus = "Capture already active — use End to save"
            return false
        }
        guard validateCaptureStart(
            remoteCommand:
                origin == .remote
                    ? pendingRemoteStartCommand
                    : nil
        ) else {
            return false
        }
        if isStarting {
            if origin == .remote {
                startStreamingImmediately(origin: .remote)
            }
            return true
        }

        if isCalibrationReady {
            switch origin {
            case .local:
                beginLocalStartCue()
            case .remote:
                startStreamingImmediately(origin: .remote)
            }
        } else {
            beginCalibration(
                autoStart: true,
                useLocalStartCue: origin == .local
            )
        }
        return true
    }

    @discardableResult
    private func validateCaptureStart(
        remoteCommand: RemoteCaptureCommand?
    ) -> Bool {
        updateInterfaceOrientation(enforce: false)
        let storageDecision = CaptureStoragePreflight.evaluateCurrent(
            for: .ordinaryVIO
        )
        guard storageDecision.isAllowed else {
            calibrationStatus = storageDecision.userMessage
            if let remoteCommand {
                sendRemoteCaptureStatus(
                    remoteCommand,
                    state: "storage_unavailable"
                )
            }
            return false
        }
        if selectedRGBVideoFormat == nil {
            calibrationStatus =
                "\(rgbCameraMode.shortLabel) physical lens unavailable"
            if let remoteCommand {
                sendRemoteCaptureStatus(
                    remoteCommand,
                    state: "camera_unavailable"
                )
            }
            return false
        }
        guard isCaptureOrientationSupported else {
            calibrationStatus =
                "Hold phone upright before Start"
            if let remoteCommand {
                sendRemoteCaptureStatus(
                    remoteCommand,
                    state: "orientation_required"
                )
            }
            return false
        }
        guard CaptureOrientationPolicy.isCompatible(
            lockedOrientation: captureInterfaceOrientationLock,
            currentOrientation: resolvedInterfaceOrientation()
        ) else {
            calibrationStatus =
                "Return phone to original capture orientation"
            if let remoteCommand {
                sendRemoteCaptureStatus(
                    remoteCommand,
                    state: "orientation_required"
                )
            }
            return false
        }
        guard isCaptureTiltWithinLimit else {
            calibrationStatus =
                "Return phone to prepared capture angle before Start"
            if let remoteCommand {
                sendRemoteCaptureStatus(
                    remoteCommand,
                    state: "orientation_required"
                )
            }
            return false
        }
        return true
    }

    private func startStreamingImmediately(
        origin: CaptureStartOrigin
    ) {
        cancelLocalStartCue()
        let currentOrientation = resolvedInterfaceOrientation()
        guard CaptureOrientationPolicy.isCompatible(
            lockedOrientation: captureInterfaceOrientationLock,
            currentOrientation: currentOrientation
        ) else {
            calibrationStatus =
                "Return phone to original capture orientation"
            return
        }
        guard isCaptureTiltWithinLimit else {
            calibrationStatus =
                "Return phone to prepared capture angle before Start"
            return
        }
        if captureInterfaceOrientationLock == nil {
            captureInterfaceOrientationLock = currentOrientation
        }
        if needsNewRecordingOnStart {
            socketClient.sendCaptureControl(
                "new_recording",
                commandID: pendingRemoteStartCommand?.commandID
            )
            needsNewRecordingOnStart = false
        }
        beginLogicalTrajectoryIfNeeded()
        lastTrajectoryFrameTimestamp = nil
        isStreaming = true
        calibrationStatus = "Streaming"
        captureFinalizationStage = .recording
        peakPhysicalMemoryMB = physicalMemoryMB
        startRGBRecording()

        if origin == .local {
            localStartCueController.playFormalStartFeedback()
        }
    }

    private func beginLocalStartCue() {
        guard isCalibrationReady,
              latestTrackingIsNormal,
              !isStreaming,
              !isStarting
        else {
            if !latestTrackingIsNormal {
                beginCalibration(
                    autoStart: true,
                    useLocalStartCue: true
                )
            }
            return
        }

        isStarting = true
        calibrationStatus = "Starting in 2"
        localStartCueController.start(
            onCountdown: { [weak self] remaining in
                guard let self,
                      self.isStarting
                else {
                    return
                }
                self.calibrationStatus =
                    "Starting in \(remaining)"
            },
            onCompletion: { [weak self] in
                self?.completeLocalStartCue()
            }
        )
    }

    private func completeLocalStartCue() {
        guard isStarting else {
            return
        }
        guard isCalibrationReady,
              latestTrackingIsNormal,
              referenceTransform != nil,
              captureStartPrerequisitesMet
        else {
            cancelLocalStartCue()
            if !isCaptureOrientationSupported {
                isCalibrating = false
                calibrationStatus =
                    "Preparation cancelled — unsupported device orientation"
                return
            }
            if !CaptureOrientationPolicy.isCompatible(
                lockedOrientation: captureInterfaceOrientationLock,
                currentOrientation: resolvedInterfaceOrientation()
            ) {
                beginCalibration(
                    autoStart: true,
                    useLocalStartCue: true
                )
                calibrationStatus =
                    "Preparation restarted — phone orientation changed"
                return
            }
            if !isCaptureTiltWithinLimit {
                beginCalibration(
                    autoStart: true,
                    useLocalStartCue: true
                )
                calibrationStatus =
                    "Preparation restarted — excessive phone tilt"
                return
            }
            beginCalibration(
                autoStart: true,
                useLocalStartCue: true
            )
            return
        }

        isStarting = false
        startStreamingImmediately(origin: .local)
    }

    private func cancelLocalStartCue() {
        localStartCueController.cancel()
        isStarting = false
    }

    private func interruptCapture(
        rgbFinishReason: RGBRecordingFinishReason = .orientationChanged
    ) {
        let wasStarting = isStarting
        cancelLocalStartCue()
        if isCalibrating {
            isCalibrating = false
            isStreaming = false
            readinessEvaluator.reset()
            needsNewRecordingOnStart = false
            calibrationStatus = "Preparation cancelled"
            finishCurrentRGBSegment(reason: rgbFinishReason)
            return
        }

        if isStreaming {
            appendLatestTrajectoryPose(
                elapsedTimeSeconds: trajectoryActiveElapsedTime,
                timestamp: prevTimestamp,
                force: true
            )
        }
        isStreaming = false
        lastTrajectoryFrameTimestamp = nil
        finishCurrentRGBSegment(reason: rgbFinishReason)
        calibrationStatus = isCalibrationReady || wasStarting
            ? "Capture interrupted — End to save"
            : "Capture interrupted"
    }

    private func safelyStopForResourcePressure(
        reason: String,
        finishReason: RGBRecordingFinishReason
    ) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.safelyStopForResourcePressure(
                    reason: reason,
                    finishReason: finishReason
                )
            }
            return
        }
        if isFinalizingLogicalCapture {
            activePackageCancellationToken?.cancel()
            rgbVideoRecorder.releaseTransientCaches()
            calibrationStatus =
                "Resource pressure — preserving recoverable files"
            return
        }
        guard isStreaming,
              !resourcePressureStopInProgress else {
            rgbVideoRecorder.releaseTransientCaches()
            return
        }
        resourcePressureStopInProgress = true
        recordSynchronizedPartialReason(reason)
        if activeCaptureCoordination != nil {
            synchronizedCapturePhase = .finalizing
            groupCoordinationStatus =
                "Resource pressure — safely ending this phone"
        }
        calibrationStatus =
            "Resource pressure — safely ending capture"
        let coordinationSnapshot = activeCaptureCoordination
        finalizeLogicalCapture(
            rgbFinishReason: finishReason
        ) { [weak self] artifacts in
            guard let self else { return }
            self.resourcePressureStopInProgress = false
            if self.activeCaptureCoordination != nil {
                self.publishSynchronizedCaptureFallback(
                    artifacts,
                    receiverUploadSucceeded: false
                )
                self.synchronizedCapturePhase = .failed
                self.groupCoordinationStatus =
                    "Ended safely under resource pressure — local ZIP retained"
                self.releaseSynchronizedSessionOwnership(
                    matching: coordinationSnapshot
                )
            } else {
                self.completedStandaloneCaptureArtifacts = artifacts
            }
        }
    }

    func endCurrentCapture(
        completion: @escaping (CompletedCaptureArtifacts) -> Void
    ) {
        let coordinationSnapshot = activeCaptureCoordination
        finalizeLogicalCapture(
            rgbFinishReason: .stop,
            completion: { [weak self] artifacts in
                completion(artifacts)
                self?.releaseSynchronizedSessionOwnership(
                    matching: coordinationSnapshot
                )
            }
        )
    }

    private func resetCalibration() {
        activePackageDeadline?.cancel()
        activePackageDeadline = nil
        activePackageCancellationToken?.cancel()
        activePackageCancellationToken = nil
        captureFinalizationStage = .idle
        resourcePressureStopInProgress = false
        pendingCoordinatedCaptureUpload = nil
        coordinatedCaptureUploadInProgress = false
        coordinatedCaptureUploadAuthorization = nil
        cancelAuthorizedCoordinatedCaptureUploadRetry()
        pendingStopCommitTransition = nil
        pendingUltrawidePreparationDeadline?.cancel()
        pendingUltrawidePreparationDeadline = nil
        failPendingGroupPreparation(reason: "preparation_cancelled")
        coordinatedPreparationPhase = .inactive
        cancelLocalStartCue()
        currentCaptureGeneration = UUID()
        currentCaptureVideoURL = nil
        currentCaptureRGBSegmentURLs = []
        finishRGBRecording(reason: .reset)
        releaseTransientCaptureResourcesForReset()
        isStreaming = false
        isCalibrationReady = false
        isCalibrating = false
        calibrationStatus = "Ready — tap Start"
        readinessEvaluator.reset()
        synchronizedBoundaryFeedbackController.reset()
        referenceTransform = nil
        captureTiltReferenceTransform = nil
        latestRawTransform = nil
        captureInterfaceOrientationLock = nil
        setNeedsUpdateOfSupportedInterfaceOrientations()
        axisDirections = nil
        trajectoryDisplayFrame = nil
        pendingRemoteStartCommand = nil
        shouldAutoStartAfterCalibration = true
        shouldUseLocalStartCueAfterCalibration = true
        needsNewRecordingOnStart = false
        latestTrackingIsNormal = false
        logicalCaptureStartedAtUnixMs = nil
        clearTrajectory()
        enterWarmIdle()
    }

    private func releaseTransientCaptureResourcesForReset() {
        rgbVideoRecorder.resetAndReleaseTransientResources()
        ultrawidePoseTimeline = UltrawidePoseTimeline()
        lastUltrawideObservationTimestamp = nil
        lastUltrawideStatusPublishTimestamp = nil
        ultrawideObservationStatus = .checking
    }

    private func releasePostCaptureTransientResources() {
        rgbVideoRecorder.releaseTransientCaches()
        ultrawidePoseTimeline = UltrawidePoseTimeline()
        lastUltrawideObservationTimestamp = nil
        lastUltrawideStatusPublishTimestamp = nil
        releaseCaptureInterfaceOrientationLockIfTerminal()
    }

    private func releaseCaptureInterfaceOrientationLockIfTerminal() {
        guard CaptureInterfaceOrientationLockPolicy.shouldRelease(
            isStreaming: isStreaming,
            isFinalizing: isFinalizingLogicalCapture,
            hasLogicalCapture: logicalCaptureStartedAtUnixMs != nil
        ) else { return }
        captureInterfaceOrientationLock = nil
        setNeedsUpdateOfSupportedInterfaceOrientations()
    }

    private func failPendingGroupPreparation(reason: String) {
        guard let pendingGroupPrepareCommand else { return }
        pendingUltrawidePreparationDeadline?.cancel()
        pendingUltrawidePreparationDeadline = nil
        coordinatedPreparationPhase = .inactive
        sendGroupAcknowledgement(
            pendingGroupPrepareCommand,
            state: "rejected",
            partialReason: reason
        )
        self.pendingGroupPrepareCommand = nil
        isCalibrating = false
        isCalibrationReady = false
        readinessEvaluator.reset()
        captureRoleLocked = false
        lockedCaptureProfile = nil
        activeCaptureCoordination = nil
        synchronizedPreparationRequestID = nil
        synchronizedCapturePhase = .failed
        isSynchronizedCaptureController = false
        groupCoordinationStatus = "Partial — group preparation cancelled"
        enterWarmIdle()
    }

    private func beginCalibration(
        autoStart: Bool = true,
        useLocalStartCue: Bool = true
    ) {
        guard ensureARSessionRunning() else {
            calibrationStatus = "Camera unavailable — cannot prepare capture"
            failPendingGroupPreparation(reason: "camera_unavailable")
            return
        }
        captureFinalizationStage = .idle
        resourcePressureStopInProgress = false
        cancelLocalStartCue()
        currentCaptureGeneration = UUID()
        currentCaptureVideoURL = nil
        currentCaptureRGBSegmentURLs = []
        if isStreaming {
            finishRGBRecording(reason: .reset)
        }
        releaseTransientCaptureResourcesForReset()
        isStreaming = false
        isCalibrationReady = false
        isCalibrating = true
        calibrationStatus =
            "Preparing — waiting for normal tracking"
        readinessEvaluator.reset()
        referenceTransform = nil
        captureTiltReferenceTransform = nil
        latestRawTransform = nil
        captureInterfaceOrientationLock = nil
        setNeedsUpdateOfSupportedInterfaceOrientations()
        trajectoryDisplayFrame = nil
        shouldAutoStartAfterCalibration = autoStart
        shouldUseLocalStartCueAfterCalibration =
            useLocalStartCue
        needsNewRecordingOnStart = true
        logicalCaptureStartedAtUnixMs = nil
        clearTrajectory()
    }

    // ARSessionDelegate method
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        if !hardwareCaptureCameraReady {
            setHardwareCaptureCameraReady(true)
        }
        let frameInterfaceOrientation =
            resolvedInterfaceOrientation()
        let orientationIsCompatible =
            CaptureOrientationPolicy.isCompatible(
                lockedOrientation: captureInterfaceOrientationLock,
                currentOrientation: frameInterfaceOrientation
            )
        if (isStreaming || isStarting || isCalibrating),
           !orientationIsCompatible,
           !isStreaming
                || enforcesRuntimeInterfaceOrientationLock {
            updateInterfaceOrientation(enforce: true)
        }
        let rawTransform = frame.camera.transform
        latestRawTransform = rawTransform
        let timestamp = frame.timestamp
        updatePerformanceIfNeeded(timestamp: timestamp)
        maybeSendEgoPreview(
            frame: frame,
            interfaceOrientation: frameInterfaceOrientation
        )
        let trackingIsNormal = isTrackingNormal(
            frame.camera.trackingState
        )
        latestTrackingIsNormal = trackingIsNormal
        let shouldProcessCaptureFrame =
            CaptureFrameWorkPolicy.shouldProcess(
                isCalibrating: isCalibrating,
                isStarting: isStarting,
                isStreaming: isStreaming,
                synchronizedPhase: synchronizedCapturePhase
            )
        let shouldPublishPresentation =
            timestamp - lastPresentationUpdateTimestamp
                >= (shouldProcessCaptureFrame
                    ? presentationUpdateInterval
                    : 0.5)

        guard shouldProcessCaptureFrame else {
            if shouldPublishPresentation {
                lastPresentationUpdateTimestamp = timestamp
                displayString =
                    "60 Hz ARKit 热待机\ntracking: "
                    + trackingStateDescription(frame.camera.trackingState)
            }
            prevTimestamp = timestamp
            return
        }

        socketClient.sendFrameClockAnchor(
            arkitTimestampSeconds: timestamp
        )
        executePendingFrameBoundaryTransitionIfNeeded(
            frameTimestampSeconds: timestamp
        )

        if isStreaming,
           enforcesRuntimeTiltLimit,
           let captureTiltReferenceTransform,
           CaptureOrientationPolicy.exceedsTiltLimit(
               referenceTransform: captureTiltReferenceTransform,
               currentTransform: rawTransform
           ) {
            recordSynchronizedPartialReason("excessive_phone_tilt")
            if synchronizedCapturePhase.isSessionActive {
                calibrationStatus =
                    "Recording — return phone to its prepared angle"
            } else {
                interruptCapture(
                    rgbFinishReason: .orientationChanged
                )
                calibrationStatus =
                    "Capture interrupted — End to save"
            }
        }

        if isStarting && !trackingIsNormal {
            beginCalibration(
                autoStart: true,
                useLocalStartCue: true
            )
        }

        updateCalibration(
            transform: rawTransform,
            timestamp: timestamp,
            trackingState: frame.camera.trackingState
        )

        if isStreaming && !isTrackingNormal(frame.camera.trackingState) {
            recordSynchronizedPartialReason("tracking_lost")
            if synchronizedCapturePhase.isSessionActive {
                calibrationStatus =
                    "Recording — tracking degraded; synchronized capture marked partial"
            } else {
                isStreaming = false
                lastTrajectoryFrameTimestamp = nil
                calibrationStatus = "Capture interrupted — End to save"
                finishCurrentRGBSegment(reason: .trackingLost)
            }
        }

        let outputTransform: simd_float4x4
        if let referenceTransform {
            outputTransform = ReferenceRelativePose.make(
                reference: referenceTransform,
                current: rawTransform
            )
            if shouldPublishPresentation {
                updateAxisDirections(
                    frame: frame,
                    referenceTransform: referenceTransform
                )
            }
        } else {
            outputTransform = matrix_identity_float4x4
            if shouldPublishPresentation {
                axisDirections = nil
            }
        }

        let shouldProbeUltrawide = captureExportSelection
            .includeUltrawideObservation
            && CaptureFrameWorkPolicy.shouldProcess(
                isCalibrating: isCalibrating,
                isStarting: isStarting,
                isStreaming: isStreaming,
                synchronizedPhase: synchronizedCapturePhase
            )
        let boundUltrawideFrame = shouldProbeUltrawide
            ? updateUltrawideObservationProbe(
                frame: frame,
                rawTransform: rawTransform,
                outputTransform: outputTransform,
                referenceTransform: referenceTransform
            )
            : nil
        completePendingGroupPreparationIfReady()

        let fps = prevTimestamp > 0.0 ? 1.0 / (timestamp - prevTimestamp) : 0.0
        let presentationTransform: simd_float4x4
        if captureProfileID == .handheldUMI,
           let physicalProfile = PhysicalTCPProfile.resolve(
               calibrationID: calibrationID
           ) {
            presentationTransform = VIOPoseTrajectoryPolicy
                .physicalTCPRelativePose(
                    referenceRelativeCamera: outputTransform,
                    cameraToTCP: physicalProfile.cameraToTCP
                )
        } else {
            presentationTransform = outputTransform
        }
        latestOutputPosition = VIOPoseTrajectoryPolicy.transformPosition(
            presentationTransform
        )
        latestOutputTransform = presentationTransform
        if captureProfileID == .handheldUMI {
            latestCameraForward = VIOPoseTrajectoryPolicy.transformXAxis(
                presentationTransform
            )
            latestCameraOrientationXYZW = VIOPoseTrajectoryPolicy
                .transformOrientationXYZW(presentationTransform)
        } else {
            latestCameraForward = cameraForward(from: presentationTransform)
            latestCameraOrientationXYZW =
                trajectoryDisplayOrientationXYZW(
                    from: presentationTransform
                )
        }
        if shouldPublishPresentation {
            lastPresentationUpdateTimestamp = timestamp
            let displayPosition = trajectoryDisplayPosition(
                latestOutputPosition
            )
            displayString = "x: \(String(format: "%.4f", displayPosition.x)), y: \(String(format: "%.4f", displayPosition.y)), z: \(String(format: "%.4f", displayPosition.z)), fps: \(String(format: "%.3f", fps))\ntracking: \(trackingStateDescription(frame.camera.trackingState))"
        }
        prevTimestamp = timestamp

        let frameLocalNs = CaptureFrameWindow.localMonotonicNs(
            arkitTimestampSeconds: timestamp
        )
        var frameCoordination = activeCaptureCoordination
        let admitsCoordinatedFrame = frameLocalNs.map {
            CaptureFrameWindow.admits(
                frameLocalNs: $0,
                startLocalNs:
                    frameCoordination?.plannedStartLocalNs,
                stopLocalNs:
                    frameCoordination?.plannedStopLocalNs
            )
        } ?? false
        if isStreaming, var coordination = frameCoordination {
            if !admitsCoordinatedFrame {
                if let frameLocalNs,
                   let startLocalNs = coordination.plannedStartLocalNs,
                   frameLocalNs < startLocalNs {
                    coordination.rejectedFramesBeforeStart =
                        (coordination.rejectedFramesBeforeStart ?? 0) + 1
                } else if let frameLocalNs,
                          let stopLocalNs = coordination.plannedStopLocalNs,
                          frameLocalNs >= stopLocalNs {
                    coordination.rejectedFramesAtOrAfterStop =
                        (coordination.rejectedFramesAtOrAfterStop ?? 0) + 1
                }
            } else {
                if coordination.firstARFrameTimestampSeconds == nil {
                    coordination.firstARFrameTimestampSeconds = timestamp
                }
                coordination.lastARFrameTimestampSeconds = timestamp
                if let frameLocalNs {
                    if coordination.firstFrameLocalNs == nil {
                        coordination.firstFrameLocalNs = frameLocalNs
                    }
                    coordination.lastFrameLocalNs = frameLocalNs
                    if let mapping = validClockSample()
                        ?? coordination.clockMappingAtStart,
                       let coordinatorFrameNs = mapping.coordinatorMonotonicNs(
                        forLocal: frameLocalNs
                       ) {
                        if coordination.firstFrameCoordinatorNs == nil {
                            coordination.firstFrameCoordinatorNs =
                                coordinatorFrameNs
                        }
                        coordination.lastFrameCoordinatorNs =
                            coordinatorFrameNs
                    }
                }
            }
            frameCoordination = coordination
            activeCaptureCoordination = coordination
        }

        if isStreaming,
           frameCoordination == nil || admitsCoordinatedFrame {
            advanceTrajectoryClock(to: timestamp)
            appendLatestTrajectoryPose(
                elapsedTimeSeconds: trajectoryActiveElapsedTime,
                timestamp: timestamp
            )
            let dataPacket = PosePacketV1(
                transformMatrix: outputTransform,
                timestamp: timestamp
            )
            socketClient.sendData(dataPacket)
            if rgbRecordingEnabled {
                rgbVideoRecorder.append(
                    frame: frame,
                    cameraPose: outputTransform,
                    trackingState:
                        trackingStateDescription(
                            frame.camera.trackingState
                        ),
                    interfaceOrientation:
                        UMICaptureOrientation.metadataValue(
                            for: resolvedInterfaceOrientation()
                        ),
                    ultrawideFrame: boundUltrawideFrame.map {
                        UltrawideRecordingFrame(
                            pixelBuffer: $0.pixelBuffer,
                            boundObservation: $0.boundObservation,
                            interfaceOrientation:
                                UMICaptureOrientation.metadataValue(
                                    for: resolvedInterfaceOrientation()
                                )
                        )
                    }
                )
            }
        }
    }

    private func updatePerformanceIfNeeded(timestamp: TimeInterval) {
        guard timestamp - lastPerformanceUpdateTimestamp >= 1 else {
            return
        }
        lastPerformanceUpdateTimestamp = timestamp
        refreshPerformanceSnapshot()
    }

    private func refreshPerformanceSnapshot() {
        let snapshot = performanceMonitor.snapshot()
        peakPhysicalMemoryMB = max(
            peakPhysicalMemoryMB,
            snapshot.physicalMemoryMB
        )
        physicalMemoryMB = snapshot.physicalMemoryMB
        availableMemoryMB = snapshot.availableMemoryMB
        safeGrowthBudgetMB = snapshot.safeGrowthBudgetMB
        captureLoadLevel = snapshot.level
        thermalStateText = Self.thermalDescription(snapshot.thermalState)
    }

    private var presentationUpdateInterval: TimeInterval {
        switch captureLoadLevel {
        case .normal:
            return 1.0 / 30.0
        case .elevated:
            return 0.1
        case .high:
            return 0.2
        case .critical:
            return 0.5
        }
    }

    private static func thermalDescription(
        _ state: ProcessInfo.ThermalState
    ) -> String {
        switch state {
        case .nominal:
            return "Normal"
        case .fair:
            return "Warm"
        case .serious:
            return "Hot"
        case .critical:
            return "Critical"
        @unknown default:
            return "Unknown"
        }
    }

    private func updateUltrawideObservationProbe(
        frame: ARFrame,
        rawTransform: simd_float4x4,
        outputTransform: simd_float4x4,
        referenceTransform: simd_float4x4?
    ) -> (
        pixelBuffer: CVPixelBuffer,
        boundObservation: BoundUltrawideObservation
    )? {
        ultrawidePoseTimeline.append(
            ARKitMetricPoseSample(
                timestamp: frame.timestamp,
                rawWorldTransform: rawTransform,
                referenceRelativeTransform: outputTransform,
                captureGeneration: currentCaptureGeneration
            )
        )

        switch ultrawideObservationSource.read(frame: frame) {
        case .privateAPIUnavailable:
            if ultrawideObservationStatus != .privateAPIUnavailable {
                ultrawideObservationStatus = .privateAPIUnavailable
            }
            return nil
        case .invalid:
            if lastUltrawideObservationTimestamp == nil {
                ultrawideObservationStatus = .invalid
            }
            return nil
        case .observation(let capturedObservation):
            let observation = capturedObservation.sample
            if let lastTimestamp = lastUltrawideObservationTimestamp {
                guard observation.timestamp > lastTimestamp else {
                    if observation.timestamp < lastTimestamp {
                        ultrawideObservationStatus = .invalid
                    }
                    return nil
                }
            }
            lastUltrawideObservationTimestamp = observation.timestamp

            guard let referenceTransform else {
                ultrawideObservationStatus = .waitingForMetricPose(
                    width: observation.width,
                    height: observation.height
                )
                return nil
            }
            guard let bound = UltrawidePoseBinding.bind(
                observation: observation,
                referenceTransform: referenceTransform,
                timeline: ultrawidePoseTimeline,
                captureGeneration: currentCaptureGeneration
            ),
            let fieldOfView = UltrawideObservationMath
                .horizontalFieldOfViewDegrees(
                    width: observation.width,
                    intrinsics: observation.intrinsics
                ) else {
                ultrawideObservationStatus = .invalid
                return nil
            }

            let shouldPublish: Bool
            if let lastPublish = lastUltrawideStatusPublishTimestamp {
                shouldPublish = observation.timestamp - lastPublish >= 0.5
            } else {
                shouldPublish = true
            }
            if shouldPublish {
                lastUltrawideStatusPublishTimestamp = observation.timestamp
                ultrawideObservationStatus = .available(
                    UltrawideObservationMetrics(
                        width: observation.width,
                        height: observation.height,
                        horizontalFieldOfViewDegrees: fieldOfView,
                        poseMatchDeltaMilliseconds:
                            bound.poseMatchDelta * 1_000
                    )
                )
            }
            return (
                pixelBuffer: capturedObservation.pixelBuffer,
                boundObservation: bound
            )
        }
    }

    private func executePendingFrameBoundaryTransitionIfNeeded(
        frameTimestampSeconds: TimeInterval
    ) {
        guard let pendingFrameBoundaryTransition,
              let frameLocalNs = CaptureFrameWindow.localMonotonicNs(
                arkitTimestampSeconds: frameTimestampSeconds
              ),
              SynchronizedFrameBoundaryPolicy.shouldExecute(
                command: pendingFrameBoundaryTransition.command.command,
                frameLocalNs: frameLocalNs,
                deadlineLocalNs:
                    pendingFrameBoundaryTransition.localDeadlineNs
              )
        else { return }
        self.pendingFrameBoundaryTransition = nil
        scheduledGroupTransition?.cancel()
        scheduledGroupTransition = nil
        executeGroupTransition(
            pendingFrameBoundaryTransition.command,
            localDeadlineNs: pendingFrameBoundaryTransition.localDeadlineNs,
            actualLocalNs: frameLocalNs,
            isARFrameBoundary: true
        )
    }

    private func updateCalibration(
        transform: simd_float4x4,
        timestamp: TimeInterval,
        trackingState: ARCamera.TrackingState
    ) {
        guard isCalibrating, referenceTransform == nil else {
            return
        }

        let readiness = readinessEvaluator.update(
            transform: transform,
            timestamp: timestamp,
            trackingIsNormal: isTrackingNormal(trackingState)
        )
        calibrationStatus = readinessStatus(readiness)

        guard readiness.isReady else {
            return
        }

        referenceTransform = transform
        captureTiltReferenceTransform = transform
        captureInterfaceOrientationLock =
            resolvedInterfaceOrientation()
        setNeedsUpdateOfSupportedInterfaceOrientations()
        if captureProfileID == .handheldUMI,
           let physicalProfile = PhysicalTCPProfile.resolve(
               calibrationID: calibrationID
           ) {
            trajectoryDisplayFrame = nil
            socketClient.sendTrajectoryDisplayFrame(
                xAxis: SIMD3<Float>(1, 0, 0),
                yAxis: SIMD3<Float>(0, 1, 0),
                zAxis: SIMD3<Float>(0, 0, 1),
                coordinateFrame: "initial_physical_fastumi_tcp",
                verticalAxis: "profile_z",
                groundPlane: "profile_x-y",
                physicalTCPProfileID: physicalProfile.identifier
            )
        } else {
            trajectoryDisplayFrame = makeTrajectoryDisplayFrame(
                referenceTransform: transform
            )
        }
        if captureProfileID != .handheldUMI,
           let trajectoryDisplayFrame {
            socketClient.sendTrajectoryDisplayFrame(
                xAxis: trajectoryDisplayFrame.xAxisInReference,
                yAxis: trajectoryDisplayFrame.yAxisInReference,
                zAxis: trajectoryDisplayFrame.zAxisInReference
            )
        }
        isCalibrationReady = true
        isCalibrating = false
        if shouldAutoStartAfterCalibration {
            if shouldUseLocalStartCueAfterCalibration {
                beginLocalStartCue()
            } else {
                startStreamingImmediately(origin: .remote)
                if let pendingRemoteStartCommand {
                    sendRemoteCaptureStatus(
                        pendingRemoteStartCommand,
                        state: "streaming"
                    )
                    self.pendingRemoteStartCommand = nil
                }
            }
        } else if pendingGroupPrepareCommand == nil {
            isStreaming = false
            calibrationStatus = "Armed — waiting for Start"
            if let pendingRemoteStartCommand {
                sendRemoteCaptureStatus(
                    pendingRemoteStartCommand,
                    state: "armed"
                )
                self.pendingRemoteStartCommand = nil
            }
        } else {
            isStreaming = false
            calibrationStatus =
                "Tracking ready — waiting for fresh 0.5× observation"
        }
    }

    private func completePendingGroupPreparationIfReady() {
        guard isCalibrationReady,
              let pendingGroupPrepareCommand
        else { return }

        guard captureProfileID.observationRequirementIsSatisfied(
            by: ultrawideObservationStatus
        ) else {
            guard pendingUltrawidePreparationDeadline == nil else { return }
            let deadline = DispatchWorkItem { [weak self] in
                guard let self,
                      self.pendingGroupPrepareCommand != nil,
                      self.isCalibrationReady
                else { return }
                self.failPendingGroupPreparation(
                    reason: "ultrawide_observation_unavailable"
                )
            }
            pendingUltrawidePreparationDeadline = deadline
            DispatchQueue.main.asyncAfter(
                deadline: .now() + 2,
                execute: deadline
            )
            return
        }

        pendingUltrawidePreparationDeadline?.cancel()
        pendingUltrawidePreparationDeadline = nil
        coordinatedPreparationPhase = .ready
        synchronizedCapturePhase = .armed
        groupCoordinationStatus = "Armed — waiting for group Start"
        calibrationStatus = "Armed — waiting for Start"
        sendGroupAcknowledgement(
            pendingGroupPrepareCommand,
            state: "armed",
            preparation: ReceiverPreparationCompatibility.readyTombstone()
        )
        self.pendingGroupPrepareCommand = nil
    }

    private func readinessStatus(
        _ readiness: TrackingReadinessResult
    ) -> String {
        switch readiness.phase {
        case .waitingForNormalTracking:
            return "Preparing — waiting for normal tracking"
        case .evaluatingTracking:
            return "Preparing — evaluating tracking"
        case .holdingNaturally:
            return "Preparing — \(readiness.progressPercent)%"
                + " · hold naturally"
        case .reduceMovement:
            return "Preparing — \(readiness.progressPercent)%"
                + " · reduce movement"
        case .ready:
            return "Preparing — 100% · hold naturally"
        }
    }

    private func clearTrajectory() {
        trajectorySamples = []
        lastTrajectoryTimestamp = nil
        lastTrajectoryFrameTimestamp = nil
        trajectoryCaptureOrigin = nil
        trajectoryActiveElapsedTime = 0
        latestOutputTransform = nil
        latestOutputPosition = .zero
        latestCameraForward = SIMD3<Float>(0, 0, -1)
        latestCameraOrientationXYZW = SIMD4<Float>(0, 0, 0, 1)
    }

    private func beginLogicalTrajectoryIfNeeded() {
        guard logicalCaptureStartedAtUnixMs == nil else {
            return
        }
        if activeCaptureCoordination != nil {
            _ = lockCaptureProfileIfNeeded()
        } else {
            // Handheld/Chest are synchronized-capture roles only. Ordinary
            // capture must not inherit a pending synchronized setup role.
            lockedCaptureProfile = nil
            captureRoleLocked = false
        }
        logicalCaptureStartedAtUnixMs =
            CaptureLibraryDate.unixMilliseconds()
    }

    private func finalizeLogicalCapture(
        rgbFinishReason: RGBRecordingFinishReason,
        commandID: String? = nil,
        completion: ((CompletedCaptureArtifacts) -> Void)? = nil
    ) {
        cancelLocalStartCue()
        guard !isFinalizingLogicalCapture else {
            if let completion {
                completion(
                    CompletedCaptureArtifacts(
                        trajectoryURL: nil,
                        rgbVideoURLs: currentCaptureRGBSegmentURLs,
                        primaryVideoURL: currentCaptureVideoURL,
                        exportPackageURL: nil,
                        exportError:
                            "Capture finalization is already in progress."
                    )
                )
            }
            return
        }
        isFinalizingLogicalCapture = true
        beginRGBBackgroundFinalization()
        captureFinalizationStage = .draining

        let previouslyFinalizedVideo = currentCaptureVideoURL
        if isStreaming && activeCaptureCoordination == nil {
            appendLatestTrajectoryPose(
                elapsedTimeSeconds: trajectoryActiveElapsedTime,
                timestamp: prevTimestamp,
                force: true
            )
        }

        let trajectorySnapshot = trajectorySamples
        let trajectoryStart = logicalCaptureStartedAtUnixMs
        let trajectoryEnd = CaptureLibraryDate.unixMilliseconds()
        let profileSnapshot = lockedCaptureProfile
        let coordinationSnapshot = activeCaptureCoordination
        logicalCaptureStartedAtUnixMs = nil

        isStreaming = false
        lastTrajectoryFrameTimestamp = nil
        isCalibrationReady = false
        isCalibrating = false
        readinessEvaluator.reset()
        needsNewRecordingOnStart = false
        pendingRemoteStartCommand = nil
        calibrationStatus = "Ending capture…"
        socketClient.sendCaptureControl(
            "end_recording",
            commandID: commandID
        )
        // The logical Stop boundary has already been captured. Writers,
        // packaging and upload do not need ARKit or camera frames.
        enterWarmIdle()

        let completionGroup = DispatchGroup()
        var trajectoryURL: URL?
        if let trajectoryStart, !trajectorySnapshot.isEmpty {
            completionGroup.enter()
            captureLibrary.archiveTrajectory(
                samples: trajectorySnapshot,
                startedAtUnixMs: trajectoryStart,
                endedAtUnixMs: trajectoryEnd,
                captureProfile: profileSnapshot,
                captureCoordination: coordinationSnapshot
            ) { record in
                trajectoryURL = record?.fileURL
                completionGroup.leave()
            }
        }

        var finalizedVideoURL: URL?
        completionGroup.enter()
        captureFinalizationStage = .finishingWriters
        finishCurrentRGBSegment(
            reason: rgbFinishReason
        ) { videoURL in
            finalizedVideoURL = videoURL
            completionGroup.leave()
        }

        completionGroup.notify(queue: .main) { [weak self] in
            guard let self else {
                if let completion {
                    completion(
                        CompletedCaptureArtifacts(
                            trajectoryURL: trajectoryURL,
                            rgbVideoURLs: [],
                            primaryVideoURL:
                                finalizedVideoURL
                                ?? previouslyFinalizedVideo,
                            exportPackageURL: nil,
                            exportError:
                                "Capture controller was released before export."
                        )
                    )
                }
                return
            }
            self.captureLibrary.refresh()
            var rgbVideoURLs = self.currentCaptureRGBSegmentURLs
            if let previouslyFinalizedVideo {
                rgbVideoURLs.append(previouslyFinalizedVideo)
            }
            if let finalizedVideoURL {
                rgbVideoURLs.append(finalizedVideoURL)
            }
            rgbVideoURLs = self.uniqueCaptureURLs(rgbVideoURLs)
            self.currentCaptureRGBSegmentURLs = []
            let primaryVideoURL = [
                finalizedVideoURL,
                previouslyFinalizedVideo,
                rgbVideoURLs.last
            ].compactMap { $0 }.first {
                Self.isPrimaryPreviewVideoURL($0)
            }

            if self.rgbRecorderStatus.phase == .failed {
                self.isFinalizingLogicalCapture = false
                self.captureFinalizationStage = .failed
                self.calibrationStatus =
                    self.rgbRecorderStatus.errorMessage
                    ?? "Video finalization failed"
                self.endRGBBackgroundFinalization()
                self.releasePostCaptureTransientResources()
                completion?(
                    CompletedCaptureArtifacts(
                        trajectoryURL: trajectoryURL,
                        rgbVideoURLs: rgbVideoURLs,
                        primaryVideoURL: primaryVideoURL,
                        exportPackageURL: nil,
                        exportError: self.calibrationStatus
                    )
                )
                return
            }

            guard let completion else {
                self.isFinalizingLogicalCapture = false
                self.captureFinalizationStage = .completed
                self.calibrationStatus = "Stopped"
                self.endRGBBackgroundFinalization()
                self.releasePostCaptureTransientResources()
                self.releaseSynchronizedSessionOwnership(
                    matching: coordinationSnapshot
                )
                return
            }

            self.calibrationStatus = "Preparing capture package…"
            self.captureFinalizationStage = .packaging
            let packageToken = CapturePackageCancellationToken()
            let packageCompletionGate = CaptureCompletionGate()
            self.activePackageCancellationToken = packageToken
            let packageDeadline = DispatchWorkItem { [weak self] in
                guard let self else { return }
                packageToken.cancel()
                packageCompletionGate.performOnce {
                    self.activePackageDeadline = nil
                    self.activePackageCancellationToken = nil
                    self.isFinalizingLogicalCapture = false
                    self.captureFinalizationStage = .failed
                    self.calibrationStatus =
                        "Capture package timed out — recovery files retained"
                    self.endRGBBackgroundFinalization()
                    self.releasePostCaptureTransientResources()
                    completion(
                        CompletedCaptureArtifacts(
                            trajectoryURL: trajectoryURL,
                            rgbVideoURLs: rgbVideoURLs,
                            primaryVideoURL: primaryVideoURL,
                            exportPackageURL: nil,
                            exportError: "package_timeout"
                        )
                    )
                }
            }
            self.activePackageDeadline?.cancel()
            self.activePackageDeadline = packageDeadline
            DispatchQueue.main.asyncAfter(
                deadline: .now()
                    + CaptureFinalizationDeadlines.packageSeconds,
                execute: packageDeadline
            )
            self.captureExportPackageBuilder.build(
                trajectoryURL: trajectoryURL,
                rgbVideoURLs: rgbVideoURLs,
                startedAtUnixMs: trajectoryStart,
                endedAtUnixMs: trajectoryEnd,
                selection: self.captureExportSelection,
                captureProfile: profileSnapshot,
                captureCoordination: coordinationSnapshot,
                cancellationToken: packageToken
            ) { [weak self] result in
                guard let self else { return }
                packageCompletionGate.performOnce {
                    packageDeadline.cancel()
                    self.activePackageDeadline = nil
                    self.activePackageCancellationToken = nil
                    self.isFinalizingLogicalCapture = false
                    self.endRGBBackgroundFinalization()
                    self.releasePostCaptureTransientResources()
                    switch result {
                    case .success(let package):
                        self.captureFinalizationStage =
                            coordinationSnapshot == nil
                            ? .completed
                            : .waitingUploadAuthorization
                        self.calibrationStatus = "Stopped"
                        completion(
                            CompletedCaptureArtifacts(
                                trajectoryURL: trajectoryURL,
                                rgbVideoURLs: rgbVideoURLs,
                                primaryVideoURL: primaryVideoURL,
                                exportPackageURL: package.fileURL,
                                exportError: nil,
                                exportPackageIdentity: package.identity
                            )
                        )
                    case .failure(let error):
                        self.captureFinalizationStage = .failed
                        self.calibrationStatus =
                            "Capture package failed — recovery files retained"
                        completion(
                            CompletedCaptureArtifacts(
                                trajectoryURL: trajectoryURL,
                                rgbVideoURLs: rgbVideoURLs,
                                primaryVideoURL: primaryVideoURL,
                                exportPackageURL: nil,
                                exportError: error.localizedDescription
                            )
                        )
                    }
                }
            }
        }
    }

    private func releaseSynchronizedSessionOwnershipIfSafe() {
        guard SynchronizedSessionLifecyclePolicy.canReleaseLocalOwnership(
            isStreaming: isStreaming,
            isFinalizing: isFinalizingLogicalCapture,
            hasLogicalCapture: logicalCaptureStartedAtUnixMs != nil
        ) else { return }
        releaseSynchronizedSessionOwnership(
            matching: activeCaptureCoordination
        )
    }

    private func releaseSynchronizedSessionOwnership(
        matching snapshot: ActiveCaptureCoordination?
    ) {
        if let snapshot,
           let activeCaptureCoordination,
           activeCaptureCoordination.sessionID != snapshot.sessionID {
            return
        }
        if synchronizedCapturePhase.isSessionActive {
            synchronizedCapturePhase = .failed
            groupCoordinationStatus =
                "Local files preserved — ready for a new synchronized session"
        }
        scheduledGroupTransition?.cancel()
        scheduledGroupTransition = nil
        pendingFrameBoundaryTransition = nil
        pendingGroupPrepareCommand = nil
        synchronizedPreparationRequestID = nil
        socketClient.clearPendingGroupTransitionRequest()
        activeCaptureCoordination = nil
        clearEgoPreviewState()
        captureRoleLocked = false
        lockedCaptureProfile = nil
        isSynchronizedCaptureController = false
        enterWarmIdle()
    }

    private func startRGBRecording() {
        guard rgbRecordingEnabled else {
            return
        }
        guard captureExportSelection.includeRawRGBVideo
                || captureExportSelection.includeProcessedRGBVideo
                || captureExportSelection.includeUltrawideObservation
        else {
            return
        }
        guard let selectedRGBVideoFormat else {
            rgbVideoFormatError =
                rgbVideoFormatError
                ?? "No supported 4:3 60 FPS ARKit format is available."
            return
        }
        let iPhoneModel = DeviceModelIdentifier.current
        let calibration = CameraCalibrationRegistry.profile(
            iPhoneModel: iPhoneModel,
            lensMode: selectedRGBVideoFormat.cameraMode,
            width: selectedRGBVideoFormat.width,
            height: selectedRGBVideoFormat.height
        )
        let captureProfile = activeCaptureCoordination == nil
            ? nil
            : lockCaptureProfileIfNeeded()
        let fixedOrientation = captureInterfaceOrientationLock
            ?? resolvedInterfaceOrientation()
        guard let rotationDegrees =
                UMICaptureOrientation.uprightRotationDegrees(
                    for: fixedOrientation
                ) else {
            rgbVideoFormatError =
                "A supported capture orientation is required before recording."
            return
        }
        rgbVideoRecorder.start(
            configuration: RGBRecordingConfiguration(
                format: selectedRGBVideoFormat,
                iPhoneModel: iPhoneModel,
                captureStartInterfaceOrientation:
                    UMICaptureOrientation.metadataValue(
                        for: fixedOrientation
                    ),
                empiricalCalibration: calibration,
                umiPreprocessing:
                    UMIImagePreprocessing.fixed224(
                        sourceWidth:
                            selectedRGBVideoFormat.width,
                        sourceHeight:
                            selectedRGBVideoFormat.height,
                        dataKey: CaptureDataKey.main(
                            for: captureProfile
                        ),
                        rotationDegrees: rotationDegrees
                    ),
                recordingFrameRate: rgbRecordingFrameRate,
                recordingQuality: rgbRecordingQuality,
                includeRawRGBVideo:
                    captureExportSelection.includeRawRGBVideo,
                includeProcessedRGBVideo:
                    captureExportSelection.includeProcessedRGBVideo,
                includeUltrawideObservation:
                    captureExportSelection.includeUltrawideObservation
                        && activeCaptureCoordination?.profile.profileID
                            == .handheldUMI,
                captureProfile: captureProfile,
                captureCoordination: activeCaptureCoordination
            )
        )
    }

    private func finishRGBRecording(
        reason: RGBRecordingFinishReason,
        completion: ((URL?) -> Void)? = nil
    ) {
        rgbVideoRecorder.finish(
            reason: reason,
            completion: completion
        )
    }

    private func finishCurrentRGBSegment(
        reason: RGBRecordingFinishReason,
        completion: ((URL?) -> Void)? = nil
    ) {
        let generation = currentCaptureGeneration
        finishRGBRecording(reason: reason) { [weak self] videoURL in
            if let self,
               self.currentCaptureGeneration == generation,
               let videoURL {
                if Self.isPrimaryPreviewVideoURL(videoURL) {
                    self.currentCaptureVideoURL = videoURL
                }
                if !self.currentCaptureRGBSegmentURLs.contains(
                    where: {
                        $0.standardizedFileURL.path
                            == videoURL.standardizedFileURL.path
                    }
                ) {
                    self.currentCaptureRGBSegmentURLs.append(videoURL)
                }
            }
            completion?(videoURL)
        }
    }

    private func uniqueCaptureURLs(_ urls: [URL]) -> [URL] {
        var paths: Set<String> = []
        return urls.filter {
            paths.insert($0.standardizedFileURL.path).inserted
        }
    }

    static func isPrimaryPreviewVideoURL(_ url: URL) -> Bool {
        let filename = url.lastPathComponent.lowercased()
        return filename == "rgb.mp4"
            || filename.hasSuffix("_rgb_224.mp4")
    }

    private func beginRGBBackgroundFinalization() {
        guard rgbBackgroundTask == .invalid else {
            return
        }
        rgbBackgroundTask = UIApplication.shared.beginBackgroundTask(
            withName: "Finalize UMI Capture"
        ) { [weak self] in
            guard let self else { return }
            self.activePackageCancellationToken?.cancel()
            self.captureFinalizationStage = .failed
            self.calibrationStatus =
                "Background time expired — recovery files retained"
            self.releasePostCaptureTransientResources()
            self.endRGBBackgroundFinalization()
        }
    }

    private func endRGBBackgroundFinalization() {
        guard rgbBackgroundTask != .invalid else {
            return
        }
        UIApplication.shared.endBackgroundTask(rgbBackgroundTask)
        rgbBackgroundTask = .invalid
    }

    private func appendTrajectoryPoint(
        _ point: SIMD3<Float>,
        cameraForward: SIMD3<Float>,
        orientationXYZW: SIMD4<Float>,
        elapsedTimeSeconds: TimeInterval,
        timestamp: TimeInterval,
        force: Bool = false
    ) {
        if VIOPoseTrajectoryPolicy.shouldSeedOrigin(
            sampleCount: trajectorySamples.count
        ) {
            trajectoryCaptureOrigin = point
            trajectorySamples = [
                TrajectoryPoseSample(
                    position: .zero,
                    cameraForward: cameraForward,
                    elapsedTimeSeconds: elapsedTimeSeconds,
                    orientationXYZW: orientationXYZW
                )
            ]
            lastTrajectoryTimestamp = timestamp
        }

        if VIOPoseTrajectoryPolicy.shouldSkipTrajectorySample(
            lastTimestamp: lastTrajectoryTimestamp,
            timestamp: timestamp,
            interval: trajectorySampleInterval,
            force: force
        ) {
            return
        }

        let captureRelativePoint =
            VIOPoseTrajectoryPolicy.captureRelativeTrajectoryPosition(
                point,
                captureOrigin: trajectoryCaptureOrigin ?? .zero
            )

        if VIOPoseTrajectoryPolicy.shouldDecimateTrajectory(
            sampleCount: trajectorySamples.count,
            maximumPointCount: maximumTrajectoryPointCount
        ) {
            trajectorySamples = trajectorySamples.enumerated().compactMap {
                index, sample in
                index.isMultiple(of: 2) ? sample : nil
            }
        }

        trajectorySamples.append(
            TrajectoryPoseSample(
                position: captureRelativePoint,
                cameraForward: cameraForward,
                elapsedTimeSeconds: elapsedTimeSeconds,
                orientationXYZW: orientationXYZW
            )
        )
        lastTrajectoryTimestamp = timestamp
    }

    /// Preserve the camera pose in the trajectory archive. All TCP composition
    /// and dataset post-processing remain Mac-side responsibilities.
    private func appendLatestTrajectoryPose(
        elapsedTimeSeconds: TimeInterval,
        timestamp: TimeInterval,
        force: Bool = false
    ) {
        appendTrajectoryPoint(
            trajectoryDisplayPosition(latestOutputPosition),
            cameraForward: trajectoryDisplayDirection(latestCameraForward),
            orientationXYZW: latestCameraOrientationXYZW,
            elapsedTimeSeconds: elapsedTimeSeconds,
            timestamp: timestamp,
            force: force
        )
    }

    private func advanceTrajectoryClock(
        to timestamp: TimeInterval
    ) {
        defer {
            lastTrajectoryFrameTimestamp = timestamp
        }
        guard let delta = VIOPoseTrajectoryPolicy.activeClockDelta(
            previousTimestamp: lastTrajectoryFrameTimestamp,
            timestamp: timestamp
        ) else {
            return
        }
        trajectoryActiveElapsedTime += delta
    }

    private func cameraForward(
        from transform: simd_float4x4
    ) -> SIMD3<Float> {
        VIOPoseTrajectoryPolicy.cameraForward(from: transform)
    }

    private func makeTrajectoryDisplayFrame(
        referenceTransform: simd_float4x4
    ) -> TrajectoryDisplayFrame {
        VIOPoseTrajectoryPolicy.makeTrajectoryDisplayFrame(
            referenceTransform: referenceTransform
        )
    }

    private func trajectoryDisplayPosition(
        _ position: SIMD3<Float>
    ) -> SIMD3<Float> {
        VIOPoseTrajectoryPolicy.trajectoryDisplayPosition(
            position,
            frame: trajectoryDisplayFrame
        )
    }

    private func trajectoryDisplayDirection(
        _ direction: SIMD3<Float>
    ) -> SIMD3<Float> {
        VIOPoseTrajectoryPolicy.trajectoryDisplayDirection(
            direction,
            frame: trajectoryDisplayFrame
        )
    }

    private func trajectoryDisplayOrientationXYZW(
        from transform: simd_float4x4
    ) -> SIMD4<Float> {
        VIOPoseTrajectoryPolicy.trajectoryDisplayOrientationXYZW(
            from: transform,
            frame: trajectoryDisplayFrame
        )
    }

    private func isTrackingNormal(_ state: ARCamera.TrackingState) -> Bool {
        if case .normal = state {
            return true
        }
        return false
    }

    private func updateAxisDirections(
        frame: ARFrame,
        referenceTransform: simd_float4x4
    ) {
        let resolvedOrientation = resolvedInterfaceOrientation()
        let orientation = UMICaptureOrientation.isValid(
            resolvedOrientation
        )
            ? resolvedOrientation
            : .portrait
        let viewMatrix = frame.camera.viewMatrix(for: orientation)

        func referenceAxisInWorld(
            _ axis: SIMD3<Float>
        ) -> SIMD4<Float> {
            referenceTransform.columns.0 * axis.x
                + referenceTransform.columns.1 * axis.y
                + referenceTransform.columns.2 * axis.z
        }

        func project(
            _ worldAxis: SIMD4<Float>
        ) -> VIOAxisDirection {
            let directionInCamera = viewMatrix * SIMD4<Float>(
                worldAxis.x,
                worldAxis.y,
                worldAxis.z,
                0
            )

            return VIOAxisDirection(
                horizontal: CGFloat(directionInCamera.x),
                vertical: CGFloat(-directionInCamera.y),
                depth: CGFloat(directionInCamera.z)
            )
        }

        let displayFrame = FrameDirectionAlignmentPolicy.displayFrame(
            referenceTransform: referenceTransform,
            profileID: captureProfileID
        )
        axisDirections = VIOAxisDirections(
            x: project(
                referenceAxisInWorld(displayFrame.xAxisInReference)
            ),
            y: project(
                referenceAxisInWorld(displayFrame.yAxisInReference)
            ),
            z: project(
                referenceAxisInWorld(displayFrame.zAxisInReference)
            )
        )
    }

    private func trackingStateDescription(_ state: ARCamera.TrackingState) -> String {
        switch state {
        case .normal:
            return "normal"
        case .notAvailable:
            return "not available"
        case .limited(let reason):
            switch reason {
            case .initializing:
                return "limited (initializing)"
            case .excessiveMotion:
                return "limited (excessive motion)"
            case .insufficientFeatures:
                return "limited (insufficient features)"
            case .relocalizing:
                return "limited (relocalizing)"
            @unknown default:
                return "limited (unknown)"
            }
        }
    }

    func sessionWasInterrupted(_ session: ARSession) {
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }
            if self.isCalibrating {
                self.failPendingGroupPreparation(
                    reason: "preparation_interrupted"
                )
            } else if self.activeCaptureCoordination != nil {
                self.activeCaptureCoordination?.partialReasons.append(
                    "arkit_session_interrupted"
                )
            }
            self.cancelLocalStartCue()
            self.finishCurrentRGBSegment(reason: .sessionInterrupted)
            self.isStreaming = false
            if self.logicalCaptureStartedAtUnixMs != nil {
                self.synchronizedCapturePhase = .failed
            }
            self.calibrationStatus =
                "Capture interrupted — End to save"
        }
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }
            self.calibrationStatus = self.logicalCaptureStartedAtUnixMs != nil
                ? "Capture interrupted — End to save"
                : "Ready — tap Start"
        }
    }

    func session(
        _ session: ARSession,
        didFailWithError error: Error
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }
            if self.isCalibrating {
                self.failPendingGroupPreparation(
                    reason: "preparation_session_failed"
                )
            } else if self.activeCaptureCoordination != nil {
                self.activeCaptureCoordination?.partialReasons.append(
                    "arkit_session_failed"
                )
            }
            self.cancelLocalStartCue()
            self.finishCurrentRGBSegment(reason: .sessionFailure)
            self.isStreaming = false
            self.isARSessionRunning = false
            self.calibrationStatus =
                "ARSession failed: \(error.localizedDescription)"
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        setHardwareCaptureCameraReady(false)
        cancelLocalStartCue()
        finishCurrentRGBSegment(reason: .viewDisappeared)
        isStreaming = false
        session.pause()
        isARSessionRunning = false
    }
}
