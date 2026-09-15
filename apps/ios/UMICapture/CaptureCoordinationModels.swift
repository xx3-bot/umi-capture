import Foundation

enum CaptureCoordinationProtocol {
    static let version = 1
    static let register = "iphonevio_register_v1"
    static let registerAck = "iphonevio_register_ack_v1"
    static let timeProbe = "iphonevio_time_probe_v1"
    static let timeReply = "iphonevio_time_reply_v1"
    static let clockSample = "iphonevio_clock_sample_v1"
    static let clockRefreshRequest = "iphonevio_clock_refresh_request_v1"
    static let frameClockAnchor = "iphonevio_frame_clock_anchor_v1"
    static let groupCommand = "iphonevio_group_command_v1"
    static let groupAck = "iphonevio_group_ack_v1"
    static let groupRequest = "iphonevio_group_request_v1"
    static let groupState = "iphonevio_group_state_v1"
    static let egoPreviewFrame = "umi_capture_ego_preview_frame_v1"
}

enum CaptureCoordinationPolicy {
    static let maximumClockSampleAgeNs: UInt64 = 3_000_000_000
    static let maximumClockUncertaintyNs: UInt64 = 8_333_333
    static let lateCommandToleranceNs: UInt64 = 16_666_667
    // Probe often enough that transient Wi-Fi RTT spikes cannot normally age
    // the last within-budget mapping out before the next usable reply.
    static let clockRefreshInterval: TimeInterval = 0.25
    static let clockFusionWindowNs: UInt64 = 2_000_000_000
    static let maximumRetainedClockCandidates = 64
    static let minimumClockFusionCandidates = 8
    static let statisticalClockUncertaintyFloorNs: UInt64 = 1_000_000
    static let commandLeadTimeNs: UInt64 = 1_500_000_000
    static let frameDrainGraceNs: UInt64 = 100_000_000
    static let maximumRetainedClockSamples = 12

    static func missedDeadline(nowNs: UInt64, deadlineNs: UInt64) -> Bool {
        nowNs > deadlineNs
            && nowNs - deadlineNs > lateCommandToleranceNs
    }
}

enum EgoPreviewThumbnailPolicy {
    static let maximumFramesPerSecond = 2.5
    static let minimumFrameIntervalNs: UInt64 = 400_000_000
    static let staleIntervalNs: UInt64 = 1_500_000_000
    static let maximumJPEGBytes = 160 * 1024
    static let maximumLongEdgePixels: CGFloat = 320
    static let JPEGCompressionQuality: CGFloat = 0.45

    static func sessionAcceptsFrames(
        phase: SynchronizedCapturePhase
    ) -> Bool {
        switch phase {
        case .preparing, .armed, .starting, .running, .stopping:
            return true
        case .inactive, .requesting, .finalizing, .finalized, .failed:
            return false
        }
    }

    static func shouldAdmitEgoFrame(
        role: CaptureRole,
        phase: SynchronizedCapturePhase,
        hasActiveCoordination: Bool,
        socketReady: Bool,
        encoderBusy: Bool,
        lastCandidateNs: UInt64?,
        nowNs: UInt64
    ) -> Bool {
        guard role == .ego,
              sessionAcceptsFrames(phase: phase),
              hasActiveCoordination,
              socketReady,
              !encoderBusy
        else { return false }
        guard let lastCandidateNs else { return true }
        return nowNs >= lastCandidateNs
            && nowNs - lastCandidateNs >= minimumFrameIntervalNs
    }

    static func shouldDisplayOnHand(
        role: CaptureRole,
        phase: SynchronizedCapturePhase,
        hasActiveCoordination: Bool,
        hasImage: Bool
    ) -> Bool {
        role == .wristUMI
            && sessionAcceptsFrames(phase: phase)
            && hasActiveCoordination
            && hasImage
    }

    static func isStale(
        lastReceivedNs: UInt64?,
        nowNs: UInt64
    ) -> Bool {
        guard let lastReceivedNs, nowNs >= lastReceivedNs else { return true }
        return nowNs - lastReceivedNs > staleIntervalNs
    }

