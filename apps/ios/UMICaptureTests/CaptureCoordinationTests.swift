import XCTest
@testable import UMICapture

final class CaptureCoordinationTests: XCTestCase {
    func testFirstEligibleStopARFrameIsNotMarkedAsMissed() {
        XCTAssertNil(SynchronizedStopBoundaryPolicy.partialReason(
            forcedPartialReason: nil,
            missedDeadline: true,
            isARFrameBoundary: true
        ))
        XCTAssertEqual(
            SynchronizedStopBoundaryPolicy.partialReason(
                forcedPartialReason: nil,
                missedDeadline: true,
                isARFrameBoundary: false
            ),
            "scheduled_deadline_missed"
        )
    }

    func testBothCaptureRolesLockInterfaceOrientationDuringCapture() {
        XCTAssertTrue(
            CaptureProfileID.handheldUMI.enforcesRuntimeInterfaceOrientationLock
        )
        XCTAssertTrue(
            CaptureProfileID.chestEGO.enforcesRuntimeInterfaceOrientationLock
        )
    }

    func testPhysicalRotationCannotOverrideLockedInterfaceOrientation() {
        XCTAssertEqual(
            UMICaptureOrientation.resolvedInterfaceOrientation(
                deviceOrientation: .landscapeLeft,
                sceneOrientation: .landscapeRight,
                lockedOrientation: .landscapeRight
            ),
            .landscapeRight
        )
        XCTAssertEqual(
            UMICaptureOrientation.resolvedInterfaceOrientation(
                deviceOrientation: .landscapeLeft,
                sceneOrientation: .landscapeRight,
                lockedOrientation: nil
            ),
            .landscapeLeft
        )
    }

    func testInterfaceLockReleasesOnlyAfterTerminalFinalization() {
        XCTAssertFalse(
            CaptureInterfaceOrientationLockPolicy.shouldRelease(
                isStreaming: false,
                isFinalizing: true,
                hasLogicalCapture: false
            )
        )
        XCTAssertTrue(
            CaptureInterfaceOrientationLockPolicy.shouldRelease(
                isStreaming: false,
                isFinalizing: false,
                hasLogicalCapture: false
            )
        )
    }

    func testAutomaticRearmCanReplaceCompletedCoordinationAfterUpload() {
        XCTAssertTrue(
            AutomaticRearmAdmissionPolicy.canAdoptSuccessor(
                isAutomaticRearm: true,
                canResetWithoutDiscardingCapture: true,
                hasPreviousCoordination: true,
                uploadQueueIsEmpty: true
            )
        )
        XCTAssertFalse(
            AutomaticRearmAdmissionPolicy.canAdoptSuccessor(
                isAutomaticRearm: true,
                canResetWithoutDiscardingCapture: false,
                hasPreviousCoordination: true,
                uploadQueueIsEmpty: true
            )
        )
    }

    func testSynchronizedBoundaryHapticsAreExactlyOncePerCommand() {
        var feedback: [GroupCaptureCommandName] = []
        let controller = SynchronizedBoundaryFeedbackController {
            feedback.append($0)
        }
        controller.play(command: .start, commandID: "start-a")
        controller.play(command: .start, commandID: "start-a")
        controller.play(command: .stop, commandID: "stop-a")
        controller.play(command: .stop, commandID: "stop-a")
        XCTAssertEqual(feedback, [.start, .stop])
    }
    func testEgoPreviewLayoutDefaultsAndSafeAreaClamping() {
        XCTAssertEqual(
            EgoPreviewLayoutPolicy.defaultPosition(for: .landscape),
            EgoPreviewNormalizedPosition(x: 0, y: 1)
        )
        XCTAssertEqual(
            EgoPreviewLayoutPolicy.defaultPosition(for: .portrait),
            EgoPreviewNormalizedPosition(x: 0.5, y: 0)
        )
        let size = CGSize(width: 844, height: 390)
        let insets = EgoPreviewSafeAreaInsets(
            top: 0,
            leading: 47,
            bottom: 21,
            trailing: 47
        )
        let clamped = EgoPreviewLayoutPolicy.clampedCenter(
            CGPoint(x: -1_000, y: 1_000),
            containerSize: size,
            safeAreaInsets: insets
        )
        XCTAssertEqual(clamped.x, 147, accuracy: 0.001)
        XCTAssertEqual(clamped.y, 291, accuracy: 0.001)
    }

    func testEgoPreviewNormalizedPositionRoundTrips() {
        let size = CGSize(width: 390, height: 844)
        let insets = EgoPreviewSafeAreaInsets(
            top: 59,
            leading: 0,
            bottom: 34,
            trailing: 0
        )
        let expected = EgoPreviewNormalizedPosition(x: 0.23, y: 0.71)
        let center = EgoPreviewLayoutPolicy.center(
            for: expected,
            containerSize: size,
            safeAreaInsets: insets
        )
        let actual = EgoPreviewLayoutPolicy.normalizedPosition(
            for: center,
            containerSize: size,
            safeAreaInsets: insets
        )
        XCTAssertEqual(actual.x, expected.x, accuracy: 0.000_001)
        XCTAssertEqual(actual.y, expected.y, accuracy: 0.000_001)
    }

