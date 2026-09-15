import Foundation
import simd

struct TrajectoryPoseSample: Equatable {
    let position: SIMD3<Float>
    let cameraForward: SIMD3<Float>
    let elapsedTimeSeconds: TimeInterval?
    let orientationXYZW: SIMD4<Float>?

    init(
        position: SIMD3<Float>,
        cameraForward: SIMD3<Float>,
        elapsedTimeSeconds: TimeInterval? = nil,
        orientationXYZW: SIMD4<Float>? = nil
    ) {
        self.position = position
        self.cameraForward = cameraForward
        self.elapsedTimeSeconds = elapsedTimeSeconds
        self.orientationXYZW = orientationXYZW
    }
}

struct TrajectoryArchiveSample: Codable, Equatable {
    let position: [Float]
    let cameraForward: [Float]
    let elapsedTimeSeconds: TimeInterval?
    let orientationXYZW: [Float]?

    init(_ sample: TrajectoryPoseSample) {
        position = [
            sample.position.x,
            sample.position.y,
            sample.position.z
        ]
        cameraForward = [
            sample.cameraForward.x,
            sample.cameraForward.y,
            sample.cameraForward.z
        ]
        elapsedTimeSeconds = sample.elapsedTimeSeconds
        if let orientation = sample.orientationXYZW {
            orientationXYZW = [
                orientation.x,
                orientation.y,
                orientation.z,
                orientation.w
            ]
        } else {
            orientationXYZW = nil
        }
    }

    var poseSample: TrajectoryPoseSample? {
        guard position.count == 3, cameraForward.count == 3 else {
            return nil
        }
        let decodedOrientation: SIMD4<Float>?
        if let orientationXYZW {
            guard orientationXYZW.count == 4 else {
                return nil
            }
            decodedOrientation = SIMD4<Float>(
                orientationXYZW[0],
                orientationXYZW[1],
                orientationXYZW[2],
                orientationXYZW[3]
            )
        } else {
            decodedOrientation = nil
        }
        return TrajectoryPoseSample(
            position: SIMD3<Float>(
                position[0],
                position[1],
                position[2]
            ),
            cameraForward: SIMD3<Float>(
                cameraForward[0],
                cameraForward[1],
                cameraForward[2]
            ),
            elapsedTimeSeconds: elapsedTimeSeconds,
            orientationXYZW: decodedOrientation
        )
    }

    enum CodingKeys: String, CodingKey {
        case position
        case cameraForward = "camera_forward"
        case elapsedTimeSeconds = "elapsed_time_s"
        case orientationXYZW = "orientation_xyzw"
    }
}

struct TrajectoryArchive: Codable, Equatable {
    static let robotDisplayFrame = "X forward, Y left, Z up"
    static let physicalTCPDisplayFrame =
        "Initial physical FastUMI TCP frame; complete SE(3)"
    static let legacyDisplayFrame = "-X vertical, Y-Z ground"

    let schemaVersion: Int
    let kind: String
    let recordingID: String
    let displayName: String
    let startedAtUnixMs: Int64
    let endedAtUnixMs: Int64
    let pointCount: Int
    let positionUnit: String
    let displayFrame: String
    let samples: [TrajectoryArchiveSample]
    var captureProfile: CaptureProfileSnapshot? = nil
    var captureCoordination: ActiveCaptureCoordination? = nil

    init(
        recordingID: UUID,
        startedAtUnixMs: Int64,
        endedAtUnixMs: Int64,
        samples: [TrajectoryPoseSample],
        captureProfile: CaptureProfileSnapshot? = nil,
        captureCoordination: ActiveCaptureCoordination? = nil
    ) {
        schemaVersion = samples.allSatisfy {
            $0.elapsedTimeSeconds != nil
                && $0.orientationXYZW != nil
        } ? 2 : 1
        kind = "trajectory"
        self.recordingID = recordingID.uuidString
        displayName = CaptureLibraryDate.displayRange(
            startUnixMs: startedAtUnixMs,
            endUnixMs: endedAtUnixMs
        )
        self.startedAtUnixMs = startedAtUnixMs
        self.endedAtUnixMs = endedAtUnixMs
        pointCount = samples.count
        positionUnit = "metre"
        displayFrame = captureProfile?.captureRole == .wristUMI
            && captureProfile?.physicalTCPProfile != nil
            ? Self.physicalTCPDisplayFrame
            : Self.robotDisplayFrame
        self.samples = samples.map(TrajectoryArchiveSample.init)
        self.captureProfile = captureProfile
        self.captureCoordination = captureCoordination
    }