    static func acceptsSequence(
        _ sequence: UInt64,
        after lastSequence: UInt64?
    ) -> Bool {
        sequence > 0 && (lastSequence.map { sequence > $0 } ?? true)
    }

    static func sequence(senderMonotonicNs: UInt64) -> UInt64 {
        max(1, senderMonotonicNs)
    }
}

enum EgoPreviewLayoutClass {
    case portrait
    case landscape
}

struct EgoPreviewSafeAreaInsets: Equatable {
    let top: CGFloat
    let leading: CGFloat
    let bottom: CGFloat
    let trailing: CGFloat
}

struct EgoPreviewNormalizedPosition: Equatable {
    let x: Double
    let y: Double
}

enum EgoPreviewLayoutPolicy {
    static let panelSize = CGSize(width: 176, height: 132)
    static let margin: CGFloat = 12

    static func layoutClass(for size: CGSize) -> EgoPreviewLayoutClass {
        size.width > size.height ? .landscape : .portrait
    }

    static func defaultPosition(
        for layoutClass: EgoPreviewLayoutClass
    ) -> EgoPreviewNormalizedPosition {
        switch layoutClass {
        case .landscape:
            return EgoPreviewNormalizedPosition(x: 0, y: 1)
        case .portrait:
            return EgoPreviewNormalizedPosition(x: 0.5, y: 0)
        }
    }

    static func center(
        for position: EgoPreviewNormalizedPosition,
        containerSize: CGSize,
        safeAreaInsets: EgoPreviewSafeAreaInsets
    ) -> CGPoint {
        let bounds = centerBounds(
            containerSize: containerSize,
            safeAreaInsets: safeAreaInsets
        )
        return CGPoint(
            x: interpolate(position.x, minimum: bounds.minX, maximum: bounds.maxX),
            y: interpolate(position.y, minimum: bounds.minY, maximum: bounds.maxY)
        )
    }

    static func clampedCenter(
        _ center: CGPoint,
        containerSize: CGSize,
        safeAreaInsets: EgoPreviewSafeAreaInsets
    ) -> CGPoint {
        let bounds = centerBounds(
            containerSize: containerSize,
            safeAreaInsets: safeAreaInsets
        )
        return CGPoint(
            x: min(bounds.maxX, max(bounds.minX, center.x)),
            y: min(bounds.maxY, max(bounds.minY, center.y))
        )
    }

    static func normalizedPosition(
        for center: CGPoint,
        containerSize: CGSize,
        safeAreaInsets: EgoPreviewSafeAreaInsets
    ) -> EgoPreviewNormalizedPosition {
        let clamped = clampedCenter(
            center,
            containerSize: containerSize,
            safeAreaInsets: safeAreaInsets
        )
        let bounds = centerBounds(
            containerSize: containerSize,
            safeAreaInsets: safeAreaInsets
        )
        return EgoPreviewNormalizedPosition(
            x: normalized(clamped.x, minimum: bounds.minX, maximum: bounds.maxX),
            y: normalized(clamped.y, minimum: bounds.minY, maximum: bounds.maxY)
        )
    }

    private static func centerBounds(
        containerSize: CGSize,
        safeAreaInsets: EgoPreviewSafeAreaInsets
    ) -> (minX: CGFloat, maxX: CGFloat, minY: CGFloat, maxY: CGFloat) {
        let requestedMinX = safeAreaInsets.leading + margin + panelSize.width / 2
        let requestedMaxX = containerSize.width - safeAreaInsets.trailing
            - margin - panelSize.width / 2
        let requestedMinY = safeAreaInsets.top + margin + panelSize.height / 2
        let requestedMaxY = containerSize.height - safeAreaInsets.bottom
            - margin - panelSize.height / 2
        let fallbackX = containerSize.width / 2
        let fallbackY = containerSize.height / 2
        return (
            minX: requestedMinX <= requestedMaxX ? requestedMinX : fallbackX,
            maxX: requestedMinX <= requestedMaxX ? requestedMaxX : fallbackX,
            minY: requestedMinY <= requestedMaxY ? requestedMinY : fallbackY,
            maxY: requestedMinY <= requestedMaxY ? requestedMaxY : fallbackY
        )
    }