    func testEgoPreviewAdmissionIsBoundedAndCaptureSafe() {
        XCTAssertTrue(
            EgoPreviewThumbnailPolicy.shouldAdmitEgoFrame(
                role: .ego,
                phase: .preparing,
                hasActiveCoordination: true,
                socketReady: true,
                encoderBusy: false,
                lastCandidateNs: nil,
                nowNs: 1_000_000_000
            )
        )
        XCTAssertFalse(
            EgoPreviewThumbnailPolicy.shouldAdmitEgoFrame(
                role: .ego,
                phase: .running,
                hasActiveCoordination: true,
                socketReady: true,
                encoderBusy: false,
                lastCandidateNs: 1_000_000_000,
                nowNs: 1_399_999_999
            )
        )
        XCTAssertTrue(
            EgoPreviewThumbnailPolicy.shouldAdmitEgoFrame(
                role: .ego,
                phase: .running,
                hasActiveCoordination: true,
                socketReady: true,
                encoderBusy: false,
                lastCandidateNs: 1_000_000_000,
                nowNs: 1_400_000_000
            )
        )
        XCTAssertFalse(
            EgoPreviewThumbnailPolicy.shouldAdmitEgoFrame(
                role: .ego,
                phase: .running,
                hasActiveCoordination: true,
                socketReady: true,
                encoderBusy: true,
                lastCandidateNs: nil,
                nowNs: 1_000_000_000
            )
        )
        XCTAssertFalse(
            EgoPreviewThumbnailPolicy.shouldAdmitEgoFrame(
                role: .wristUMI,
                phase: .running,
                hasActiveCoordination: true,
                socketReady: true,
                encoderBusy: false,
                lastCandidateNs: nil,
                nowNs: 1_000_000_000
            )
        )
    }

    func testEgoPreviewLifecycleEndsBeforeFileFinalization() {
        for phase in [
            SynchronizedCapturePhase.preparing,
            .armed,
            .starting,
            .running,
            .stopping,
        ] {
            XCTAssertTrue(
                EgoPreviewThumbnailPolicy.sessionAcceptsFrames(phase: phase)
            )
        }
        for phase in [
            SynchronizedCapturePhase.inactive,
            .requesting,
            .finalizing,
            .finalized,
            .failed,
        ] {
            XCTAssertFalse(
                EgoPreviewThumbnailPolicy.sessionAcceptsFrames(phase: phase)
            )
        }
        XCTAssertTrue(
            EgoPreviewThumbnailPolicy.shouldDisplayOnHand(
                role: .wristUMI,
                phase: .running,
                hasActiveCoordination: true,
                hasImage: true
            )
        )
        XCTAssertFalse(
            EgoPreviewThumbnailPolicy.shouldDisplayOnHand(
                role: .ego,
                phase: .running,
                hasActiveCoordination: true,
                hasImage: true
            )
        )
    }

    func testEgoPreviewStaleAndSequencePoliciesAreFailClosed() {
        XCTAssertFalse(
            EgoPreviewThumbnailPolicy.isStale(
                lastReceivedNs: 1_000_000_000,
                nowNs: 2_500_000_000
            )
        )
        XCTAssertTrue(
            EgoPreviewThumbnailPolicy.isStale(
                lastReceivedNs: 1_000_000_000,
                nowNs: 2_500_000_001
            )
        )
        XCTAssertTrue(EgoPreviewThumbnailPolicy.acceptsSequence(1, after: nil))
        XCTAssertTrue(EgoPreviewThumbnailPolicy.acceptsSequence(2, after: 1))
        XCTAssertFalse(EgoPreviewThumbnailPolicy.acceptsSequence(1, after: 1))
    }

    func testEgoPreviewPayloadRequiresBoundedJPEGAndOrientation() {
        let JPEG = Data([0xff, 0xd8, 0xff, 0xd9])
        var payload: [String: Any] = [
            "protocol_version": 1,
            "session_id": "session-1",
            "generation": 2,
            "device_id": "ego-1",
            "capture_role": "ego",
            "sequence": "1",
            "arkit_timestamp_s": 12.5,
            "sender_monotonic_ns": "1000000000",
            "orientation": "landscape_left",
            "jpeg_base64": JPEG.base64EncodedString(),
        ]
        XCTAssertEqual(
            EgoPreviewFramePayload.decode(payload)?.jpegData,
            JPEG
        )

        payload["orientation"] = "unknown"
        XCTAssertNil(EgoPreviewFramePayload.decode(payload))
        payload["orientation"] = "portrait"
        payload["capture_role"] = "wrist_umi"
        XCTAssertNil(EgoPreviewFramePayload.decode(payload))
        payload["capture_role"] = "ego"
        payload["session_id"] = ""
        XCTAssertNil(EgoPreviewFramePayload.decode(payload))
        payload["session_id"] = "session-1"
        payload["jpeg_base64"] = Data(
            repeating: 0xaa,
            count: EgoPreviewThumbnailPolicy.maximumJPEGBytes + 1
        ).base64EncodedString()
        XCTAssertNil(EgoPreviewFramePayload.decode(payload))
    }

