import ARKit
import CoreVideo
import ObjectiveC.runtime

enum ARFrameUltrawideReadResult {
    case privateAPIUnavailable
    case invalid
    case observation(ARFrameUltrawideObservation)
}

struct ARFrameUltrawideObservation {
    let pixelBuffer: CVPixelBuffer
    let sample: UltrawideObservationSample
}

final class ARFrameUltrawideObservationSource {
    static let capturedImageIvarName = "_capturedUltraWideImage"
    static let timestampIvarName = "_ultraWideImageTimestamp"
    static let cameraIvarName = "_ultraWideCamera"

    private let capturedImageIvar: Ivar?
    private let timestampIvar: Ivar?
    private let cameraIvar: Ivar?

    init() {
        capturedImageIvar = class_getInstanceVariable(
            ARFrame.self,
            Self.capturedImageIvarName
        )
        timestampIvar = class_getInstanceVariable(
            ARFrame.self,
            Self.timestampIvarName
        )
        cameraIvar = class_getInstanceVariable(
            ARFrame.self,
            Self.cameraIvarName
        )
    }

    var hasRequiredPrivateFields: Bool {
        capturedImageIvar != nil
            && timestampIvar != nil
            && cameraIvar != nil
    }

    func read(frame: ARFrame) -> ARFrameUltrawideReadResult {
        guard let capturedImageIvar,
              let timestampIvar,
              let cameraIvar else {
            return .privateAPIUnavailable
        }
        let objectPointer = UnsafeRawPointer(
            Unmanaged.passUnretained(frame).toOpaque()
        )
        let pixelBuffer = objectPointer
            .advanced(by: ivar_getOffset(capturedImageIvar))
            .load(as: CVPixelBuffer?.self)
        let timestamp = objectPointer
            .advanced(by: ivar_getOffset(timestampIvar))
            .load(as: Double?.self)
        let camera = objectPointer
            .advanced(by: ivar_getOffset(cameraIvar))
            .load(as: ARCamera?.self)

        guard let pixelBuffer,
              let timestamp,
              let camera else {
            return .invalid
        }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0,
              height > 0,
              Int(camera.imageResolution.width.rounded()) == width,
              Int(camera.imageResolution.height.rounded()) == height else {
            return .invalid
        }
        return .observation(
            ARFrameUltrawideObservation(
                pixelBuffer: pixelBuffer,
                sample: UltrawideObservationSample(
                timestamp: timestamp,
                width: width,
                height: height,
                intrinsics: camera.intrinsics,
                worldTransform: camera.transform
                )
            )
        )
    }
}