    private static func interpolate(
        _ value: Double,
        minimum: CGFloat,
        maximum: CGFloat
    ) -> CGFloat {
        minimum + CGFloat(min(1, max(0, value))) * (maximum - minimum)
    }

    private static func normalized(
        _ value: CGFloat,
        minimum: CGFloat,
        maximum: CGFloat
    ) -> Double {
        guard maximum > minimum else { return 0.5 }
        return Double((value - minimum) / (maximum - minimum))
    }
}

struct EgoPreviewFramePayload: Equatable {
    let sessionID: String
    let generation: Int
    let deviceID: String
    let sequence: UInt64
    let arFrameTimestampSeconds: Double
    let senderMonotonicNs: UInt64
    let orientation: String
    let jpegData: Data

    static func decode(_ payload: [String: Any]) -> EgoPreviewFramePayload? {
        guard payload["protocol_version"] as? Int
                == CaptureCoordinationProtocol.version,
              let sessionID = payload["session_id"] as? String,
              !sessionID.isEmpty,
              let generation = payload["generation"] as? Int,
              generation > 0,
              let deviceID = payload["device_id"] as? String,
              !deviceID.isEmpty,
              payload["capture_role"] as? String == CaptureRole.ego.rawValue,
              let sequenceText = payload["sequence"] as? String,
              let sequence = UInt64(sequenceText),
              sequence > 0,
              let arFrameTimestampSeconds =
                payload["arkit_timestamp_s"] as? Double,
              arFrameTimestampSeconds.isFinite,
              arFrameTimestampSeconds >= 0,
              let senderMonotonicText =
                payload["sender_monotonic_ns"] as? String,
              let senderMonotonicNs = UInt64(senderMonotonicText),
              let orientation = payload["orientation"] as? String,
              ["portrait", "landscape_left", "landscape_right"]
                .contains(orientation),
              let jpegBase64 = payload["jpeg_base64"] as? String,
              jpegBase64.utf8.count
                <= ((EgoPreviewThumbnailPolicy.maximumJPEGBytes + 2) / 3) * 4,
              let jpegData = Data(base64Encoded: jpegBase64),
              !jpegData.isEmpty,
              jpegData.count <= EgoPreviewThumbnailPolicy.maximumJPEGBytes,
              jpegData.starts(with: [0xff, 0xd8]),
              jpegData.suffix(2).elementsEqual([0xff, 0xd9])
        else { return nil }
        return EgoPreviewFramePayload(
            sessionID: sessionID,
            generation: generation,
            deviceID: deviceID,
            sequence: sequence,
            arFrameTimestampSeconds: arFrameTimestampSeconds,
            senderMonotonicNs: senderMonotonicNs,
            orientation: orientation,
            jpegData: jpegData
        )
    }
}

enum CaptureFrameWindow {
    static func localMonotonicNs(
        arkitTimestampSeconds: Double
    ) -> UInt64? {
        guard arkitTimestampSeconds.isFinite,
              arkitTimestampSeconds >= 0,
              arkitTimestampSeconds <= Double(UInt64.max) / 1_000_000_000
        else { return nil }
        return UInt64(arkitTimestampSeconds * 1_000_000_000)
    }

    static func admits(
        frameLocalNs: UInt64,
        startLocalNs: UInt64?,
        stopLocalNs: UInt64?
    ) -> Bool {
        if let startLocalNs, frameLocalNs < startLocalNs {
            return false
        }
        if let stopLocalNs, frameLocalNs >= stopLocalNs {
            return false
        }
        return true
    }
}

enum UncalibratedPreparationAction: Equatable {
    case waitForNormalTracking
    case arm
}

enum UncalibratedPreparationPolicy {
    static func action(trackingIsNormal: Bool) -> UncalibratedPreparationAction {
        trackingIsNormal ? .arm : .waitForNormalTracking
    }
}