    func testClockEstimatorMapsMidpointsAndBoundsUncertainty() {
        var estimator = CoordinatorClockEstimator()
        let sample = estimator.accept(
            probeID: "p1",
            localSendNs: 1_000,
            localReceiveNs: 1_200,
            coordinatorReceiveNs: 2_050,
            coordinatorSendNs: 2_070
        )
        XCTAssertEqual(sample?.rttNs, 180)
        XCTAssertEqual(sample?.uncertaintyNs, 90)
        XCTAssertEqual(sample?.offsetNs, 960)
        XCTAssertEqual(sample?.localMonotonicNs(forCoordinator: 2_460), 1_500)
    }

    func testClockEstimatorRejectsImpossibleAndStaleSamples() {
        var estimator = CoordinatorClockEstimator()
        XCTAssertNil(
            estimator.accept(
                probeID: "invalid",
                localSendNs: 2_000,
                localReceiveNs: 1_000,
                coordinatorReceiveNs: 3_000,
                coordinatorSendNs: 3_100
            )
        )
        _ = estimator.accept(
            probeID: "valid",
            localSendNs: 1_000,
            localReceiveNs: 1_100,
            coordinatorReceiveNs: 2_000,
            coordinatorSendNs: 2_020
        )
        XCTAssertNil(
            estimator.bestSample(
                nowLocalMonotonicNs:
                    1_100 + CaptureCoordinationPolicy.maximumClockSampleAgeNs + 1
            )
        )
    }

    func testClockEstimatorFusesRepeatedHigherRTTSamples() {
        var estimator = CoordinatorClockEstimator()
        XCTAssertNil(
            estimator.accept(
                probeID: "slow-1",
                localSendNs: 0,
                localReceiveNs: 20_000_000,
                coordinatorReceiveNs: 1_010_000_000,
                coordinatorSendNs: 1_010_000_000
            )
        )
        let fused = estimator.accept(
            probeID: "slow-2",
            localSendNs: 30_000_000,
            localReceiveNs: 50_000_000,
            coordinatorReceiveNs: 1_044_000_000,
            coordinatorSendNs: 1_044_000_000
        )
        XCTAssertEqual(fused?.offsetNs, 1_002_000_000)
        XCTAssertEqual(fused?.uncertaintyNs, 8_000_000)
        XCTAssertEqual(fused?.sampledAtLocalMonotonicNs, 50_000_000)
    }

    func testClockEstimatorKeepsStableHighRTTMappingFresh() {
        var estimator = CoordinatorClockEstimator()
        var latest: CaptureClockMappingSample?
        for index in 0..<8 {
            let localSend = UInt64(index) * 100_000_000
            latest = estimator.accept(
                probeID: "stable-\(index)",
                localSendNs: localSend,
                localReceiveNs: localSend + 30_000_000,
                coordinatorReceiveNs: localSend + 1_015_000_000,
                coordinatorSendNs: localSend + 1_015_000_000
            )
        }
        XCTAssertEqual(latest?.offsetNs, 1_000_000_000)
        XCTAssertEqual(latest?.uncertaintyNs, 1_000_000)
        XCTAssertEqual(latest?.sampledAtLocalMonotonicNs, 730_000_000)
    }

    func testCommandDecodeRequiresTargetAndDeadlinePolicy() {
        let common: [String: Any] = [
            "protocol_version": 1,
            "command_id": "command-1",
            "session_id": "session-1",
            "generation": 3,
            "target_device_id": "device-1"
        ]
        var prepare = common
        prepare["command"] = "prepare"
        XCTAssertNotNil(GroupCaptureCommand.decode(prepare))
        prepare["recovery_reset"] = true
        XCTAssertEqual(GroupCaptureCommand.decode(prepare)?.recoveryReset, true)
        prepare["recovery_reset"] = false
        prepare["automatic_rearm"] = true
        XCTAssertEqual(GroupCaptureCommand.decode(prepare)?.automaticRearm, true)
        prepare["automatic_rearm"] = "true"
        XCTAssertNil(GroupCaptureCommand.decode(prepare))
        prepare["automatic_rearm"] = false
        prepare["recovery_reset"] = "true"
        XCTAssertNil(GroupCaptureCommand.decode(prepare))
        prepare["recovery_reset"] = false
        prepare["coordinator_deadline_ns"] = "100"
        XCTAssertNil(GroupCaptureCommand.decode(prepare))

        var start = common
        start["command"] = "start"
        XCTAssertNil(GroupCaptureCommand.decode(start))
        start["coordinator_deadline_ns"] = "100"
        start["controller_kind"] = "device"
        start["controller_device_id"] = "device-1"
        start["shared_device_control"] = true
        XCTAssertEqual(GroupCaptureCommand.decode(start)?.generation, 3)
        XCTAssertEqual(
            GroupCaptureCommand.decode(start)?.controllerDeviceID,
            "device-1"
        )
        XCTAssertEqual(
            GroupCaptureCommand.decode(start)?.sharedDeviceControl,
            true
        )
        start["recovery_reset"] = true
        XCTAssertNil(GroupCaptureCommand.decode(start))
        start["recovery_reset"] = false
        start["automatic_rearm"] = true
        XCTAssertNil(GroupCaptureCommand.decode(start))
        start["automatic_rearm"] = false

        start["controller_kind"] = "invalid"
        XCTAssertNil(GroupCaptureCommand.decode(start))
    }