    var poseSamples: [TrajectoryPoseSample]? {
        var decoded = samples.compactMap(\.poseSample)
        guard decoded.count == samples.count,
              Self.isValid(samples: decoded, schemaVersion: schemaVersion)
        else {
            return nil
        }
        if displayFrame == Self.legacyDisplayFrame {
            decoded = decoded.map(Self.convertLegacySample)
        }
        return decoded
    }

    var hasRecordedTiming: Bool {
        schemaVersion >= 2 && poseSamples?.allSatisfy {
            $0.elapsedTimeSeconds != nil
                && $0.orientationXYZW != nil
        } == true
    }

    private static func isValid(
        samples: [TrajectoryPoseSample],
        schemaVersion: Int
    ) -> Bool {
        guard schemaVersion == 1 || schemaVersion == 2 else {
            return false
        }
        guard schemaVersion == 2 else {
            return true
        }

        var previousTime = -Double.infinity
        for sample in samples {
            guard let elapsed = sample.elapsedTimeSeconds,
                  elapsed.isFinite,
                  elapsed >= 0,
                  elapsed >= previousTime,
                  let orientation = sample.orientationXYZW,
                  orientation.x.isFinite,
                  orientation.y.isFinite,
                  orientation.z.isFinite,
                  orientation.w.isFinite
            else {
                return false
            }
            let norm = simd_length(orientation)
            guard norm > 0.99, norm < 1.01 else {
                return false
            }
            previousTime = elapsed
        }
        return true
    }

    private static func convertLegacySample(
        _ sample: TrajectoryPoseSample
    ) -> TrajectoryPoseSample {
        let convertedOrientation: SIMD4<Float>?
        if let orientation = sample.orientationXYZW {
            let oldRotation = simd_float3x3(
                simd_normalize(simd_quatf(vector: orientation))
            )
            let newRotation = simd_float3x3(
                legacyVectorToRobot(oldRotation.columns.0),
                legacyVectorToRobot(oldRotation.columns.1),
                legacyVectorToRobot(oldRotation.columns.2)
            )
            let quaternion = simd_normalize(simd_quatf(newRotation))
            convertedOrientation = quaternion.vector
        } else {
            convertedOrientation = nil
        }
        return TrajectoryPoseSample(
            position: legacyVectorToRobot(sample.position),
            cameraForward: legacyVectorToRobot(sample.cameraForward),
            elapsedTimeSeconds: sample.elapsedTimeSeconds,
            orientationXYZW: convertedOrientation
        )
    }

    private static func legacyVectorToRobot(
        _ vector: SIMD3<Float>
    ) -> SIMD3<Float> {
        // Legacy display coordinates were [down, left, forward].
        SIMD3<Float>(vector.z, vector.y, -vector.x)
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case kind
        case recordingID = "recording_id"
        case displayName = "display_name"
        case startedAtUnixMs = "started_at_unix_ms"
        case endedAtUnixMs = "ended_at_unix_ms"
        case pointCount = "point_count"
        case positionUnit = "position_unit"
        case displayFrame = "display_frame"
        case samples
        case captureProfile = "capture_profile"
        case captureCoordination = "capture_coordination"
    }
}

struct TrajectoryCaptureRecord: Identifiable, Equatable {
    let id: String
    let archive: TrajectoryArchive
    let fileURL: URL

    var displayName: String {
        archive.displayName
    }

    var samples: [TrajectoryPoseSample] {
        archive.poseSamples ?? []
    }

    var hasRecordedTiming: Bool {
        archive.hasRecordedTiming
    }