enum ReceiverPreparationCompatibility {
    static func readyTombstone() -> [String: Any] {
        [
            "phase": "ready",
            "stationary_duration_s": 0.0,
            "gyro_rms_rad_s": 0.0,
            "gyro_peak_rad_s": 0.0,
            "vision_board_calibration_enabled": false,
            "calibration_reused": false,
            "training_truth_eligible": false,
            "frame_direction_alignment":
                FrameDirectionAlignmentPolicy.identifier
        ]
    }
}

enum SynchronizedFrameBoundaryPolicy {
    static let missingFrameFallbackDelayNs: UInt64 = 250_000_000

    static func usesARFrameBoundary(
        for command: GroupCaptureCommandName
    ) -> Bool {
        command == .start || command == .stop
    }

    static func shouldExecute(
        command: GroupCaptureCommandName,
        frameLocalNs: UInt64,
        deadlineLocalNs: UInt64
    ) -> Bool {
        usesARFrameBoundary(for: command)
            && frameLocalNs >= deadlineLocalNs
    }
}

enum SynchronizedStopBoundaryPolicy {
    static func partialReason(
        forcedPartialReason: String?,
        missedDeadline: Bool,
        isARFrameBoundary: Bool
    ) -> String? {
        if let forcedPartialReason {
            return forcedPartialReason
        }
        // The first ARFrame at-or-after the deadline is the intended boundary,
        // even though its timestamp is necessarily later than the deadline.
        return missedDeadline && !isARFrameBoundary
            ? "scheduled_deadline_missed"
            : nil
    }
}

struct CaptureClockMappingSample: Codable, Equatable {
    let probeID: String
    let localMidpointMonotonicNs: UInt64
    let coordinatorMidpointMonotonicNs: UInt64
    let offsetNs: Int64
    let rttNs: UInt64
    let uncertaintyNs: UInt64
    let sampledAtLocalMonotonicNs: UInt64

    func coordinatorMonotonicNs(
        forLocal localNs: UInt64
    ) -> UInt64? {
        let mapped = Int64(clamping: localNs) &+ offsetNs
        guard mapped >= 0 else {
            return nil
        }
        return UInt64(mapped)
    }

    func localMonotonicNs(
        forCoordinator coordinatorNs: UInt64
    ) -> UInt64? {
        let mapped = Int64(clamping: coordinatorNs) &- offsetNs
        guard mapped >= 0 else {
            return nil
        }
        return UInt64(mapped)
    }

    func ageNs(nowLocalMonotonicNs: UInt64) -> UInt64 {
        nowLocalMonotonicNs >= sampledAtLocalMonotonicNs
            ? nowLocalMonotonicNs - sampledAtLocalMonotonicNs
            : UInt64.max
    }

    enum CodingKeys: String, CodingKey {
        case probeID = "probe_id"
        case localMidpointMonotonicNs = "local_midpoint_monotonic_ns"
        case coordinatorMidpointMonotonicNs =
            "coordinator_midpoint_monotonic_ns"
        case offsetNs = "offset_ns"
        case rttNs = "rtt_ns"
        case uncertaintyNs = "uncertainty_ns"
        case sampledAtLocalMonotonicNs =
            "sampled_at_local_monotonic_ns"
    }
}

struct CaptureFrameClockAnchor: Codable, Equatable {
    let arkitTimestampSeconds: Double
    let localMonotonicNs: UInt64
    let coordinatorMonotonicNs: UInt64
    let uncertaintyNs: UInt64
    let clockSampleAgeNs: UInt64

    enum CodingKeys: String, CodingKey {
        case arkitTimestampSeconds = "arkit_timestamp_s"
        case localMonotonicNs = "local_monotonic_ns"
        case coordinatorMonotonicNs = "coordinator_monotonic_ns"
        case uncertaintyNs = "uncertainty_ns"
        case clockSampleAgeNs = "clock_sample_age_ns"
    }
}