    func testLedgerIsIdempotentAndRejectsStaleGeneration() {
        var ledger = CaptureCommandLedger()
        let first = command(name: .start, id: "same", generation: 2)
        XCTAssertEqual(ledger.disposition(for: first), .execute)
        ledger.record(state: "scheduled", for: first)
        XCTAssertEqual(
            ledger.disposition(for: first),
            .duplicate(previousState: "scheduled")
        )
        XCTAssertEqual(
            ledger.disposition(
                for: command(name: .pause, id: "old", generation: 1)
            ),
            .staleGeneration
        )
        XCTAssertEqual(
            ledger.disposition(
                for: command(name: .pause, id: "same", generation: 2)
            ),
            .conflictingCommandID
        )
    }

    func testDeadlineToleranceBoundaryIsCentralizedAndFailClosed() {
        let deadline: UInt64 = 1_000
        let tolerance = CaptureCoordinationPolicy.lateCommandToleranceNs
        XCTAssertFalse(
            CaptureCoordinationPolicy.missedDeadline(
                nowNs: deadline + tolerance,
                deadlineNs: deadline
            )
        )
        XCTAssertTrue(
            CaptureCoordinationPolicy.missedDeadline(
                nowNs: deadline + tolerance + 1,
                deadlineNs: deadline
            )
        )
    }

    func testFrameWindowIsStartInclusiveAndStopExclusive() {
        XCTAssertFalse(
            CaptureFrameWindow.admits(
                frameLocalNs: 999,
                startLocalNs: 1_000,
                stopLocalNs: 2_000
            )
        )
        XCTAssertTrue(
            CaptureFrameWindow.admits(
                frameLocalNs: 1_000,
                startLocalNs: 1_000,
                stopLocalNs: 2_000
            )
        )
        XCTAssertTrue(
            CaptureFrameWindow.admits(
                frameLocalNs: 1_999,
                startLocalNs: 1_000,
                stopLocalNs: 2_000
            )
        )
        XCTAssertFalse(
            CaptureFrameWindow.admits(
                frameLocalNs: 2_000,
                startLocalNs: 1_000,
                stopLocalNs: 2_000
            )
        )
    }

    func testUncalibratedPreparationWaitsForFreshNormalFrameThenArms() {
        XCTAssertEqual(
            UncalibratedPreparationPolicy.action(trackingIsNormal: false),
            .waitForNormalTracking
        )
        XCTAssertEqual(
            UncalibratedPreparationPolicy.action(trackingIsNormal: true),
            .arm
        )
    }

    func testReadyPreparationWireTombstoneDisablesRemovedBoardTruth() {
        let tombstone = ReceiverPreparationCompatibility.readyTombstone()

        XCTAssertEqual(Set(tombstone.keys), [
            "phase",
            "stationary_duration_s",
            "gyro_rms_rad_s",
            "gyro_peak_rad_s",
            "vision_board_calibration_enabled",
            "calibration_reused",
            "training_truth_eligible",
            "frame_direction_alignment"
        ])
        XCTAssertEqual(tombstone["phase"] as? String, "ready")
        XCTAssertEqual(tombstone["stationary_duration_s"] as? Double, 0)
        XCTAssertEqual(tombstone["gyro_rms_rad_s"] as? Double, 0)
        XCTAssertEqual(tombstone["gyro_peak_rad_s"] as? Double, 0)
        XCTAssertEqual(
            tombstone["vision_board_calibration_enabled"] as? Bool,
            false
        )
        XCTAssertEqual(tombstone["calibration_reused"] as? Bool, false)
        XCTAssertEqual(
            tombstone["training_truth_eligible"] as? Bool,
            false
        )
        XCTAssertEqual(
            tombstone["frame_direction_alignment"] as? String,
            FrameDirectionAlignmentPolicy.identifier
        )
    }

    func testSynchronizedStartAndStopUseFirstARFrameAtOrAfterDeadline() {
        XCTAssertFalse(
            SynchronizedFrameBoundaryPolicy.shouldExecute(
                command: .start,
                frameLocalNs: 999,
                deadlineLocalNs: 1_000
            )
        )
        XCTAssertTrue(
            SynchronizedFrameBoundaryPolicy.shouldExecute(
                command: .start,
                frameLocalNs: 1_000,
                deadlineLocalNs: 1_000
            )
        )
        XCTAssertTrue(
            SynchronizedFrameBoundaryPolicy.shouldExecute(
                command: .stop,
                frameLocalNs: 1_010,
                deadlineLocalNs: 1_000
            )
        )
        XCTAssertFalse(
            SynchronizedFrameBoundaryPolicy.shouldExecute(
                command: .pause,
                frameLocalNs: 1_010,
                deadlineLocalNs: 1_000
            )
        )
    }

    func testGroupPrepareAdoptsUnstartedLocalPreparationButRejectsLiveFlows() {
        XCTAssertTrue(groupPreparationAdmission())
        XCTAssertFalse(groupPreparationAdmission(isStreaming: true))
        XCTAssertTrue(groupPreparationAdmission(isStarting: true))
        XCTAssertTrue(groupPreparationAdmission(isCalibrating: true))
        XCTAssertTrue(groupPreparationAdmission(isCalibrationReady: true))
        XCTAssertFalse(groupPreparationAdmission(isFinalizing: true))
        XCTAssertFalse(groupPreparationAdmission(hasLogicalCapture: true))
        XCTAssertFalse(groupPreparationAdmission(hasActiveCoordination: true))
        XCTAssertFalse(groupPreparationAdmission(captureRoleLocked: true))
    }

