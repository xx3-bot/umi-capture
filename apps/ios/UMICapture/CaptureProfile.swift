import Foundation
import simd

struct PhysicalTCPProfile: Equatable {
    static let transformConvention = "arkit_camera_T_fastumi_tcp"

    let identifier: String
    let cameraToTCP: simd_float4x4

    var cameraToTCPRowMajor: [Float] {
        (0..<4).flatMap { row in
            (0..<4).map { column in
                cameraToTCP[column][row]
            }
        }
    }

    static let fastUMIIPhone = PhysicalTCPProfile(
        identifier: "fastumi-iphone15pro-v1",
        cameraToTCP: simd_float4x4(
            SIMD4<Float>(1, 0, 0, 0),
            SIMD4<Float>(0, -0.9659258, -0.25881904, 0),
            SIMD4<Float>(0, 0.25881904, -0.9659258, 0),
            SIMD4<Float>(0, -0.06441, -0.211397, 1)
        )
    )

    static func resolve(calibrationID: String?) -> PhysicalTCPProfile? {
        guard let normalized = calibrationID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
              [
                "15p",
                "fastumi-iphone15pro-v1",
                "fastumi-iphone15pro-wide-v1",
                "fastumi-iphone15pro-narrow-v1"
              ].contains(normalized)
        else { return nil }
        return .fastUMIIPhone
    }
}

struct PhysicalTCPProfileBinding: Codable, Equatable {
    let profileID: String
    let transformConvention: String
    let cameraToTCPRowMajor: [Float]

    init(profile: PhysicalTCPProfile) {
        profileID = profile.identifier
        transformConvention = PhysicalTCPProfile.transformConvention
        cameraToTCPRowMajor = profile.cameraToTCPRowMajor
    }

    enum CodingKeys: String, CodingKey {
        case profileID = "profile_id"
        case transformConvention = "transform_convention"
        case cameraToTCPRowMajor = "camera_T_tcp_row_major"
    }
}

enum CaptureRole: String, Codable, CaseIterable, Identifiable {
    case wristUMI = "wrist_umi"
    case ego = "ego"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .wristUMI:
            return "Handheld UMI"
        case .ego:
            return "Chest EGO"
        }
    }
}

enum CaptureProfileID: String, Codable, CaseIterable, Identifiable {
    case handheldUMI = "handheld_umi"
    case chestEGO = "chest_ego"

    var id: String { rawValue }

    var role: CaptureRole {
        switch self {
        case .handheldUMI:
            return .wristUMI
        case .chestEGO:
            return .ego
        }
    }

    var displayName: String {
        role.displayName
    }

    var requiresUltrawideObservation: Bool {
        self == .handheldUMI
    }

    /// Wrist-mounted UMI capture follows the gripper through its full
    /// workspace. Large pitch and roll changes are expected after the start
    /// boundary, so they must not interrupt an active capture. Initial
    /// calibration and Start still use the common tilt prerequisite.
    var enforcesRuntimeTiltLimit: Bool {
        self != .handheldUMI
    }

    /// Encoded video and pose metadata use the capture-start interface
    /// orientation. Both roles keep that interface orientation fixed while a
    /// capture is active; physical tool motion remains unrestricted.
    var enforcesRuntimeInterfaceOrientationLock: Bool {
        true
    }

    func observationRequirementIsSatisfied(
        by status: UltrawideObservationStatus
    ) -> Bool {
        guard requiresUltrawideObservation else { return true }
        switch status {
        case .waitingForMetricPose, .available:
            return true
        case .checking, .privateAPIUnavailable, .invalid:
            return false
        }
    }
}

enum CaptureCalibrationKind: String, Codable {
    case cameraToTCP = "camera_T_tcp"
    case cameraToBody = "camera_T_body"
}

enum CaptureCalibrationStatus: String, Codable {
    case calibrated
    case uncalibrated
}

