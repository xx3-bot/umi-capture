import AVFoundation
import ImageIO
import simd
import UIKit

enum RGBCameraMode: String, Codable, CaseIterable, Identifiable {
    case wide1x = "1x_wide"
    case ultraWide05x = "0.5x_ultra_wide"

    var id: String {
        rawValue
    }

    var shortLabel: String {
        switch self {
        case .wide1x:
            return "1×"
        case .ultraWide05x:
            return "0.5×"
        }
    }

    var physicalCameraLabel: String {
        switch self {
        case .wide1x:
            return "builtInWideAngleCamera"
        case .ultraWide05x:
            return "builtInUltraWideCamera"
        }
    }

    var captureDeviceType: AVCaptureDevice.DeviceType {
        switch self {
        case .wide1x:
            return .builtInWideAngleCamera
        case .ultraWide05x:
            return .builtInUltraWideCamera
        }
    }
}

enum UMICaptureOrientation {
    static func captureOrientation(
        from deviceOrientation: UIDeviceOrientation
    ) -> UIInterfaceOrientation {
        switch deviceOrientation {
        case .portrait:
            return .portrait
        case .portraitUpsideDown:
            return .portraitUpsideDown
        case .landscapeLeft:
            // Device rotation and interface rotation use opposite names.
            return .landscapeRight
        case .landscapeRight:
            return .landscapeLeft
        case .faceUp, .faceDown, .unknown:
            return .unknown
        @unknown default:
            return .unknown
        }
    }

    static func metadataValue(
        for orientation: UIInterfaceOrientation
    ) -> String {
        switch orientation {
        case .portrait:
            return "portrait"
        case .portraitUpsideDown:
            return "portrait_upside_down"
        case .landscapeLeft:
            return "landscape_left"
        case .landscapeRight:
            return "landscape_right"
        case .unknown:
            return "unknown"
        @unknown default:
            return "unknown"
        }
    }

    static func isValid(
        _ orientation: UIInterfaceOrientation
    ) -> Bool {
        orientation == .portrait
            || orientation == .landscapeLeft
            || orientation == .landscapeRight
    }

    static func resolvedInterfaceOrientation(
        deviceOrientation: UIInterfaceOrientation,
        sceneOrientation: UIInterfaceOrientation?,
        lockedOrientation: UIInterfaceOrientation?
    ) -> UIInterfaceOrientation {
        if let lockedOrientation,
           isValid(lockedOrientation) {
            return lockedOrientation
        }
        if isValid(deviceOrientation) {
            return deviceOrientation
        }
        if let sceneOrientation,
           isValid(sceneOrientation) {
            return sceneOrientation
        }
        return .unknown
    }

    static func interfaceOrientationMask(
        for orientation: UIInterfaceOrientation
    ) -> UIInterfaceOrientationMask? {
        switch orientation {
        case .portrait:
            return .portrait
        case .landscapeLeft:
            return .landscapeLeft
        case .landscapeRight:
            return .landscapeRight
        case .portraitUpsideDown, .unknown:
            return nil
        @unknown default:
            return nil
        }
    }

    static func uprightRotationDegrees(
        for orientation: UIInterfaceOrientation
    ) -> Int? {
        switch orientation {
        case .landscapeLeft:
            return 180
        case .portrait:
            return 90
        case .landscapeRight:
            return 0
        case .portraitUpsideDown, .unknown:
            return nil
        @unknown default:
            return nil
        }
    }

    static func uprightRotationDegrees(
        forMetadataValue value: String
    ) -> Int? {
        switch value {
        case "landscape_left": return 180
        case "portrait": return 90
        case "landscape_right": return 0
        default: return nil
        }
    }

    static func uprightImageOrientation(
        for orientation: UIInterfaceOrientation
    ) -> CGImagePropertyOrientation? {
        guard let degrees = uprightRotationDegrees(for: orientation) else {
            return nil
        }
        switch degrees {
        case 0:
            return .up
        case 90:
            return .right
        case 180:
            return .down
        case 270:
            return .left
        default:
            return nil
        }
    }
}

enum CaptureOrientationPolicy {
    static let maximumTiltChangeDegrees: Double = 45

    static func isCompatible(
        lockedOrientation: UIInterfaceOrientation?,
        currentOrientation: UIInterfaceOrientation
    ) -> Bool {
        guard UMICaptureOrientation.isValid(currentOrientation) else {
            return false
        }
        guard let lockedOrientation else {
            return true
        }
        return lockedOrientation == currentOrientation
    }

    static func tiltChangeDegrees(
        referenceTransform: simd_float4x4,
        currentTransform: simd_float4x4
    ) -> Double {
        let referenceGravity =
            gravityDirectionInCamera(referenceTransform)
        let currentGravity =
            gravityDirectionInCamera(currentTransform)
        let clampedDot = min(
            1,
            max(
                -1,
                Double(
                    simd_dot(
                        referenceGravity,
                        currentGravity
                    )
                )
            )
        )
        return acos(clampedDot) * 180 / .pi
    }

    static func exceedsTiltLimit(
        referenceTransform: simd_float4x4,
        currentTransform: simd_float4x4
    ) -> Bool {
        tiltChangeDegrees(
            referenceTransform: referenceTransform,
            currentTransform: currentTransform
        ) > maximumTiltChangeDegrees
    }

    private static func gravityDirectionInCamera(
        _ transform: simd_float4x4
    ) -> SIMD3<Float> {
        let gravity = SIMD3<Float>(
            transform.columns.0.y,
            transform.columns.1.y,
            transform.columns.2.y
        )
        let length = simd_length(gravity)
        guard length > 0.000_1 else {
            return SIMD3<Float>(0, 1, 0)
        }
        return gravity / length
    }
}

enum CaptureConfigurationPolicy {
    static func canSwitchCamera(
        isCalibrating: Bool,
        isStarting: Bool,
        isStreaming: Bool,
        isCalibrationReady: Bool,
        isFinalizing: Bool,
        hasLogicalCapture: Bool,
        recorderPhase: RGBRecorderPhase
    ) -> Bool {
        !isCalibrating
            && !isStarting
            && !isStreaming
            && !isCalibrationReady
            && !isFinalizing
            && !hasLogicalCapture
            && recorderPhase != .recording
            && recorderPhase != .finishing
    }
}

enum DeviceModelIdentifier {
    static var current: String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let mirror = Mirror(
            reflecting: systemInfo.machine
        )
        return mirror.children.reduce(into: "") {
            identifier,
            element in
            guard let value = element.value as? Int8,
                  value != 0
            else {
                return
            }
            identifier.append(
                Character(
                    UnicodeScalar(UInt8(value))
                )
            )
        }
    }
}