    func testSynchronizedControlRoutesOnlyTheSelectedController() {
        XCTAssertTrue(SynchronizedCapturePhase.inactive.allowsNewSessionRequest)
        XCTAssertTrue(SynchronizedCapturePhase.finalized.allowsNewSessionRequest)
        XCTAssertTrue(SynchronizedCapturePhase.failed.allowsNewSessionRequest)
        XCTAssertFalse(SynchronizedCapturePhase.running.allowsNewSessionRequest)
        XCTAssertEqual(
            SynchronizedCaptureControlPolicy.primaryAction(
                phase: .inactive,
                isController: false
            ),
            .localStart
        )
        XCTAssertEqual(
            SynchronizedCaptureControlPolicy.primaryAction(
                phase: .armed,
                isController: true
            ),
            .group(.start)
        )
        XCTAssertEqual(
            SynchronizedCaptureControlPolicy.primaryAction(
                phase: .running,
                isController: true
            ),
            .disabled
        )
        XCTAssertEqual(
            SynchronizedCaptureControlPolicy.endAction(
                phase: .running,
                isController: true
            ),
            .group(.stop)
        )
        XCTAssertEqual(
            SynchronizedCaptureControlPolicy.primaryAction(
                phase: .armed,
                isController: false
            ),
            .disabled
        )
    }

    func testSharedDeviceControlMakesBothRegisteredPhonesControllers() {
        for deviceID in ["wrist-device", "ego-device"] {
            XCTAssertTrue(
                SynchronizedCaptureControlPolicy.deviceCanControl(
                    controllerKind: "device",
                    initiatingDeviceID: "wrist-device",
                    sharedDeviceControl: true,
                    controllerCapable: true,
                    localDeviceID: deviceID
                )
            )
        }
        XCTAssertTrue(
            SynchronizedCaptureControlPolicy.deviceCanControl(
                controllerKind: "mac",
                initiatingDeviceID: nil,
                sharedDeviceControl: true,
                controllerCapable: true,
                localDeviceID: "wrist-device"
            )
        )
        XCTAssertFalse(
            SynchronizedCaptureControlPolicy.deviceCanControl(
                controllerKind: "device",
                initiatingDeviceID: "wrist-device",
                sharedDeviceControl: false,
                controllerCapable: true,
                localDeviceID: "ego-device"
            )
        )
        XCTAssertTrue(
            SynchronizedCaptureControlPolicy.effectiveController(
                cachedController: false,
                sharedDeviceControl: true,
                controllerCapable: true
            )
        )
        XCTAssertFalse(
            SynchronizedCaptureControlPolicy.effectiveController(
                cachedController: false,
                sharedDeviceControl: false,
                controllerCapable: true
            )
        )
        XCTAssertFalse(
            SynchronizedCaptureControlPolicy.deviceCanControl(
                controllerKind: "device",
                initiatingDeviceID: "wrist-device",
                sharedDeviceControl: true,
                controllerCapable: false,
                localDeviceID: "ego-device"
            )
        )
    }

    func testEitherHardwareButtonStartsThenEndsSynchronizedCapture() {
        XCTAssertEqual(
            SynchronizedCaptureControlPolicy.hardwareToggleAction(
                phase: .armed,
                isController: true
            ),
            .group(.start)
        )
        XCTAssertEqual(
            SynchronizedCaptureControlPolicy.hardwareToggleAction(
                phase: .running,
                isController: true
            ),
            .group(.stop)
        )
        XCTAssertEqual(
            SynchronizedCaptureControlPolicy.hardwareToggleAction(
                phase: .running,
                isController: false
            ),
            .localEnd
        )
        XCTAssertEqual(
            SynchronizedCaptureControlPolicy.hardwareToggleAction(
                phase: .armed,
                isController: false
            ),
            .disabled
        )
        XCTAssertEqual(
            SynchronizedCaptureControlPolicy.hardwareToggleAction(
                phase: .inactive,
                isController: false
            ),
            .localStart
        )
    }

    func testSessionOwnershipReleasesOnlyAfterLocalDataIsSafe() {
        XCTAssertTrue(
            SynchronizedSessionLifecyclePolicy.canReleaseLocalOwnership(
                isStreaming: false,
                isFinalizing: false,
                hasLogicalCapture: false
            )
        )
        XCTAssertFalse(
            SynchronizedSessionLifecyclePolicy.canReleaseLocalOwnership(
                isStreaming: true,
                isFinalizing: false,
                hasLogicalCapture: true
            )
        )
        XCTAssertFalse(
            SynchronizedSessionLifecyclePolicy.canReleaseLocalOwnership(
                isStreaming: false,
                isFinalizing: true,
                hasLogicalCapture: false
            )
        )
        XCTAssertFalse(
            SynchronizedSessionLifecyclePolicy.canReleaseLocalOwnership(
                isStreaming: false,
                isFinalizing: false,
                hasLogicalCapture: true
            )
        )
    }