enum GroupCaptureCommandName: String, Codable {
    case prepare
    case start
    // Kept only to decode old v1 Receiver requests. UMICapture rejects both.
    case pause
    case resume
    case stop
}

enum SynchronizedCapturePhase: Equatable {
    case inactive
    case requesting
    case preparing
    case armed
    case starting
    case running
    case stopping
    case finalizing
    case finalized
    case failed

    var isSessionActive: Bool {
        switch self {
        case .inactive, .finalized, .failed:
            return false
        case .requesting, .preparing, .armed, .starting, .running,
             .stopping, .finalizing:
            return true
        }
    }

    var allowsNewSessionRequest: Bool {
        switch self {
        case .inactive, .finalized, .failed:
            return true
        case .requesting, .preparing, .armed, .starting, .running,
             .stopping, .finalizing:
            return false
        }
    }
}

enum CaptureSurfaceAction: Equatable {
    case localStart
    case localEnd
    case group(GroupCaptureCommandName)
    case disabled
}

enum SynchronizedPreparationButtonAction: Equatable {
    case prepare
    case unavailable
}

struct PendingGroupPreparationRequest: Equatable {
    let requestID: String
    let recoverPreviousSession: Bool
    let autoRearmAfterCapture: Bool

    init(
        requestID: String,
        recoverPreviousSession: Bool,
        autoRearmAfterCapture: Bool = false
    ) {
        self.requestID = requestID
        self.recoverPreviousSession = recoverPreviousSession
        self.autoRearmAfterCapture = autoRearmAfterCapture
    }
}

struct GroupPreparationRequestDeliveryState {
    private(set) var pending: PendingGroupPreparationRequest?

    mutating func begin(
        recoverPreviousSession: Bool,
        autoRearmAfterCapture: Bool = false,
        ready: Bool,
        registrationAcknowledged: Bool,
        requestID: String = UUID().uuidString
    ) -> PendingGroupPreparationRequest? {
        let request = PendingGroupPreparationRequest(
            requestID: requestID,
            recoverPreviousSession: recoverPreviousSession,
            autoRearmAfterCapture: autoRearmAfterCapture
        )
        guard ready, registrationAcknowledged else {
            pending = request
            return nil
        }
        // An immediately emitted Prepare must not remain queued. A subsequent
        // registration acknowledgement would otherwise emit it a second time
        // and turn one recovery tap into two Receiver generations.
        pending = nil
        return request
    }

    mutating func takeAfterRegistrationAcknowledgement()
        -> PendingGroupPreparationRequest? {
        defer { pending = nil }
        return pending
    }

    mutating func clear() {
        pending = nil
    }
}

struct PendingGroupTransitionRequest: Equatable {
    let command: GroupCaptureCommandName
    let requestID: String
}

struct GroupTransitionRequestDeliveryState {
    private(set) var pending: PendingGroupTransitionRequest?

    mutating func begin(
        command: GroupCaptureCommandName,
        ready: Bool,
        registrationAcknowledged: Bool,
        requestID: String = UUID().uuidString
    ) -> PendingGroupTransitionRequest? {
        precondition(command == .start)
        let request = PendingGroupTransitionRequest(
            command: command,
            requestID: requestID
        )
        guard ready, registrationAcknowledged else {
            pending = request
            return nil
        }
        pending = nil
        return request
    }

    mutating func takeAfterRegistrationAcknowledgement()
        -> PendingGroupTransitionRequest? {
        defer { pending = nil }
        return pending
    }

    mutating func clear() {
        pending = nil
    }
}

enum SynchronizedPreparationButtonPolicy {
    static func action(
        phase: SynchronizedCapturePhase,
        isController: Bool
    ) -> SynchronizedPreparationButtonAction {
        switch phase {
        case .inactive, .finalized, .failed:
            // Keep the button tappable so requestSynchronizedCapture can
            // explain a missing connection or preflight requirement instead
            // of silently swallowing the tap in SwiftUI's disabled state.
            return .prepare
        case .armed, .requesting, .preparing, .starting, .running,
             .stopping, .finalizing:
            return .unavailable
        }
    }
}

