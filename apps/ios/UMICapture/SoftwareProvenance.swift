import Foundation

struct SoftwareProvenance: Codable, Equatable {
    static let currentSchemaVersion = 2
    static let productName = "UMI Capture"
    static let developerName = "Xinrui Xiong"
    static let inspirationProjects = [
        "Universal Manipulation Interface",
        "UMI on Legs",
        "iPhUMI",
        "iPhoneVIO"
    ]
    static let feedbackAddress = "https://github.com/xx3-bot/umi-capture/issues"
    static let aboutDescription =
        "UMI Capture is an independently implemented ARKit-based capture and processing tool inspired by prior open-source robot-learning interfaces."

    let schemaVersion: Int
    let appName: String
    let marketingVersion: String
    let buildNumber: String
    let bundleIdentifier: String
    let developer: String
    let acknowledgements: [String]

    static func current(bundle: Bundle = .main) -> SoftwareProvenance {
        SoftwareProvenance(
            schemaVersion: currentSchemaVersion,
            appName: productName,
            marketingVersion: bundle.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String ?? "unknown",
            buildNumber: bundle.object(
                forInfoDictionaryKey: "CFBundleVersion"
            ) as? String ?? "unknown",
            bundleIdentifier: bundle.bundleIdentifier
                ?? "com.example.UMICapture",
            developer: developerName,
            acknowledgements: inspirationProjects
        )
    }

    var clientMetadata: [String: Any] {
        [
            "schema_version": schemaVersion,
            "app_name": appName,
            "marketing_version": marketingVersion,
            "build_number": buildNumber,
            "bundle_identifier": bundleIdentifier
        ]
    }

    var attributionLines: [String] {
        [
            SoftwareProvenance.aboutDescription,
            "Developer: \(developer)",
            "Inspired by: \(acknowledgements.joined(separator: ", "))",
            "Feedback/debug: \(SoftwareProvenance.feedbackAddress)"
        ]
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case appName = "app_name"
        case marketingVersion = "marketing_version"
        case buildNumber = "build_number"
        case bundleIdentifier = "bundle_identifier"
        case developer
        case acknowledgements
    }
}
