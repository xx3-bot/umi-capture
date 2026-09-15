import XCTest
import simd
@testable import UMICapture

final class CaptureProfileMetadataTests: XCTestCase {

    func testHandheldProfileBindsWristRoleAndUncalibratedTruthfully() throws {
        let profile = CaptureProfileSnapshot.make(
            deviceID: "device",
            profileID: .handheldUMI,
            gripperID: "gripper-a",
            calibrationID: nil,
            lockedAtLocalMonotonicNs: 42
        )
        XCTAssertEqual(profile.captureRole, .wristUMI)
        XCTAssertEqual(profile.gripperID, "gripper-a")
        XCTAssertEqual(profile.calibration.kind, .cameraToTCP)
        XCTAssertEqual(profile.calibration.status, .uncalibrated)
        XCTAssertNil(profile.calibration.calibrationID)
        XCTAssertNil(profile.physicalTCPProfile)
        let encoded = try JSONEncoder().encode(profile)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("tcp_pose"))
    }

    func testChestProfileCannotCarryGripperSemantics() {
        let profile = CaptureProfileSnapshot.make(
            deviceID: "device",
            profileID: .chestEGO,
            gripperID: "must-be-removed",
            calibrationID: "body-calibration-1",
            lockedAtLocalMonotonicNs: 7
        )
        XCTAssertEqual(profile.captureRole, .ego)
        XCTAssertNil(profile.gripperID)
        XCTAssertEqual(profile.calibration.kind, .cameraToBody)
        XCTAssertEqual(profile.calibration.status, .calibrated)
        XCTAssertTrue(
            CaptureProfileID.chestEGO.observationRequirementIsSatisfied(
                by: .privateAPIUnavailable
            )
        )
    }

    func testCaptureDataKeysFollowLockedRoleWithLegacyFallback() {
        let hand = CaptureProfileSnapshot.make(
            deviceID: "hand",
            profileID: .handheldUMI,
            gripperID: nil,
            calibrationID: nil,
            lockedAtLocalMonotonicNs: 1
        )
        let chest = CaptureProfileSnapshot.make(
            deviceID: "chest",
            profileID: .chestEGO,
            gripperID: nil,
            calibrationID: nil,
            lockedAtLocalMonotonicNs: 2
        )

        XCTAssertEqual(CaptureDataKey.main(for: hand), "wrist_rgb")
        XCTAssertEqual(
            CaptureDataKey.ultrawide(for: hand),
            "wrist_rgb_ultrawide"
        )
        XCTAssertEqual(CaptureDataKey.main(for: chest), "ego_rgb")
        XCTAssertEqual(
            CaptureDataKey.ultrawide(for: chest),
            "ego_rgb_ultrawide"
        )
        XCTAssertEqual(CaptureDataKey.main(for: nil), "ego_rgb")
        XCTAssertEqual(
            CaptureDataKey.ultrawide(for: nil),
            "ego_rgb_ultrawide"
        )

        XCTAssertEqual(
            UMIImagePreprocessing.fixed224(
                sourceWidth: 1920,
                sourceHeight: 1440,
                dataKey: CaptureDataKey.main(for: hand),
                rotationDegrees: 180
            ).dataKey,
            "wrist_rgb"
        )
    }

    func testFrozenOrientationProducesPhysicallyUprightUMIMetadata() {
        XCTAssertEqual(
            UMICaptureOrientation.uprightRotationDegrees(
                forMetadataValue: "landscape_left"
            ),
            180
        )
        XCTAssertEqual(
            UMICaptureOrientation.uprightRotationDegrees(
                forMetadataValue: "portrait"
            ),
            90
        )
        XCTAssertEqual(
            UMICaptureOrientation.uprightRotationDegrees(
                forMetadataValue: "landscape_right"
            ),
            0
        )

        var intrinsics = matrix_identity_float3x3
        intrinsics.columns.0.x = 1_000
        intrinsics.columns.1.y = 800
        intrinsics.columns.2.x = 900
        intrinsics.columns.2.y = 600
        let preprocessing = UMIImagePreprocessing.fixed224(
            sourceWidth: 1_920,
            sourceHeight: 1_440,
            dataKey: "wrist_rgb",
            rotationDegrees: 90
        )
        let transformed = preprocessing.transformedIntrinsics(intrinsics)

        XCTAssertEqual(preprocessing.imageOrientation, .right)
        XCTAssertEqual(transformed[0][0], 0, accuracy: 0.001)
        XCTAssertEqual(transformed[0][1], -124.444_44, accuracy: 0.001)
        XCTAssertEqual(transformed[0][2], 129.666_67, accuracy: 0.001)
        XCTAssertEqual(transformed[1][0], 155.555_56, accuracy: 0.001)
        XCTAssertEqual(transformed[1][1], 0, accuracy: 0.001)
        XCTAssertEqual(transformed[1][2], 102.666_67, accuracy: 0.001)
    }

    func testGripperMarkerLayoutIsOnlyDeclaredForValidatedBundledHand() {
        let bundledHand = CaptureProfileSnapshot.make(
            deviceID: "hand",
            profileID: .handheldUMI,
            gripperID: "fastumi-iphone15pro-v1",
            calibrationID: "fastumi-iphone15pro-v1",
            lockedAtLocalMonotonicNs: 1
        )
        let unvalidatedHand = CaptureProfileSnapshot.make(
            deviceID: "hand",
            profileID: .handheldUMI,
            gripperID: "custom",
            calibrationID: nil,
            lockedAtLocalMonotonicNs: 1
        )
        let ego = CaptureProfileSnapshot.make(
            deviceID: "ego",
            profileID: .chestEGO,
            gripperID: "fastumi-iphone15pro-v1",
            calibrationID: "fastumi-iphone15pro-v1",
            lockedAtLocalMonotonicNs: 1
        )

        XCTAssertEqual(
            bundledHand.gripperMarkerLayout,
            "fastumi_aruco_mount"
        )
        XCTAssertNil(unvalidatedHand.gripperMarkerLayout)
        XCTAssertNil(ego.gripperMarkerLayout)
    }

    func testRecordingInfoDecodesOrientationAndGripperContract() throws {
        let object: [String: Any] = [
            "schema_version": 6,
            "recording_uuid": "recording",
            "width": 1920,
            "height": 1440,
            "nominal_fps": 60,
            "codec": "HEVC/H.265",
            "container": "MP4",
            "encoded_frame_count": 1,
            "dropped_frame_count": 0,
            "finish_reason": "stop",
            "umi_pixels_physically_upright": true,
            "raw_video_display_rotation_degrees": 180,
            "gripper_marker_layout": "fastumi_aruco_mount"
        ]
        let info = try JSONDecoder().decode(
            RGBRecordingInfo.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        XCTAssertEqual(info.umiPixelsPhysicallyUpright, true)
        XCTAssertEqual(info.rawVideoDisplayRotationDegrees, 180)
        XCTAssertEqual(info.gripperMarkerLayout, "fastumi_aruco_mount")
    }

    func testBundledFastUMIIdentityPresetIsExactAndHandOnly() throws {
        let preset = try XCTUnwrap(
            BundledFastUMIHardwareBinding.preset(for: .handheldUMI)
        )
        XCTAssertEqual(preset.gripperID, "fastumi-iphone15pro-v1")
        XCTAssertEqual(
            preset.calibrationID,
            "fastumi-iphone15pro-v1"
        )
        XCTAssertNil(
            BundledFastUMIHardwareBinding.preset(for: .chestEGO)
        )
    }

    func testValidatedHandProfileArchivesPhysicalTCPIdentityAndMatrix() throws {
        let profile = CaptureProfileSnapshot.make(
            deviceID: "hand",
            profileID: .handheldUMI,
            gripperID: "fastumi-iphone15pro-v1",
            calibrationID: "fastumi-iphone15pro-v1",
            lockedAtLocalMonotonicNs: 1
        )
        let physical = try XCTUnwrap(profile.physicalTCPProfile)
        XCTAssertEqual(physical.profileID, "fastumi-iphone15pro-v1")
        XCTAssertEqual(
            physical.transformConvention,
            "arkit_camera_T_fastumi_tcp"
        )
        XCTAssertEqual(physical.cameraToTCPRowMajor.count, 16)
        XCTAssertEqual(physical.cameraToTCPRowMajor[7], -0.06441, accuracy: 0.000_001)
        XCTAssertEqual(physical.cameraToTCPRowMajor[11], -0.211397, accuracy: 0.000_001)
    }

    func testSyncSetupMakesBundledHardwareBindingExplicit() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent(
                "UMICapture/ContentView.swift"
            ),
            encoding: .utf8
        )
        let managerSource = try String(
            contentsOf: root.appendingPathComponent(
                "UMICapture/ARSessionManager.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(
            source.contains(
                "Use bundled FastUMI × iPhUMI default"
            )
        )
        XCTAssertTrue(
            source.contains(
                "required for bundled default"
            )
        )
        XCTAssertTrue(
            source.contains(
                "Other hardware requires its own validated configuration and IDs."
            )
        )
        XCTAssertTrue(
            source.contains(
                "BundledFastUMIHardwareBinding.preset("
            )
        )
        XCTAssertFalse(
            managerSource.contains("fastumi-iphone15pro-v1")
        )
    }

    func testHandheldProfileFailsClosedUntilUltrawideIsObserved() {
        XCTAssertFalse(
            CaptureProfileID.handheldUMI.observationRequirementIsSatisfied(
                by: .checking
            )
        )
        XCTAssertTrue(
            CaptureProfileID.handheldUMI.observationRequirementIsSatisfied(
                by: .waitingForMetricPose(width: 640, height: 480)
            )
        )
    }

    func testOptionalMetadataRoundTripsWithoutChangingLegacyDefaults() throws {
        let coordination = ActiveCaptureCoordination(
            sessionID: "session",
            generation: 1,
            profile: CaptureProfileSnapshot.make(
                deviceID: "device",
                profileID: .handheldUMI,
                gripperID: nil,
                calibrationID: nil,
                lockedAtLocalMonotonicNs: 10
            ),
            clockMappingAtStart: nil,
            plannedStartCoordinatorNs: 20,
            actualStartLocalNs: 21,
            plannedStopCoordinatorNs: nil,
            actualStopLocalNs: nil,
            firstARFrameTimestampSeconds: 1.5,
            lastARFrameTimestampSeconds: 2.5
        )
        let data = try JSONEncoder().encode(coordination)
        XCTAssertEqual(
            try JSONDecoder().decode(ActiveCaptureCoordination.self, from: data),
            coordination
        )
    }

    func testTrajectoryArchiveEncodesProfileAndCoordinationMetadata() throws {
        let profile = CaptureProfileSnapshot.make(
            deviceID: "device",
            profileID: .handheldUMI,
            gripperID: "gripper",
            calibrationID: nil,
            lockedAtLocalMonotonicNs: 10
        )
        let coordination = ActiveCaptureCoordination(
            sessionID: "session",
            generation: 2,
            profile: profile,
            clockMappingAtStart: nil,
            plannedStartCoordinatorNs: 20,
            actualStartLocalNs: 21,
            plannedStopCoordinatorNs: 30,
            actualStopLocalNs: 31,
            firstARFrameTimestampSeconds: 1,
            lastARFrameTimestampSeconds: 2
        )
        let archive = TrajectoryArchive(
            recordingID: UUID(),
            startedAtUnixMs: 1_000,
            endedAtUnixMs: 2_000,
            samples: [
                TrajectoryPoseSample(
                    position: .zero,
                    cameraForward: SIMD3<Float>(0, 0, -1),
                    elapsedTimeSeconds: 0,
                    orientationXYZW: SIMD4<Float>(0, 0, 0, 1)
                )
            ],
            captureProfile: profile,
            captureCoordination: coordination
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(archive)
            ) as? [String: Any]
        )
        XCTAssertNotNil(object["capture_profile"])
        XCTAssertNotNil(object["capture_coordination"])
    }

    func testCalibratedHandTrajectoryUsesPhysicalTCPDisplayFrame() {
        let profile = CaptureProfileSnapshot.make(
            deviceID: "device",
            profileID: .handheldUMI,
            gripperID: "gripper",
            calibrationID: "15p",
            lockedAtLocalMonotonicNs: 10
        )
        let archive = TrajectoryArchive(
            recordingID: UUID(),
            startedAtUnixMs: 1_000,
            endedAtUnixMs: 2_000,
            samples: [
                TrajectoryPoseSample(
                    position: .zero,
                    cameraForward: SIMD3<Float>(1, 0, 0),
                    elapsedTimeSeconds: 0,
                    orientationXYZW: SIMD4<Float>(0, 0, 0, 1)
                )
            ],
            captureProfile: profile
        )

        XCTAssertEqual(
            archive.displayFrame,
            TrajectoryArchive.physicalTCPDisplayFrame
        )
    }

    func testOrdinaryCaptureDoesNotActivateAConfiguredSyncRole() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent(
                "UMICapture/ARSessionManager.swift"
            ),
            encoding: .utf8
        )
        let start = try XCTUnwrap(
            source.range(of: "    private func beginLogicalTrajectoryIfNeeded()")
        )
        let end = try XCTUnwrap(
            source.range(
                of: "    private func finalizeLogicalCapture(",
                range: start.upperBound..<source.endIndex
            )
        )
        let activation = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(
            activation.contains("if activeCaptureCoordination != nil")
        )
        XCTAssertTrue(activation.contains("lockedCaptureProfile = nil"))
        XCTAssertTrue(activation.contains("captureRoleLocked = false"))
        XCTAssertTrue(
            source.contains(
                "captureProfile: profileSnapshot"
            )
        )
    }

    func testHandVisualizationKeepsArchivedCameraPoseDeviceLocal() {
        let source = [
            TrajectoryPoseSample(
                position: .zero,
                cameraForward: SIMD3<Float>(0, 0, -1),
                elapsedTimeSeconds: 0,
                orientationXYZW: SIMD4<Float>(0, 0, 0, 1)
            ),
            TrajectoryPoseSample(
                position: SIMD3<Float>(1, -2, 3),
                cameraForward: SIMD3<Float>(0, 0, -1),
                elapsedTimeSeconds: 1,
                orientationXYZW: SIMD4<Float>(0, 0, 0, 1)
            )
        ]

        let displayed = TrajectoryVisualizationPolicy.samples(
            from: source,
            displayFrame: TrajectoryArchive.robotDisplayFrame,
            captureRole: .wristUMI,
            calibrationID: "15p"
        )

        XCTAssertEqual(source[1].position, SIMD3<Float>(1, -2, 3))
        XCTAssertEqual(displayed.count, 2)
        XCTAssertEqual(displayed[0].position, .zero)
        XCTAssertEqual(displayed[1].position.x, 1, accuracy: 0.000_001)
        XCTAssertEqual(displayed[1].position.y, 2, accuracy: 0.000_001)
        XCTAssertEqual(displayed[1].position.z, 3, accuracy: 0.000_001)
        XCTAssertNotNil(displayed[1].orientationXYZW)
    }
}