enum GroupCommandClockFailureAction: Equatable {
    case executeImmediatelyAndMarkUnsynchronized
    case reject
}

enum SynchronizedCaptureControlPolicy {
    static func effectiveController(
        cachedController: Bool,
        sharedDeviceControl: Bool,
        controllerCapable: Bool
    ) -> Bool {
        cachedController || (sharedDeviceControl && controllerCapable)
    }

    static func deviceCanControl(
        controllerKind: String?,
        initiatingDeviceID: String?,
        sharedDeviceControl: Bool,
        controllerCapable: Bool,
        localDeviceID: String
    ) -> Bool {
        guard controllerCapable else { return false }
        if sharedDeviceControl {
            return true
        }
        return controllerKind == "device"
            && initiatingDeviceID == localDeviceID
    }

    static func clockFailureAction(
        for command: GroupCaptureCommandName
    ) -> GroupCommandClockFailureAction {
        switch command {
        case .stop:
            // Losing the shared clock may prevent a synchronized boundary,
            // but it must never make a device continue recording against an
            // explicit Stop request.
            return .executeImmediatelyAndMarkUnsynchronized
        case .prepare, .start, .pause, .resume:
            return .reject
        }
    }

    static func primaryAction(
        phase: SynchronizedCapturePhase,
        isController: Bool
    ) -> CaptureSurfaceAction {
        switch phase {
        case .inactive, .finalized, .failed:
            return .localStart
        case .armed:
            return isController ? .group(.start) : .disabled
        case .running:
            return .disabled
        case .requesting, .preparing, .starting, .stopping, .finalizing:
            return .disabled
        }
    }

    static func endAction(
        phase: SynchronizedCapturePhase,
        isController: Bool
    ) -> CaptureSurfaceAction {
        switch phase {
        case .inactive, .finalized, .failed:
            return .localEnd
        case .running:
            // The selected controller requests a synchronized Stop. The peer
            // always retains a local emergency End so field data collection
            // can be stopped without access to the Mac or controller phone.
            return isController ? .group(.stop) : .localEnd
        case .requesting, .preparing, .armed, .starting,
             .stopping, .finalizing:
            return .disabled
        }
    }

    static func hardwareToggleAction(
        phase: SynchronizedCapturePhase,
        isController: Bool
    ) -> CaptureSurfaceAction {
        switch phase {
        case .inactive, .finalized, .failed:
            return .localStart
        case .armed:
            return isController ? .group(.start) : .disabled
        case .running:
            // In a synchronized session both physical volume buttons use the
            // same field-friendly toggle: Start before capture, End after it.
            // A peer still retains a local emergency End.
            return isController ? .group(.stop) : .localEnd
        case .requesting, .preparing, .starting,
             .stopping, .finalizing:
            return .disabled
        }
    }
}

enum SynchronizedSessionLifecyclePolicy {
    static func canReleaseLocalOwnership(
        isStreaming: Bool,
        isFinalizing: Bool,
        hasLogicalCapture: Bool
    ) -> Bool {
        !isStreaming && !isFinalizing && !hasLogicalCapture
    }

    static func canResetWithoutDiscardingCapture(
        isStreaming: Bool,
        isFinalizing: Bool,
        hasLogicalCapture: Bool,
        recorderPhase: RGBRecorderPhase
    ) -> Bool {
        !isStreaming
            && !isFinalizing
            && !hasLogicalCapture
            && recorderPhase != .recording
            && recorderPhase != .finishing
    }

    static func shouldApplyNonterminalGroupState(
        hasActiveCoordination: Bool,
        currentPhase: SynchronizedCapturePhase
    ) -> Bool {
        if hasActiveCoordination {
            return true
        }
        switch currentPhase {
        case .finalized, .failed:
            // A delayed state broadcast from the retired session must not
            // disable the next-session controls after local files are safe.
            return false
        case .inactive, .requesting, .preparing, .armed, .starting, .running,
             .stopping, .finalizing:
            return true
        }
    }
}