    func testMembershipLossRevokesArmedStateButPreservesActiveLocalData() {
        XCTAssertEqual(
            SynchronizedMembershipRecoveryPolicy.action(
                bothRolesConnected: false,
                membershipValid: false,
                isStreaming: false,
                isFinalizing: false,
                hasLogicalCapture: false
            ),
            .invalidateAndReprepare
        )
        XCTAssertEqual(
            SynchronizedMembershipRecoveryPolicy.action(
                bothRolesConnected: false,
                membershipValid: false,
                isStreaming: true,
                isFinalizing: false,
                hasLogicalCapture: true
            ),
            .preserveLocalCapture
        )
        XCTAssertEqual(
            SynchronizedMembershipRecoveryPolicy.action(
                bothRolesConnected: true,
                membershipValid: true,
                isStreaming: false,
                isFinalizing: false,
                hasLogicalCapture: false
            ),
            .healthy
        )
    }

    func testSuccessfulReceiverUploadDoesNotPresentShareOrPreview() {
        XCTAssertFalse(
            CapturePackagePresentationPolicy.shouldPresentManualFallback(
                isCoordinatedCapture: true,
                receiverUploadSucceeded: true
            )
        )
        XCTAssertTrue(
            CapturePackagePresentationPolicy.shouldPresentManualFallback(
                isCoordinatedCapture: true,
                receiverUploadSucceeded: false
            )
        )
        XCTAssertFalse(
            CapturePackagePresentationPolicy.shouldPresentManualFallback(
                isCoordinatedCapture: true,
                receiverUploadSucceeded: nil
            )
        )
        XCTAssertTrue(
            CapturePackagePresentationPolicy.shouldPresentManualFallback(
                isCoordinatedCapture: false,
                receiverUploadSucceeded: nil
            )
        )
    }

    func testSuccessfulUploadNoticeNamesDestinationAndFile() {
        XCTAssertEqual(
            CaptureUploadSuccessNoticePolicy.destinationLabel(
                receiverDisplayName: "  Lab Mac  ",
                host: "192.0.2.20"
            ),
            "Lab Mac"
        )
        XCTAssertEqual(
            CaptureUploadSuccessNoticePolicy.destinationLabel(
                receiverDisplayName: nil,
                host: "192.0.2.20"
            ),
            "Mac Receiver (192.0.2.20)"
        )
        XCTAssertEqual(CaptureUploadSuccessNoticePolicy.displayDuration, 4)
    }

    func testRetiredSessionCannotRegressToDelayedNonterminalState() {
        XCTAssertFalse(
            SynchronizedSessionLifecyclePolicy
                .shouldApplyNonterminalGroupState(
                    hasActiveCoordination: false,
                    currentPhase: .finalized
                )
        )
        XCTAssertFalse(
            SynchronizedSessionLifecyclePolicy
                .shouldApplyNonterminalGroupState(
                    hasActiveCoordination: false,
                    currentPhase: .failed
                )
        )
        XCTAssertTrue(
            SynchronizedSessionLifecyclePolicy
                .shouldApplyNonterminalGroupState(
                    hasActiveCoordination: true,
                    currentPhase: .finalized
                )
        )
        XCTAssertTrue(
            SynchronizedSessionLifecyclePolicy
                .shouldApplyNonterminalGroupState(
                    hasActiveCoordination: false,
                    currentPhase: .requesting
                )
        )
    }

    func testResetCannotDiscardAnActiveOrFinalizingCapture() {
        XCTAssertTrue(
            SynchronizedSessionLifecyclePolicy
                .canResetWithoutDiscardingCapture(
                    isStreaming: false,
                    isFinalizing: false,
                    hasLogicalCapture: false,
                    recorderPhase: .idle
                )
        )
        XCTAssertFalse(
            SynchronizedSessionLifecyclePolicy
                .canResetWithoutDiscardingCapture(
                    isStreaming: true,
                    isFinalizing: false,
                    hasLogicalCapture: true,
                    recorderPhase: .recording
                )
        )
        XCTAssertFalse(
            SynchronizedSessionLifecyclePolicy
                .canResetWithoutDiscardingCapture(
                    isStreaming: false,
                    isFinalizing: false,
                    hasLogicalCapture: true,
                    recorderPhase: .idle
                )
        )
        XCTAssertFalse(
            SynchronizedSessionLifecyclePolicy
                .canResetWithoutDiscardingCapture(
                    isStreaming: false,
                    isFinalizing: true,
                    hasLogicalCapture: false,
                    recorderPhase: .finishing
                )
        )
    }

    func testPeerRetainsEmergencyEndDuringActiveCapture() {
        XCTAssertEqual(
            SynchronizedCaptureControlPolicy.endAction(
                phase: .running,
                isController: false
            ),
            .localEnd
        )
    }

    func testSynchronizedPreparationButtonNeverStartsCapture() {
        XCTAssertEqual(
            SynchronizedPreparationButtonPolicy.action(
                phase: .failed,
                isController: false
            ),
            .prepare
        )
        XCTAssertEqual(
            SynchronizedPreparationButtonPolicy.action(
                phase: .armed,
                isController: true
            ),
            .unavailable
        )
        XCTAssertEqual(
            SynchronizedPreparationButtonPolicy.action(
                phase: .armed,
                isController: false
            ),
            .unavailable
        )
    }

    func testImmediatePrepareIsNotReplayedByRegistrationAcknowledgement() {
        var delivery = GroupPreparationRequestDeliveryState()
        let immediate = delivery.begin(
            recoverPreviousSession: true,
            ready: true,
            registrationAcknowledged: true,
            requestID: "one-tap"
        )

        XCTAssertEqual(
            immediate,
            PendingGroupPreparationRequest(
                requestID: "one-tap",
                recoverPreviousSession: true
            )
        )
        XCTAssertNil(delivery.takeAfterRegistrationAcknowledgement())
    }

