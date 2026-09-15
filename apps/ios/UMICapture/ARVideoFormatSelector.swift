import ARKit
import AVFoundation
import Foundation

struct SelectedARVideoFormat {
    let format: ARConfiguration.VideoFormat
    let width: Int
    let height: Int
    let framesPerSecond: Int
    let cameraMode: RGBCameraMode
    let physicalCameraType: String

    var displayDescription: String {
        "\(cameraMode.shortLabel) · "
            + "\(width) × \(height) @ \(framesPerSecond) FPS"
    }
}

struct ARVideoFormatCandidate: Equatable {
    let width: Int
    let height: Int
    let framesPerSecond: Int
    let physicalCameraType: String
}

enum ARVideoFormatSelectionError: LocalizedError {
    case noFormatsForPhysicalCamera(
        camera: String,
        allSupportedFormats: String
    )
    case noSupportedFourByThree60FPS(
        camera: String,
        supportedFormats: String
    )

    var errorDescription: String? {
        switch self {
        case .noFormatsForPhysicalCamera(
            let camera,
            let allSupportedFormats
        ):
            return """
            ARKit reports no formats for \(camera). The app will not \
            fall back to another physical lens. All reported formats: \
            \(allSupportedFormats)
            """
        case .noSupportedFourByThree60FPS(
            let camera,
            let supportedFormats
        ):
            return """
            \(camera) has no 4:3 60 FPS ARKit format. The app will not \
            switch lenses or use 30 FPS. Formats for this lens: \
            \(supportedFormats)
            """
        }
    }
}

enum ARVideoFormatSelector {
    static func select(
        from formats: [ARConfiguration.VideoFormat],
        cameraMode: RGBCameraMode
    ) throws -> SelectedARVideoFormat {
        let lensFormats = formats.filter {
            $0.captureDeviceType
                == cameraMode.captureDeviceType
        }
        guard !lensFormats.isEmpty else {
            throw ARVideoFormatSelectionError
                .noFormatsForPhysicalCamera(
                    camera: cameraMode.physicalCameraLabel,
                    allSupportedFormats:
                        supportedFormatsDescription(formats)
                )
        }

        let candidates = lensFormats.map(candidate)
        let selectedCandidate = try selectCandidate(
            from: candidates,
            cameraMode: cameraMode
        )
        guard let selectedIndex = candidates.firstIndex(
            of: selectedCandidate
        ) else {
            throw ARVideoFormatSelectionError
                .noSupportedFourByThree60FPS(
                    camera: cameraMode.physicalCameraLabel,
                    supportedFormats:
                        supportedFormatsDescription(lensFormats)
                )
        }
        return selection(
            from: lensFormats[selectedIndex],
            cameraMode: cameraMode
        )
    }

    static func selectCandidate(
        from candidates: [ARVideoFormatCandidate],
        cameraMode: RGBCameraMode
    ) throws -> ARVideoFormatCandidate {
        let physicalCameraType =
            cameraMode.captureDeviceType.rawValue
        let lensCandidates = candidates.filter {
            $0.physicalCameraType == physicalCameraType
                || $0.physicalCameraType
                    == cameraMode.physicalCameraLabel
        }
        guard !lensCandidates.isEmpty else {
            throw ARVideoFormatSelectionError
                .noFormatsForPhysicalCamera(
                    camera: cameraMode.physicalCameraLabel,
                    allSupportedFormats:
                        candidateDescriptions(candidates)
                )
        }

        let valid = lensCandidates.filter {
            $0.framesPerSecond == 60
                && isFourByThree(
                    width: $0.width,
                    height: $0.height
                )
        }

        if let preferred = valid.first(where: {
            $0.width == 1_920 && $0.height == 1_440
        }) {
            return preferred
        }

        if let highest = valid.max(by: {
            $0.width * $0.height < $1.width * $1.height
        }) {
            return highest
        }

        throw ARVideoFormatSelectionError
            .noSupportedFourByThree60FPS(
                camera: cameraMode.physicalCameraLabel,
                supportedFormats:
                    candidateDescriptions(lensCandidates)
            )
    }

    static func supportedFormatsDescription(
        _ formats: [ARConfiguration.VideoFormat]
    ) -> String {
        guard !formats.isEmpty else {
            return "none"
        }

        let descriptions = Set(
            formats.map {
                "\($0.captureDeviceType.rawValue):"
                    + "\(Int($0.imageResolution.width))×"
                    + "\(Int($0.imageResolution.height))@"
                    + "\($0.framesPerSecond)"
            }
        )
        return descriptions.sorted().joined(separator: ", ")
    }

    private static func selection(
        from format: ARConfiguration.VideoFormat,
        cameraMode: RGBCameraMode
    ) -> SelectedARVideoFormat {
        SelectedARVideoFormat(
            format: format,
            width: Int(format.imageResolution.width),
            height: Int(format.imageResolution.height),
            framesPerSecond: format.framesPerSecond,
            cameraMode: cameraMode,
            physicalCameraType:
                cameraMode.physicalCameraLabel
        )
    }

    private static func candidate(
        _ format: ARConfiguration.VideoFormat
    ) -> ARVideoFormatCandidate {
        ARVideoFormatCandidate(
            width: Int(format.imageResolution.width),
            height: Int(format.imageResolution.height),
            framesPerSecond: format.framesPerSecond,
            physicalCameraType:
                format.captureDeviceType.rawValue
        )
    }

    private static func candidateDescriptions(
        _ candidates: [ARVideoFormatCandidate]
    ) -> String {
        guard !candidates.isEmpty else {
            return "none"
        }
        return Set(
            candidates.map {
                "\($0.physicalCameraType):"
                    + "\($0.width)×\($0.height)@"
                    + "\($0.framesPerSecond)"
            }
        )
        .sorted()
        .joined(separator: ", ")
    }

    private static func isFourByThree(
        _ resolution: CGSize
    ) -> Bool {
        guard resolution.height > 0 else {
            return false
        }
        let aspectRatio = resolution.width / resolution.height
        return abs(aspectRatio - (4.0 / 3.0)) < 0.01
    }

    private static func isFourByThree(
        width: Int,
        height: Int
    ) -> Bool {
        guard height > 0 else {
            return false
        }
        return abs(
            Double(width) / Double(height) - (4.0 / 3.0)
        ) < 0.01
    }
}
