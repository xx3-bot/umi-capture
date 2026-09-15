import CoreGraphics
import Foundation
import ImageIO
import simd

struct CameraCalibrationProfile: Codable, Equatable {
    let profileID: String
    let iPhoneModel: String
    let lensMode: RGBCameraMode
    let physicalCameraType: String
    let width: Int
    let height: Int
    let cameraModel: String
    let K: [[Double]]
    let D: [Double]
    let parameterSource: String
    let approximate: Bool

    enum CodingKeys: String, CodingKey {
        case profileID = "profile_id"
        case iPhoneModel = "iphone_model"
        case lensMode = "lens_mode"
        case physicalCameraType = "physical_camera_type"
        case width
        case height
        case cameraModel = "camera_model"
        case K
        case D
        case parameterSource = "parameter_source"
        case approximate
    }
}

enum CameraCalibrationRegistry {
    static func profile(
        iPhoneModel: String,
        lensMode: RGBCameraMode,
        width: Int,
        height: Int
    ) -> CameraCalibrationProfile {
        let referenceWidth = 1_920.0
        let referenceHeight = 1_440.0
        let reference = referenceParameters(
            iPhoneModel: iPhoneModel,
            lensMode: lensMode
        )
        let fx = reference.fx
            * Double(width) / referenceWidth
        let fy = reference.fy
            * Double(height) / referenceHeight
        let cx = reference.cx
            * Double(width) / referenceWidth
        let cy = reference.cy
            * Double(height) / referenceHeight
        let profileID = [
            iPhoneModel,
            lensMode.rawValue,
            "\(width)x\(height)",
            "approx-v1"
        ].joined(separator: "_")

        return CameraCalibrationProfile(
            profileID: profileID,
            iPhoneModel: iPhoneModel,
            lensMode: lensMode,
            physicalCameraType:
                lensMode.physicalCameraLabel,
            width: width,
            height: height,
            cameraModel: "pinhole-radtan",
            K: [
                [fx, 0, cx],
                [0, fy, cy],
                [0, 0, 1]
            ],
            D: [0, 0, 0, 0, 0],
            parameterSource: reference.source,
            approximate: true
        )
    }

    private static func referenceParameters(
        iPhoneModel: String,
        lensMode: RGBCameraMode
    ) -> (
        fx: Double,
        fy: Double,
        cx: Double,
        cy: Double,
        source: String
    ) {
        if iPhoneModel == "iPhone16,1",
           lensMode == .wide1x {
            return (
                fx: 1_349.8192,
                fy: 1_349.8192,
                cx: 959.23083,
                cy: 719.29706,
                source:
                    "Experimental public approximation for "
                    + "iPhone16,1 1x at 1920x1440. "
                    + "D is initialized to zero because ARKit does "
                    + "not expose distortion coefficients. This is "
                    + "an approximate engineering prior, not a "
                    + "laboratory lens calibration."
            )
        }

        let focalLength: Double
        let availabilityNote: String
        switch lensMode {
        case .wide1x:
            focalLength = 1_330
            availabilityNote =
                "No device-specific observed K is registered."
        case .ultraWide05x:
            focalLength = 720
            availabilityNote =
                iPhoneModel == "iPhone16,1"
                ? "ARKit exposed no builtInUltraWideCamera "
                    + "world-tracking format on the tested device."
                : "No device-specific observed K is registered."
        }
        return (
            fx: focalLength,
            fy: focalLength,
            cx: 960,
            cy: 720,
            source:
                "Project approximate field-of-view prior for the "
                + "\(lensMode.shortLabel) physical lens. "
                + availabilityNote
                + " D is initialized to zero because ARKit does not "
                + "expose distortion coefficients. Verify with "
                + "laboratory lens calibration and per-frame ARKit K "
                + "before metric use."
        )
    }
}

struct UMIImagePreprocessing: Codable, Equatable {
    let dataKey: String
    let sourceWidth: Int
    let sourceHeight: Int
    let cropX: Int
    let cropY: Int
    let cropWidth: Int
    let cropHeight: Int
    let outputWidth: Int
    let outputHeight: Int
    let rotationDegrees: Int
    let interpolation: String

    enum CodingKeys: String, CodingKey {
        case dataKey = "data_key"
        case sourceWidth = "source_width"
        case sourceHeight = "source_height"
        case cropX = "crop_x"
        case cropY = "crop_y"
        case cropWidth = "crop_width"
        case cropHeight = "crop_height"
        case outputWidth = "output_width"
        case outputHeight = "output_height"
        case rotationDegrees = "rotation_degrees"
        case interpolation
    }

    static func fixed224(
        sourceWidth: Int,
        sourceHeight: Int,
        dataKey: String,
        rotationDegrees: Int = 0
    ) -> UMIImagePreprocessing {
        precondition(
            [0, 90, 180, 270].contains(rotationDegrees),
            "UMI rotation must be a clockwise quarter turn"
        )
        let cropSize = min(sourceWidth, sourceHeight)
        return UMIImagePreprocessing(
            dataKey: dataKey,
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            cropX: (sourceWidth - cropSize) / 2,
            cropY: (sourceHeight - cropSize) / 2,
            cropWidth: cropSize,
            cropHeight: cropSize,
            outputWidth: 224,
            outputHeight: 224,
            rotationDegrees: rotationDegrees,
            interpolation:
                "CoreImage fixed center-crop, bilinear scale, and orientation normalization"
        )
    }

    var imageOrientation: CGImagePropertyOrientation {
        switch rotationDegrees {
        case 0: return .up
        case 90: return .right
        case 180: return .down
        case 270: return .left
        default:
            preconditionFailure("Unsupported UMI rotation")
        }
    }

    var rawVideoTrackTransform: CGAffineTransform {
        CGAffineTransform(
            rotationAngle: CGFloat(rotationDegrees) * .pi / 180
        )
    }

    func transformedIntrinsics(
        _ intrinsics: simd_float3x3
    ) -> [[Float]] {
        let scaleX = Float(outputWidth) / Float(cropWidth)
        let scaleY = Float(outputHeight) / Float(cropHeight)
        let fx = intrinsics.columns.0.x * scaleX
        let fy = intrinsics.columns.1.y * scaleY
        let cx = (
            intrinsics.columns.2.x - Float(cropX)
        ) * scaleX
        let cy = (
            intrinsics.columns.2.y - Float(cropY)
        ) * scaleY
        switch rotationDegrees {
        case 0:
            return [
                [fx, 0, cx],
                [0, fy, cy],
                [0, 0, 1]
            ]
        case 90:
            return [
                [0, -fy, Float(outputHeight - 1) - cy],
                [fx, 0, cx],
                [0, 0, 1]
            ]
        case 180:
            return [
                [-fx, 0, Float(outputWidth - 1) - cx],
                [0, -fy, Float(outputHeight - 1) - cy],
                [0, 0, 1]
            ]
        case 270:
            return [
                [0, fy, cy],
                [-fx, 0, Float(outputWidth - 1) - cx],
                [0, 0, 1]
            ]
        default:
            preconditionFailure("Unsupported UMI rotation")
        }
    }
}