    func testPrepareQueuedBeforeRegistrationIsReplayedExactlyOnce() {
        var delivery = GroupPreparationRequestDeliveryState()
        XCTAssertNil(
            delivery.begin(
                recoverPreviousSession: true,
                ready: true,
                registrationAcknowledged: false,
                requestID: "queued-tap"
            )
        )

        XCTAssertEqual(
            delivery.takeAfterRegistrationAcknowledgement(),
            PendingGroupPreparationRequest(
                requestID: "queued-tap",
                recoverPreviousSession: true
            )
        )
        XCTAssertNil(delivery.takeAfterRegistrationAcknowledgement())
    }

    func testQueuedPreparePreservesOptionalAutoRearmChoice() {
        var delivery = GroupPreparationRequestDeliveryState()
        XCTAssertNil(delivery.begin(
            recoverPreviousSession: false,
            autoRearmAfterCapture: true,
            ready: false,
            registrationAcknowledged: false,
            requestID: "prepare-auto-rearm"
        ))
        let replay = delivery.takeAfterRegistrationAcknowledgement()
        XCTAssertEqual(replay?.requestID, "prepare-auto-rearm")
        XCTAssertEqual(replay?.autoRearmAfterCapture, true)
    }

    func testStartQueuedDuringRegistrationIsNotSilentlyDropped() {
        var delivery = GroupTransitionRequestDeliveryState()
        XCTAssertNil(
            delivery.begin(
                command: .start,
                ready: true,
                registrationAcknowledged: false,
                requestID: "queued-start"
            )
        )

        XCTAssertEqual(
            delivery.takeAfterRegistrationAcknowledgement(),
            PendingGroupTransitionRequest(
                command: .start,
                requestID: "queued-start"
            )
        )
        XCTAssertNil(delivery.takeAfterRegistrationAcknowledgement())
    }

    func testImmediateStartIsNotReplayedAfterRegistration() {
        var delivery = GroupTransitionRequestDeliveryState()
        XCTAssertEqual(
            delivery.begin(
                command: .start,
                ready: true,
                registrationAcknowledged: true,
                requestID: "immediate-start"
            ),
            PendingGroupTransitionRequest(
                command: .start,
                requestID: "immediate-start"
            )
        )
        XCTAssertNil(delivery.takeAfterRegistrationAcknowledgement())
    }

    func testPartialEvidenceKeepsEndControlsWhileCaptureExists() {
        XCTAssertTrue(
            ViewController.shouldPreserveControlsForPartialGroupState(
                isStreaming: true,
                isFinalizing: false,
                hasLogicalCapture: true
            )
        )
        XCTAssertTrue(
            ViewController.shouldPreserveControlsForPartialGroupState(
                isStreaming: false,
                isFinalizing: true,
                hasLogicalCapture: true
            )
        )
        XCTAssertFalse(
            ViewController.shouldPreserveControlsForPartialGroupState(
                isStreaming: false,
                isFinalizing: false,
                hasLogicalCapture: false
            )
        )
    }

    func testMissingReceiverSessionClearsStaleReadyStateWhenIdle() {
        XCTAssertEqual(
            SynchronizedMissingSessionPolicy.action(
                isStreaming: false,
                isFinalizing: false,
                hasLogicalCapture: false
            ),
            .clearStaleState
        )
    }

    func testMissingReceiverSessionPreservesAnActiveLocalCapture() {
        XCTAssertEqual(
            SynchronizedMissingSessionPolicy.action(
                isStreaming: true,
                isFinalizing: false,
                hasLogicalCapture: true
            ),
            .preserveLocalCapture
        )
    }

    func testRoleNamedProcessedVideoIsSelectedForPreview() {
        XCTAssertTrue(
            ViewController.isPrimaryPreviewVideoURL(
                URL(fileURLWithPath: "/tmp/ego_rgb_224.mp4")
            )
        )
        XCTAssertTrue(
            ViewController.isPrimaryPreviewVideoURL(
                URL(fileURLWithPath: "/tmp/hand_rgb_224.mp4")
            )
        )
        XCTAssertTrue(
            ViewController.isPrimaryPreviewVideoURL(
                URL(fileURLWithPath: "/tmp/rgb.mp4")
            )
        )
        XCTAssertFalse(
            ViewController.isPrimaryPreviewVideoURL(
                URL(fileURLWithPath: "/tmp/ultrawide_rgb.mp4")
            )
        )
    }

    func testClockFailureStillHonorsStopLocallyAndRejectsLegacyPauseResume() {
        XCTAssertEqual(
            SynchronizedCaptureControlPolicy.clockFailureAction(for: .stop),
            .executeImmediatelyAndMarkUnsynchronized
        )
        for command in [
            GroupCaptureCommandName.prepare,
            .start,
            .pause,
            .resume,
        ] {
            XCTAssertEqual(
                SynchronizedCaptureControlPolicy.clockFailureAction(
                    for: command
                ),
                .reject
            )
        }
    }