struct CaptureCalibrationBinding: Codable, Equatable {
    let kind: CaptureCalibrationKind
    let calibrationID: String?
    let status: CaptureCalibrationStatus

    init(kind: CaptureCalibrationKind, calibrationID: String?) {
        self.kind = kind
        let normalized = calibrationID?.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        if let normalized, !normalized.isEmpty {
            self.calibrationID = normalized
            status = .calibrated
        } else {
            self.calibrationID = nil
            status = .uncalibrated
        }
    }

    enum CodingKeys: String, CodingKey {
        case kind
        case calibrationID = "calibration_id"
        case status
    }
}

struct CaptureProfileSnapshot: Codable, Equatable {
    let deviceID: String
    let profileID: CaptureProfileID
    let captureRole: CaptureRole
    let gripperID: String?
    let calibration: CaptureCalibrationBinding
    let physicalTCPProfile: PhysicalTCPProfileBinding?
    let lockedAtLocalMonotonicNs: UInt64

    var gripperMarkerLayout: String? {
        guard captureRole == .wristUMI,
              gripperID == BundledFastUMIHardwareBinding.identifier,
              physicalTCPProfile?.profileID
                == BundledFastUMIHardwareBinding.identifier
        else { return nil }
        return "fastumi_aruco_mount"
    }

    static func make(
        deviceID: String,
        profileID: CaptureProfileID,
        gripperID: String?,
        calibrationID: String?,
        lockedAtLocalMonotonicNs: UInt64
    ) -> CaptureProfileSnapshot {
        let normalizedGripper = gripperID?.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        switch profileID {
        case .handheldUMI:
            return CaptureProfileSnapshot(
                deviceID: deviceID,
                profileID: profileID,
                captureRole: .wristUMI,
                gripperID: normalizedGripper?.isEmpty == false
                    ? normalizedGripper
                    : nil,
                calibration: CaptureCalibrationBinding(
                    kind: .cameraToTCP,
                    calibrationID: calibrationID
                ),
                physicalTCPProfile: PhysicalTCPProfile
                    .resolve(calibrationID: calibrationID)
                    .map { PhysicalTCPProfileBinding(profile: $0) },
                lockedAtLocalMonotonicNs: lockedAtLocalMonotonicNs
            )
        case .chestEGO:
            return CaptureProfileSnapshot(
                deviceID: deviceID,
                profileID: profileID,
                captureRole: .ego,
                gripperID: nil,
                calibration: CaptureCalibrationBinding(
                    kind: .cameraToBody,
                    calibrationID: calibrationID
                ),
                physicalTCPProfile: nil,
                lockedAtLocalMonotonicNs: lockedAtLocalMonotonicNs
            )
        }
    }

    enum CodingKeys: String, CodingKey {
        case deviceID = "device_id"
        case profileID = "profile_id"
        case captureRole = "capture_role"
        case gripperID = "gripper_id"
        case calibration
        case physicalTCPProfile = "physical_tcp_profile"
        case lockedAtLocalMonotonicNs = "locked_at_local_monotonic_ns"
    }
}

enum CaptureDataKey {
    static func main(
        for captureProfile: CaptureProfileSnapshot?
    ) -> String {
        captureProfile?.captureRole == .wristUMI
            ? "wrist_rgb"
            : "ego_rgb"
    }

    static func ultrawide(
        for captureProfile: CaptureProfileSnapshot?
    ) -> String {
        captureProfile?.captureRole == .wristUMI
            ? "wrist_rgb_ultrawide"
            : "ego_rgb_ultrawide"
    }
}

struct CaptureIdentityPreset: Equatable {
    let gripperID: String
    let calibrationID: String
}

enum BundledFastUMIHardwareBinding {
    static let identifier = "fastumi-iphone15pro-v1"

    static func preset(
        for profileID: CaptureProfileID
    ) -> CaptureIdentityPreset? {
        guard profileID == .handheldUMI else { return nil }
        return CaptureIdentityPreset(
            gripperID: identifier,
            calibrationID: identifier
        )
    }
}