    var visualizationSamples: [TrajectoryPoseSample] {
        TrajectoryVisualizationPolicy.samples(
            from: samples,
            displayFrame: archive.displayFrame,
            captureRole: archive.captureProfile?.captureRole,
            calibrationID:
                archive.captureProfile?.calibration.calibrationID
        )
    }
}

enum TrajectoryVisualizationPolicy {
    static func samples(
        from source: [TrajectoryPoseSample],
        displayFrame: String,
        captureRole _: CaptureRole?,
        calibrationID _: String?
    ) -> [TrajectoryPoseSample] {
        let corrected = displayFrame == TrajectoryArchive.robotDisplayFrame
            ? source.compactMap(correctMislabeledLateralPose)
            : source
        return corrected.count == source.count ? corrected : source
    }

    private static func correctMislabeledLateralPose(
        _ sample: TrajectoryPoseSample
    ) -> TrajectoryPoseSample? {
        let correctedOrientation: SIMD4<Float>?
        if let orientation = sample.orientationXYZW {
            let oldRotation = simd_float3x3(
                simd_normalize(simd_quatf(vector: orientation))
            )
            let newRotation = simd_float3x3(
                correctLateral(oldRotation.columns.0),
                -correctLateral(oldRotation.columns.1),
                correctLateral(oldRotation.columns.2)
            )
            correctedOrientation = simd_normalize(
                simd_quatf(newRotation)
            ).vector
        } else {
            correctedOrientation = nil
        }
        return TrajectoryPoseSample(
            position: correctLateral(sample.position),
            cameraForward: simd_normalize(
                correctLateral(sample.cameraForward)
            ),
            elapsedTimeSeconds: sample.elapsedTimeSeconds,
            orientationXYZW: correctedOrientation
        )
    }

    private static func correctLateral(
        _ vector: SIMD3<Float>
    ) -> SIMD3<Float> {
        SIMD3<Float>(vector.x, -vector.y, vector.z)
    }
}

struct RGBCaptureRecord: Identifiable, Equatable {
    let id: String
    let info: RGBRecordingInfo
    let directoryURL: URL
    let videoURL: URL
    let infoURL: URL
    let displayName: String
    let sortTimestampUnixMs: Int64

    var shareURLs: [URL] {
        [
            videoURL,
            directoryURL.appendingPathComponent(
                "ego_rgb_224.mp4"
            ),
            directoryURL.appendingPathComponent(
                "frames.jsonl"
            ),
            infoURL
        ].filter {
            FileManager.default.fileExists(atPath: $0.path)
        }
    }
}

struct CaptureFileIdentity: Equatable, Hashable {
    let device: UInt64
    let inode: UInt64
    let byteSize: UInt64
    let modificationSeconds: Int64
    let modificationNanoseconds: Int64
}

struct CaptureExportPackageRecord: Identifiable, Equatable {
    let id: String
    let packageID: String
    let displayName: String
    let fileURL: URL
    let identity: CaptureFileIdentity
    let createdAtUnixMs: Int64
}

enum CaptureExportRecoveryState: String, Equatable {
    case incompleteWriting
    case corruptPackage
    case identityConflict
}

struct CaptureExportRecoveryRecord: Identifiable, Equatable {
    let id: String
    let displayName: String
    let fileURL: URL
    let identity: CaptureFileIdentity
    let state: CaptureExportRecoveryState
    let isDeletionEligible: Bool
    let diagnostic: String
}

enum CaptureLibraryDate {
    static func unixMilliseconds(_ date: Date = Date()) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }

    static func displayRange(
        startUnixMs: Int64,
        endUnixMs: Int64
    ) -> String {
        "\(displayTimestamp(startUnixMs)) → \(displayTimestamp(endUnixMs))"
    }

    static func displayTimestamp(_ unixMs: Int64) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(
            from: Date(timeIntervalSince1970: Double(unixMs) / 1_000)
        )
    }

    static func fileTimestamp(_ unixMs: Int64) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd_HHmmss_SSS"
        return formatter.string(
            from: Date(timeIntervalSince1970: Double(unixMs) / 1_000)
        )
    }
}