    func testFinalizedArtifactReferenceFreezesCompleteUploadIdentity()
        throws {
        let packageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".zip")
        let payload = Data("authorized-package".utf8)
        try payload.write(to: packageURL)
        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".mp4")
        try Data("source-video".utf8).write(to: sourceURL)
        defer {
            try? FileManager.default.removeItem(at: packageURL)
            try? FileManager.default.removeItem(at: sourceURL)
        }

        let references = ViewController.artifactReferences(
            from: CompletedCaptureArtifacts(
                trajectoryURL: nil,
                rgbVideoURLs: [sourceURL],
                primaryVideoURL: nil,
                exportPackageURL: packageURL,
                exportError: nil
            )
        )
        XCTAssertEqual(references.count, 1)
        let reference = try XCTUnwrap(references.first)
        XCTAssertEqual(reference["name"] as? String, packageURL.lastPathComponent)
        XCTAssertEqual(reference["platform"] as? String, "iOS")
        XCTAssertEqual(
            (reference["size_bytes"] as? NSNumber)?.uint64Value,
            UInt64(payload.count)
        )
        XCTAssertEqual(
            reference["sha256"] as? String,
            "effe7af84f22b9f732f93f0fcecc34e9ecf2b8b256368dbfe0ce50220b41923d"
        )
    }

    func testFrozenGrantReplayRequiresExactPendingZipIdentity() throws {
        let digest = String(repeating: "a", count: 64)
        let expected = try XCTUnwrap(
            CoordinatedCaptureUploadFileIdentity(
                artifactReference: [
                    "name": "UMICapture-session-hand.zip",
                    "platform": "iOS",
                    "size_bytes": NSNumber(value: 4_096),
                    "sha256": digest
                ],
                deviceID: "device-hand"
            )
        )
        let fileIdentity: [String: Any] = [
            "filename": expected.filename,
            "device_id": expected.deviceID,
            "platform": expected.platform,
            "size_bytes": NSNumber(value: expected.sizeBytes),
            "sha256": expected.sha256
        ]
        let grant: [String: Any] = [
            "schema_version": 1,
            "session_id": "session-1",
            "generation": 7,
            "device_id": expected.deviceID,
            "file_identity": fileIdentity
        ]
        XCTAssertTrue(
            FrozenCoordinatedUploadGrantReplayPolicy.authorizes(
                grant: grant,
                expectedSessionID: "session-1",
                expectedGeneration: 7,
                expectedIdentity: expected
            )
        )

        for (key, value) in [
            ("session_id", "session-2" as Any),
            ("generation", 8 as Any),
            ("generation", true as Any),
            ("device_id", "device-ego" as Any)
        ] {
            var alteredGrant = grant
            alteredGrant[key] = value
            XCTAssertFalse(
                FrozenCoordinatedUploadGrantReplayPolicy.authorizes(
                    grant: alteredGrant,
                    expectedSessionID: "session-1",
                    expectedGeneration: 7,
                    expectedIdentity: expected
                )
            )
        }

        for (key, value) in [
            ("filename", "other.zip" as Any),
            ("device_id", "device-ego" as Any),
            ("platform", "macOS" as Any),
            ("size_bytes", 4_097 as Any),
            ("size_bytes", true as Any),
            ("sha256", String(repeating: "b", count: 64) as Any)
        ] {
            var alteredIdentity = fileIdentity
            alteredIdentity[key] = value
            var alteredGrant = grant
            alteredGrant["file_identity"] = alteredIdentity
            XCTAssertFalse(
                FrozenCoordinatedUploadGrantReplayPolicy.authorizes(
                    grant: alteredGrant,
                    expectedSessionID: "session-1",
                    expectedGeneration: 7,
                    expectedIdentity: expected
                )
            )
        }

        var unboundGrant = grant
        unboundGrant["file_identity"] = nil
        XCTAssertFalse(
            FrozenCoordinatedUploadGrantReplayPolicy.authorizes(
                grant: unboundGrant,
                expectedSessionID: "session-1",
                expectedGeneration: 7,
                expectedIdentity: expected
            )
        )
    }

    private func groupPreparationAdmission(
        isStreaming: Bool = false,
        isStarting: Bool = false,
        isCalibrating: Bool = false,
        isCalibrationReady: Bool = false,
        isFinalizing: Bool = false,
        hasLogicalCapture: Bool = false,
        hasActiveCoordination: Bool = false,
        captureRoleLocked: Bool = false
    ) -> Bool {
        ViewController.canBeginGroupPreparation(
            isStreaming: isStreaming,
            isStarting: isStarting,
            isCalibrating: isCalibrating,
            isCalibrationReady: isCalibrationReady,
            isFinalizing: isFinalizing,
            hasLogicalCapture: hasLogicalCapture,
            hasActiveCoordination: hasActiveCoordination,
            captureRoleLocked: captureRoleLocked
        )
    }

    private func command(
        name: GroupCaptureCommandName,
        id: String,
        generation: Int
    ) -> GroupCaptureCommand {
        GroupCaptureCommand(
            command: name,
            commandID: id,
            sessionID: "session",
            generation: generation,
            targetDeviceID: "device",
            coordinatorDeadlineNs: name == .prepare ? nil : 1_000,
            controllerKind: "device",
            controllerDeviceID: "device",
            sharedDeviceControl: false,
            recoveryReset: false,
            automaticRearm: false
        )
    }
}
