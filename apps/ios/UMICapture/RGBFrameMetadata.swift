import CoreVideo
import Foundation
import simd

struct RGBFrameMetadata: Codable, Equatable {
    let schemaVersion: Int
    let frameIndex: Int
    let dataKey: String
    let lensMode: RGBCameraMode
    let physicalCameraType: String
    let width: Int
    let height: Int
    let arkitTimestampSeconds: Double
    let mp4PresentationTimeSeconds: Double
    let arkitCameraIntrinsics: [[Float]]
    let umi224CameraIntrinsics: [[Float]]
    let empiricalCalibrationProfileID: String
    let empiricalCalibration: CameraCalibrationProfile
    let cameraPose: [[Float]]
    let trackingState: String
    let interfaceOrientation: String
    let encoded: Bool
    let umi224Encoded: Bool
    let dropReason: String?

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case frameIndex = "frame_index"
        case dataKey = "data_key"
        case lensMode = "lens_mode"
        case physicalCameraType = "physical_camera_type"
        case width
        case height
        case arkitTimestampSeconds = "arkit_timestamp_s"
        case mp4PresentationTimeSeconds = "mp4_pts_s"
        case arkitCameraIntrinsics =
            "arkit_camera_intrinsics"
        case umi224CameraIntrinsics =
            "umi_224_camera_intrinsics"
        case empiricalCalibrationProfileID =
            "empirical_calibration_profile_id"
        case empiricalCalibration =
            "empirical_calibration"
        case cameraPose = "camera_pose"
        case trackingState = "tracking_state"
        case interfaceOrientation = "interface_orientation"
        case encoded
        case umi224Encoded = "umi_224_encoded"
        case dropReason = "drop_reason"
    }
}

struct RGBFrameDescriptor {
    let timestamp: TimeInterval
    let intrinsics: simd_float3x3
    let cameraPose: simd_float4x4
    let trackingState: String
    let interfaceOrientation: String
}

struct RGBFrameInput {
    let pixelBuffer: CVPixelBuffer?
    let descriptor: RGBFrameDescriptor
    let ultrawideFrame: UltrawideRecordingFrame?
}