enum CaptureInterfaceOrientationLockPolicy {
    static func shouldRelease(
        isStreaming: Bool,
        isFinalizing: Bool,
        hasLogicalCapture: Bool
    ) -> Bool {
        !isStreaming && !isFinalizing && !hasLogicalCapture
    }
}

enum AutomaticRearmAdmissionPolicy {
    static func canAdoptSuccessor(
        isAutomaticRearm: Bool,
        canResetWithoutDiscardingCapture: Bool,
        hasPreviousCoordination: Bool,
        uploadQueueIsEmpty: Bool
    ) -> Bool {
        isAutomaticRearm
            && canResetWithoutDiscardingCapture
            && hasPreviousCoordination
            && uploadQueueIsEmpty
    }
}

enum SynchronizedMembershipRecoveryAction: Equatable {
    case healthy
    case invalidateAndReprepare
    case preserveLocalCapture
}

enum SynchronizedMissingSessionAction: Equatable {
    case clearStaleState
    case preserveLocalCapture
}

enum SynchronizedMissingSessionPolicy {
    static func action(
        isStreaming: Bool,
        isFinalizing: Bool,
        hasLogicalCapture: Bool
    ) -> SynchronizedMissingSessionAction {
        isStreaming || isFinalizing || hasLogicalCapture
            ? .preserveLocalCapture
            : .clearStaleState
    }
}

enum SynchronizedMembershipRecoveryPolicy {
    static func action(
        bothRolesConnected: Bool,
        membershipValid: Bool,
        isStreaming: Bool,
        isFinalizing: Bool,
        hasLogicalCapture: Bool
    ) -> SynchronizedMembershipRecoveryAction {
        guard bothRolesConnected, membershipValid else {
            return isStreaming || isFinalizing || hasLogicalCapture
                ? .preserveLocalCapture
                : .invalidateAndReprepare
        }
        return .healthy
    }
}

enum CapturePackagePresentationPolicy {
    static func shouldPresentManualFallback(
        isCoordinatedCapture: Bool,
        receiverUploadSucceeded: Bool?
    ) -> Bool {
        guard isCoordinatedCapture else { return true }
        return receiverUploadSucceeded == false
    }
}

struct CaptureUploadSuccessNotice: Equatable {
    let destination: String
    let filename: String
}

enum CaptureUploadSuccessNoticePolicy {
    static let displayDuration: TimeInterval = 4

    static func destinationLabel(
        receiverDisplayName: String?,
        host: String
    ) -> String {
        let displayName = receiverDisplayName?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ) ?? ""
        if !displayName.isEmpty {
            return displayName
        }
        return "Mac Receiver (\(host))"
    }
}

struct GroupCaptureCommand: Equatable {
    let command: GroupCaptureCommandName
    let commandID: String
    let sessionID: String
    let generation: Int
    let targetDeviceID: String
    let coordinatorDeadlineNs: UInt64?
    let controllerKind: String?
    let controllerDeviceID: String?
    let sharedDeviceControl: Bool
    let recoveryReset: Bool
    let automaticRearm: Bool

    static func decode(_ payload: [String: Any]) -> GroupCaptureCommand? {
        guard
            payload["protocol_version"] as? Int
                == CaptureCoordinationProtocol.version,
            let commandText = payload["command"] as? String,
            let command = GroupCaptureCommandName(rawValue: commandText),
            let commandID = payload["command_id"] as? String,
            !commandID.isEmpty,
            let sessionID = payload["session_id"] as? String,
            !sessionID.isEmpty,
            let generation = payload["generation"] as? Int,
            generation >= 0,
            let targetDeviceID = payload["target_device_id"] as? String,
            !targetDeviceID.isEmpty
        else {
            return nil
        }
        let deadline: UInt64?
        if let text = payload["coordinator_deadline_ns"] as? String {
            guard let value = UInt64(text) else { return nil }
            deadline = value
        } else {
            deadline = nil
        }
        if command == .prepare {
            guard deadline == nil else { return nil }
        } else {
            guard deadline != nil else { return nil }
        }
        let controllerKind = payload["controller_kind"] as? String
        let controllerDeviceID = payload["controller_device_id"] as? String
        let sharedDeviceControl: Bool
        if let value = payload["shared_device_control"] {
            guard let value = value as? Bool else { return nil }
            sharedDeviceControl = value
        } else {
            sharedDeviceControl = false
        }
        let recoveryReset: Bool
        if let value = payload["recovery_reset"] {
            guard let value = value as? Bool else { return nil }
            recoveryReset = value
        } else {
            recoveryReset = false
        }
        guard command == .prepare || !recoveryReset else { return nil }
        let automaticRearm: Bool
        if let value = payload["automatic_rearm"] {
            guard let value = value as? Bool else { return nil }
            automaticRearm = value
        } else {
            automaticRearm = false
        }
        guard command == .prepare || !automaticRearm else { return nil }
        if let controllerKind,
           controllerKind != "mac" && controllerKind != "device" {
            return nil
        }
        if controllerKind == "device",
           controllerDeviceID?.isEmpty != false {
            return nil
        }
        return GroupCaptureCommand(
            command: command,
            commandID: commandID,
            sessionID: sessionID,
            generation: generation,
            targetDeviceID: targetDeviceID,
            coordinatorDeadlineNs: deadline,
            controllerKind: controllerKind,
            controllerDeviceID: controllerDeviceID,
            sharedDeviceControl: sharedDeviceControl,
            recoveryReset: recoveryReset,
            automaticRearm: automaticRearm
        )
    }
}

struct ActiveCaptureCoordination: Codable, Equatable {
    let sessionID: String
    let generation: Int
    let profile: CaptureProfileSnapshot
    var clockMappingAtStart: CaptureClockMappingSample?
    var clockMappingAtStop: CaptureClockMappingSample? = nil
    var plannedStartCoordinatorNs: UInt64?
    var plannedStartLocalNs: UInt64? = nil
    var actualStartLocalNs: UInt64?
    var plannedStopCoordinatorNs: UInt64?
    var plannedStopLocalNs: UInt64? = nil
    var actualStopLocalNs: UInt64?
    var stopFinalizationStartedLocalNs: UInt64? = nil
    var firstARFrameTimestampSeconds: Double?
    var lastARFrameTimestampSeconds: Double?
    var firstFrameLocalNs: UInt64? = nil
    var lastFrameLocalNs: UInt64? = nil
    var firstFrameCoordinatorNs: UInt64? = nil
    var lastFrameCoordinatorNs: UInt64? = nil
    var rejectedFramesBeforeStart: Int? = nil
    var rejectedFramesAtOrAfterStop: Int? = nil
    var partialReasons: [String] = []

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case generation
        case profile
        case clockMappingAtStart = "clock_mapping_at_start"
        case clockMappingAtStop = "clock_mapping_at_stop"
        case plannedStartCoordinatorNs = "planned_start_coordinator_ns"
        case plannedStartLocalNs = "planned_start_local_ns"
        case actualStartLocalNs = "actual_start_local_ns"
        case plannedStopCoordinatorNs = "planned_stop_coordinator_ns"
        case plannedStopLocalNs = "planned_stop_local_ns"
        case actualStopLocalNs = "actual_stop_local_ns"
        case stopFinalizationStartedLocalNs = "stop_finalization_started_local_ns"
        case firstARFrameTimestampSeconds = "first_arkit_timestamp_s"
        case lastARFrameTimestampSeconds = "last_arkit_timestamp_s"
        case firstFrameLocalNs = "first_frame_local_ns"
        case lastFrameLocalNs = "last_frame_local_ns"
        case firstFrameCoordinatorNs = "first_frame_coordinator_ns"
        case lastFrameCoordinatorNs = "last_frame_coordinator_ns"
        case rejectedFramesBeforeStart = "rejected_frames_before_start"
        case rejectedFramesAtOrAfterStop = "rejected_frames_at_or_after_stop"
        case partialReasons = "partial_reasons"
    }
}
