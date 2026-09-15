import CryptoKit
import Foundation
import zlib

struct CaptureExportSelection: Codable, Equatable {
    var includeRawRGBVideo: Bool
    var includeProcessedRGBVideo: Bool
    var includeUltrawideObservation: Bool

    init(
        includeRawRGBVideo: Bool,
        includeProcessedRGBVideo: Bool,
        includeUltrawideObservation: Bool
    ) {
        self.includeRawRGBVideo = includeRawRGBVideo
        self.includeProcessedRGBVideo = includeProcessedRGBVideo
        self.includeUltrawideObservation = includeUltrawideObservation
    }

    static let all = CaptureExportSelection(
        includeRawRGBVideo: true,
        includeProcessedRGBVideo: true,
        includeUltrawideObservation: true
    )

    enum CodingKeys: String, CodingKey {
        case includeRawRGBVideo = "include_raw_rgb_video"
        case includeProcessedRGBVideo = "include_processed_rgb_video"
        case includeUltrawideObservation =
            "include_ultrawide_observation"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        includeRawRGBVideo = try container.decode(
            Bool.self,
            forKey: .includeRawRGBVideo
        )
        includeProcessedRGBVideo = try container.decode(
            Bool.self,
            forKey: .includeProcessedRGBVideo
        )
        includeUltrawideObservation = try container.decode(
            Bool.self,
            forKey: .includeUltrawideObservation
        )
    }

    func includesArtifact(named name: String) -> Bool {
        switch name {
        case "rgb.mp4":
            return includeRawRGBVideo
        case "ego_rgb_224.mp4":
            return includeProcessedRGBVideo
        case "frames.jsonl":
            return includeRawRGBVideo || includeProcessedRGBVideo
        case UltrawideRecordingWriter.videoFilename,
             UltrawideRecordingWriter.framesFilename,
             UltrawideRecordingWriter.previewFilename:
            return includeUltrawideObservation
        case "recording_info.json":
            return true
        default:
            return true
        }
    }
}

struct CaptureExportArtifactNaming: Equatable {
    let stem: String

    static func make(
        captureProfile: CaptureProfileSnapshot?,
        startedAtUnixMs: Int64
    ) -> CaptureExportArtifactNaming {
        let role = captureProfile?.captureRole == .wristUMI
            ? "hand"
            : "ego"
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let timestamp = formatter.string(
            from: Date(
                timeIntervalSince1970:
                    Double(startedAtUnixMs) / 1_000
            )
        )
        return CaptureExportArtifactNaming(
            stem: "\(role)_\(timestamp)"
        )
    }

    var packageFilename: String {
        "\(stem).zip"
    }

    func packagedName(for sourceName: String) -> String {
        switch sourceName {
        case "rgb.mp4":
            return "\(stem)_rgb.mp4"
        case "ego_rgb_224.mp4":
            return "\(stem)_rgb_224.mp4"
        case UltrawideRecordingWriter.videoFilename:
            return "\(stem)_ultrawide_rgb.mp4"
        default:
            return sourceName
        }
    }
}

struct CompletedCaptureArtifacts {
    let trajectoryURL: URL?
    let rgbVideoURLs: [URL]
    let primaryVideoURL: URL?
    let exportPackageURL: URL?
    let exportError: String?
    let exportPackageIdentity: CapturePackageFileIdentity?

    init(
        trajectoryURL: URL?,
        rgbVideoURLs: [URL],
        primaryVideoURL: URL?,
        exportPackageURL: URL?,
        exportError: String?,
        exportPackageIdentity: CapturePackageFileIdentity? = nil
    ) {
        self.trajectoryURL = trajectoryURL
        self.rgbVideoURLs = rgbVideoURLs
        self.primaryVideoURL = primaryVideoURL
        self.exportPackageURL = exportPackageURL
        self.exportError = exportError
        self.exportPackageIdentity = exportPackageIdentity
    }

    var fallbackShareURLs: [URL] {
        var urls: [URL] = []
        if let trajectoryURL {
            urls.append(trajectoryURL)
        }
        for videoURL in rgbVideoURLs {
            let directoryURL = videoURL.deletingLastPathComponent()
            for name in CaptureExportPackageBuilder.rgbArtifactNames {
                let url = directoryURL.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: url.path) {
                    urls.append(url)
                }
            }
        }
        return Self.uniqueURLs(urls)
    }

    var shareURLs: [URL] {
        if let exportPackageURL {
            return [exportPackageURL]
        }
        return fallbackShareURLs
    }

    private static func uniqueURLs(_ urls: [URL]) -> [URL] {
        var paths: Set<String> = []
        return urls.filter {
            paths.insert($0.standardizedFileURL.path).inserted
        }
    }
}

struct CapturePackageFileIdentity: Equatable {
    let sizeBytes: UInt64
    let sha256: String
}

struct CaptureExportPackage: Equatable {
    let fileURL: URL
    let includedFileCount: Int
    let warnings: [String]
    let identity: CapturePackageFileIdentity
}

final class CaptureExportPackageBuilder {
    static let rgbArtifactNames = [
        "rgb.mp4",
        "ego_rgb_224.mp4",
        "ultrawide_rgb.mp4",
        "ultrawide_frames.jsonl",
        "ultrawide_preview.jpg",
        "frames.jsonl",
        "recording_info.json"
    ]

    private let queue = DispatchQueue(
        label: "com.umicapture.capture-export-package",
        qos: .utility
    )
    private let explicitOutputDirectoryURL: URL?
    private let explicitTrustedSourceRootURL: URL?
    private let documentsDirectoryResolver: () -> URL?
    private let afterIntegrityPreflight: (() throws -> Void)?
    private let softwareProvenance: SoftwareProvenance

    init(
        outputDirectoryURL: URL? = nil,
        trustedSourceRootURL: URL? = nil,
        documentsDirectoryResolver: @escaping () -> URL? = {
            FileManager.default.urls(
                for: .documentDirectory,
                in: .userDomainMask
            ).first
        },
        afterIntegrityPreflight: (() throws -> Void)? = nil,
        softwareProvenance: SoftwareProvenance = .current()
    ) {
        explicitOutputDirectoryURL = outputDirectoryURL
        explicitTrustedSourceRootURL = trustedSourceRootURL
        self.documentsDirectoryResolver = documentsDirectoryResolver
        self.afterIntegrityPreflight = afterIntegrityPreflight
        self.softwareProvenance = softwareProvenance
    }

    func build(
        trajectoryURL: URL?,
        rgbVideoURLs: [URL],
        startedAtUnixMs: Int64?,
        endedAtUnixMs: Int64,
        selection: CaptureExportSelection = .all,
        captureProfile: CaptureProfileSnapshot? = nil,
        captureCoordination: ActiveCaptureCoordination? = nil,
        cancellationToken: CapturePackageCancellationToken? = nil,
        completion: @escaping (
            Result<CaptureExportPackage, Error>
        ) -> Void
    ) {
        queue.async {
            do {
                let package = try self.buildOnQueue(
                    trajectoryURL: trajectoryURL,
                    rgbVideoURLs: rgbVideoURLs,
                    startedAtUnixMs: startedAtUnixMs,
                    endedAtUnixMs: endedAtUnixMs,
                    selection: selection,
                    captureProfile: captureProfile,
                    captureCoordination: captureCoordination,
                    cancellationToken: cancellationToken
                )
                DispatchQueue.main.async {
                    completion(.success(package))
                }
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
    }

    private func buildOnQueue(
        trajectoryURL: URL?,
        rgbVideoURLs: [URL],
        startedAtUnixMs: Int64?,
        endedAtUnixMs: Int64,
        selection: CaptureExportSelection,
        captureProfile: CaptureProfileSnapshot?,
        captureCoordination: ActiveCaptureCoordination?,
        cancellationToken: CapturePackageCancellationToken?
    ) throws -> CaptureExportPackage {
        let directories = try resolveDirectories()
        let outputDirectoryURL = directories.output
        try FileManager.default.createDirectory(
            at: outputDirectoryURL,
            withIntermediateDirectories: true
        )

        let start = startedAtUnixMs ?? endedAtUnixMs
        let packageNaming = CaptureExportArtifactNaming.make(
            captureProfile: captureProfile,
            startedAtUnixMs: start
        )
        let destinationURL = availablePackageDestination(
            in: outputDirectoryURL,
            filename: packageNaming.packageFilename
        )
        let recordingID = UUID()
        let temporaryURL = outputDirectoryURL
            .appendingPathComponent(".\(recordingID.uuidString).writing")

        let input = try makeInput(
            trajectoryURL: trajectoryURL,
            rgbVideoURLs: rgbVideoURLs,
            startedAtUnixMs: startedAtUnixMs,
            endedAtUnixMs: endedAtUnixMs,
            recordingID: recordingID,
            trustedSourceRootURL: directories.trustedSourceRoot,
            outputDirectoryURL: outputDirectoryURL,
            selection: selection,
            captureProfile: captureProfile,
            captureCoordination: captureCoordination
        )
        try afterIntegrityPreflight?()
        var entries = input.fileEntries
        entries.insert(
            StoredZIPEntry(
                path: "capture_manifest.json",
                data: try makeManifestData(input.manifest)
            ),
            at: 0
        )
        entries.insert(
            StoredZIPEntry(
                path: "README.txt",
                data: makeReadmeData(input.manifest)
            ),
            at: 1
        )

        do {
            let writeResult = try StoredZIPArchiveWriter.write(
                entries: entries,
                to: temporaryURL,
                cancellationToken: cancellationToken
            )
            guard !FileManager.default.fileExists(
                atPath: destinationURL.path
            ) else {
                throw CaptureExportError.destinationAlreadyExists
            }
            try FileManager.default.moveItem(
                at: temporaryURL,
                to: destinationURL
            )
            return CaptureExportPackage(
                fileURL: destinationURL,
                includedFileCount: entries.count,
                warnings: input.manifest.warnings,
                identity: CapturePackageFileIdentity(
                    sizeBytes: writeResult.archiveByteSize,
                    sha256: writeResult.archiveSHA256
                )
            )
        } catch {
            throw CaptureExportError.packageWriteFailed(
                underlying: error,
                preservedPartialURL: temporaryURL
            )
        }

    }

    private func availablePackageDestination(
        in directoryURL: URL,
        filename: String
    ) -> URL {
        let initial = directoryURL.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: initial.path) else {
            return initial
        }
        let extensionName = initial.pathExtension
        let stem = initial.deletingPathExtension().lastPathComponent
        var sequence = 2
        while true {
            let candidate = directoryURL.appendingPathComponent(
                "\(stem)_\(sequence).\(extensionName)"
            )
            if !FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            sequence += 1
        }
    }

    private func makeInput(
        trajectoryURL: URL?,
        rgbVideoURLs: [URL],
        startedAtUnixMs: Int64?,
        endedAtUnixMs: Int64,
        recordingID: UUID,
        trustedSourceRootURL: URL,
        outputDirectoryURL: URL,
        selection: CaptureExportSelection,
        captureProfile: CaptureProfileSnapshot?,
        captureCoordination: ActiveCaptureCoordination?
    ) throws -> PackageInput {
        var entries: [StoredZIPEntry] = []
        var fileGuide: [CaptureExportFileGuide] = [
            CaptureExportFileGuide(
                path: "capture_manifest.json",
                required: true,
                purpose: "Machine-readable package index, coordinate/unit contract, processing workflow, segment summary, and integrity warnings.",
                howToUse: "Read this file first. Iterate file_guide for the exact role and usage of every packaged artifact, then inspect rgb_segments before processing any video."
            ),
            CaptureExportFileGuide(
                path: "README.txt",
                required: true,
                purpose: "Short bilingual human-readable handoff guide for the complete phone-side capture package.",
                howToUse: "Open directly after receiving or unzipping the package. It gives the minimal processing order and points to capture_manifest.json for field-level details."
            )
        ]
        var segmentGuides: [CaptureExportSegmentGuide] = []
        var warnings: [String] = []
        var canonicalProducerPaths: Set<String> = []
        var producerCount = 0

        if let trajectoryURL {
            let canonicalURL = try classifyProducerURL(
                trajectoryURL,
                expectedBasename: nil,
                canonicalProducerPaths: &canonicalProducerPaths,
                trustedSourceRootURL: trustedSourceRootURL
            )
            guard canonicalURL.lastPathComponent == "trajectory.json"
                    || canonicalURL.lastPathComponent.hasSuffix(
                        "_trajectory.json"
                    ) else {
                throw CaptureExportError.unexpectedProducerBasename(
                    canonicalURL.lastPathComponent
                )
            }
            let snapshot = try CaptureArtifactIntegrity.readSemanticData(
                from: canonicalURL,
                trustedRootURL: trustedSourceRootURL
            )
            let archive: TrajectoryArchive
            do {
                archive = try JSONDecoder().decode(
                    TrajectoryArchive.self,
                    from: snapshot
                )
            } catch {
                throw CaptureExportError.invalidTrajectoryArchive
            }
            guard archive.kind == "trajectory",
                  !archive.recordingID.isEmpty,
                  archive.pointCount == archive.samples.count,
                  archive.poseSamples != nil
            else {
                throw CaptureExportError.invalidTrajectoryArchive
            }
            let archivePath = "trajectory/trajectory.json"
            let descriptor = try CaptureArtifactIntegrity.descriptor(
                path: archivePath,
                producerKind: .trajectory,
                producerID: archive.recordingID,
                required: true,
                data: snapshot
            )
            entries.append(
                StoredZIPEntry(
                    path: archivePath,
                    data: snapshot,
                    descriptor: descriptor
                )
            )
            producerCount += 1
            fileGuide.append(
                CaptureExportFileGuide(
                    path: archivePath,
                    required: false,
                    purpose: "Downsampled logical trajectory for 3D preview and trajectory-level playback.",
                    howToUse: "Read samples in order. position is metres in the documented display frame; elapsed_time_s is active Streaming time and orientation_xyzw is x,y,z,w. Do not use this file as a replacement for frames.jsonl when aligning RGB frames."
                )
            )
        } else {
            warnings.append(
                "No completed trajectory archive was available for this capture."
            )
        }

        var canonicalSegmentDirectories: Set<String> = []
        for (index, declaredVideoURL) in rgbVideoURLs.enumerated() {
            let segmentAnchorURL = try classifyProducerURL(
                declaredVideoURL,
                expectedBasename:
                    declaredVideoURL.lastPathComponent == "rgb.mp4"
                        ? "rgb.mp4"
                        : "recording_info.json",
                canonicalProducerPaths: &canonicalProducerPaths,
                trustedSourceRootURL: trustedSourceRootURL
            )
            let segmentNumber = index + 1
            let segmentName = String(
                format: "segment_%03d",
                segmentNumber
            )
            let sourceDirectory = try CaptureArtifactIntegrity
                .canonicalSourceURL(
                    segmentAnchorURL.deletingLastPathComponent(),
                    trustedRootURL: trustedSourceRootURL
                )
            guard canonicalSegmentDirectories.insert(
                sourceDirectory.path
            ).inserted else {
                throw CaptureExportError.duplicateProducerInput
            }
            var includedNames: [String] = []
            var archiveNamesBySourceName: [String: String] = [:]
            var missingNames: [String] = []
            var excludedNames: [String] = []
            let infoURL = sourceDirectory.appendingPathComponent(
                "recording_info.json"
            )
            let infoData = try CaptureArtifactIntegrity.readSemanticData(
                from: infoURL,
                trustedRootURL: trustedSourceRootURL
            )
            let recordingInfo: RGBRecordingInfo
            do {
                recordingInfo = try JSONDecoder().decode(
                    RGBRecordingInfo.self,
                    from: infoData
                )
            } catch {
                throw CaptureExportError.invalidRecordingInfo
            }
            let effectiveCaptureProfile =
                recordingInfo.captureProfile ?? captureProfile
            let segmentNaming = CaptureExportArtifactNaming.make(
                captureProfile: effectiveCaptureProfile,
                startedAtUnixMs:
                    recordingInfo.startedAtUnixMs
                    ?? startedAtUnixMs
                    ?? endedAtUnixMs
            )
            let capturedMediaFrameCount =
                recordingInfo.encodedFrameCount
                + (recordingInfo.umiEncodedFrameCount ?? 0)
                + (recordingInfo.ultrawideEncodedFrameCount ?? 0)
            guard !recordingInfo.recordingUUID.isEmpty,
                  sourceDirectory.lastPathComponent
                    == recordingInfo.recordingUUID,
                  recordingInfo.width > 0,
                  recordingInfo.height > 0,
                  recordingInfo.nominalFPS > 0,
                  capturedMediaFrameCount > 0,
                  recordingInfo.framesMetadataFilename
                    ?? "frames.jsonl" == "frames.jsonl"
            else {
                throw CaptureExportError.invalidRecordingInfo
            }
            let declaredUMIFilename = recordingInfo.umiVideoFilename
            if let declaredUMIFilename {
                guard declaredUMIFilename == "ego_rgb_224.mp4",
                      let encodedCount = recordingInfo.umiEncodedFrameCount,
                      encodedCount > 0
                else {
                    throw CaptureExportError.invalidRecordingInfo
                }
            }
            let declaredUltrawideNames = Set(
                [
                    recordingInfo.ultrawideVideoFilename,
                    recordingInfo.ultrawideFramesMetadataFilename,
                    recordingInfo.ultrawidePreviewFilename
                ].compactMap { $0 }
            )
            if recordingInfo.ultrawideVideoFilename != nil {
                guard recordingInfo.ultrawideVideoFilename
                        == UltrawideRecordingWriter.videoFilename,
                      recordingInfo.ultrawideFramesMetadataFilename
                        == UltrawideRecordingWriter.framesFilename,
                      let encodedCount = recordingInfo
                        .ultrawideEncodedFrameCount,
                      encodedCount > 0,
                      let width = recordingInfo.ultrawideWidth,
                      let height = recordingInfo.ultrawideHeight,
                      width > 0,
                      height > 0,
                      declaredUltrawideNames.isSubset(
                        of: Set([
                            UltrawideRecordingWriter.videoFilename,
                            UltrawideRecordingWriter.framesFilename,
                            UltrawideRecordingWriter.previewFilename
                        ])
                      )
                else {
                    throw CaptureExportError.invalidRecordingInfo
                }
            } else if !declaredUltrawideNames.isEmpty {
                throw CaptureExportError.invalidRecordingInfo
            }
            for artifactName in Self.rgbArtifactNames {
                let sourceURL = sourceDirectory
                    .appendingPathComponent(artifactName)
                guard selection.includesArtifact(named: artifactName)
                else {
                    excludedNames.append(artifactName)
                    continue
                }
                let isUMIDerivative = artifactName == "ego_rgb_224.mp4"
                let isUltrawideArtifact = [
                    UltrawideRecordingWriter.videoFilename,
                    UltrawideRecordingWriter.framesFilename,
                    UltrawideRecordingWriter.previewFilename
                ].contains(artifactName)
                let isOptional = (
                    isUMIDerivative && declaredUMIFilename == nil
                ) || (
                    isUltrawideArtifact
                        && !declaredUltrawideNames.contains(artifactName)
                )
                if isOptional,
                   FileManager.default.fileExists(atPath: sourceURL.path) {
                    if isUMIDerivative {
                        warnings.append(
                            "\(segmentName) contains an undeclared "
                                + "ego_rgb_224.mp4; omitted from the "
                                + "completed package."
                        )
                    } else {
                        warnings.append(
                            "\(segmentName) contains undeclared "
                                + "\(artifactName); omitted from the "
                                + "completed package."
                        )
                    }
                    missingNames.append(artifactName)
                    continue
                }
                guard FileManager.default.fileExists(atPath: sourceURL.path)
                else {
                    if !isOptional {
                        throw CaptureExportError.missingRequiredArtifact(
                            artifactName
                        )
                    }
                    missingNames.append(artifactName)
                    continue
                }
                let packagedName = effectiveCaptureProfile == nil
                    ? artifactName
                    : segmentNaming.packagedName(for: artifactName)
                let archivePath = "rgb/\(segmentName)/\(packagedName)"
                let descriptor: CaptureArtifactDescriptor
                if artifactName == "recording_info.json" {
                    descriptor = try CaptureArtifactIntegrity.descriptor(
                        path: archivePath,
                        producerKind: .rgbSegment,
                        producerID: recordingInfo.recordingUUID,
                        required: true,
                        data: infoData
                    )
                    entries.append(
                        StoredZIPEntry(
                            path: archivePath,
                            data: infoData,
                            descriptor: descriptor
                        )
                    )
                } else {
                    descriptor = try CaptureArtifactIntegrity.descriptor(
                        path: archivePath,
                        producerKind: .rgbSegment,
                        producerID: recordingInfo.recordingUUID,
                        required: !isOptional,
                        fileURL: sourceURL,
                        trustedRootURL: trustedSourceRootURL
                    )
                    entries.append(
                        StoredZIPEntry(
                            path: archivePath,
                            fileURL: sourceURL,
                            descriptor: descriptor
                        )
                    )
                }
                includedNames.append(packagedName)
                archiveNamesBySourceName[artifactName] = packagedName
                fileGuide.append(
                    guide(
                        archivePath: archivePath,
                        artifactName: artifactName,
                        required: !isOptional,
                        dataKey: CaptureDataKey.main(
                            for: effectiveCaptureProfile
                        )
                    )
                )
            }

            if !missingNames.isEmpty {
                warnings.append(
                    "\(segmentName) is missing: "
                        + missingNames.joined(separator: ", ")
                )
            }
            if !excludedNames.isEmpty {
                warnings.append(
                    "\(segmentName) intentionally excludes from this ZIP: "
                        + excludedNames.joined(separator: ", ")
                        + ". The source capture remains on the iPhone."
                )
            }
            segmentGuides.append(
                CaptureExportSegmentGuide(
                    name: segmentName,
                    recordingUUID: recordingInfo.recordingUUID,
                    displayName: recordingInfo.displayName,
                    lensMode: recordingInfo.lensMode?.rawValue,
                    physicalCameraType: recordingInfo.physicalCameraType,
                    width: recordingInfo.width,
                    height: recordingInfo.height,
                    nominalFPS: recordingInfo.nominalFPS,
                    includedFiles: includedNames,
                    archiveNamesBySourceName:
                        archiveNamesBySourceName,
                    missingFiles: missingNames,
                    excludedFiles: excludedNames
                )
            )
            producerCount += 1
        }

        if rgbVideoURLs.isEmpty {
            warnings.append(
                "RGB recording was disabled or no playable RGB segment was finalized."
            )
        }
        warnings.append(
            "Mac receiver poses.csv and metadata.json are not stored on the iPhone and are not included. Add them separately only when full-rate Socket.IO VIO or receiver-derived velocity/angular-rate fields are required."
        )
        guard producerCount > 0 else {
            throw CaptureExportError.noDeclaredProducer
        }

        let descriptors = entries.compactMap(\.descriptor)
        guard descriptors.count == entries.count,
              Set(descriptors.map(\.path)).count == descriptors.count
        else {
            throw CaptureExportError.invalidIntegrityEnvelope
        }

        let manifest = CaptureExportManifest(
            schemaVersion: 1,
            kind: "iphonevio_capture_export",
            packageID: recordingID.uuidString,
            createdAtUnixMs: CaptureLibraryDate.unixMilliseconds(),
            captureStartedAtUnixMs: startedAtUnixMs,
            captureEndedAtUnixMs: endedAtUnixMs,
            positionUnit: "metre",
            quaternionOrder: "qx qy qz qw",
            poseFrame: "frames.jsonl camera_pose is the immutable reference-relative ARKit camera transform. Each phone has an independent local ARKit coordinate frame. For a Hand profile with physical_tcp_profile, trajectory/trajectory.json is the downsampled complete-SE(3) motion in the initial physical FastUMI TCP frame. It is not an Ego-Hand transform or robot-body absolute pose.",
            cameraRole: captureProfile?.captureRole == .wristUMI
                ? "wrist_umi_camera"
                : "chest_ego_camera",
            dataKey: CaptureDataKey.main(for: captureProfile),
            captureProfile: captureProfile,
            captureCoordination: captureCoordination,
            softwareProvenance: softwareProvenance,
            exportSelection: selection,
            recommendedWorkflow: [
                "Read export_selection, each rgb_segments archive_names_by_source_name/included_files/excluded_files list, and recording_info.json before looking for media.",
                "Use archive_names_by_source_name to locate role-and-time-named RGB media. Source names remain recorded for compatibility.",
                "When a 1x video is included, read frames.jsonl line by line and match decoded video time to mp4_pts_s. Use camera_pose, arkit_camera_intrinsics, tracking_state, and lens metadata from the same record.",
                "Use trajectory/trajectory.json only for logical-path preview or trajectory-level playback; it is downsampled and is not the per-video-frame join table.",
                "For Hand, preserve physical_tcp_profile and compute canonical full-rate motion from raw camera_pose as inverse(camera_T_tcp) * camera_pose * camera_T_tcp. Retarget to the robot only with the separately versioned physical robot TCP start profile.",
                "Honor this package's \(CaptureDataKey.main(for: captureProfile)) data_key and camera metadata; do not relabel it as the other device role or substitute GoPro calibration."
            ],
            fileGuide: fileGuide,
            rgbSegments: segmentGuides,
            completionState: "completed",
            integritySchemaVersion: 1,
            artifactIntegrity: descriptors.sorted { $0.path < $1.path },
            preservedPartialNames: preservedPartialNames(
                outputDirectoryURL: outputDirectoryURL
            ),
            warnings: warnings
        )
        return PackageInput(
            manifest: manifest,
            fileEntries: entries
        )
    }

    private func guide(
        archivePath: String,
        artifactName: String,
        required: Bool,
        dataKey: String
    ) -> CaptureExportFileGuide {
        switch artifactName {
        case "rgb.mp4":
            return CaptureExportFileGuide(
                path: archivePath,
                required: required,
                purpose: "Original native-resolution 4:3 HEVC RGB video from ARFrame.capturedImage.",
                howToUse: "Decode without assuming a different resolution, crop, digital zoom, or stabilization. Use frames.jsonl mp4_pts_s for timing."
            )
        case "ego_rgb_224.mp4":
            return CaptureExportFileGuide(
                path: archivePath,
                required: required,
                purpose: "Deterministic 224x224 processed RGB derivative prepared for UMI-style consumers.",
                howToUse: "Use as \(dataKey). The legacy source filename may remain ego_rgb_224.mp4; rely on archive_names_by_source_name plus recording_info.json and frame-row data_key for role, preprocessing, and effective intrinsics."
            )
        case "frames.jsonl":
            return CaptureExportFileGuide(
                path: archivePath,
                required: required,
                purpose: "One JSON object per attempted ARKit RGB frame, including timestamps, camera pose, intrinsics, tracking state, lens, orientation, and encoding result.",
                howToUse: "Stream line by line. Keep encoded=true for rgb.mp4; keep umi_224_encoded=true for the mapped 224x224 derivative. Align video using mp4_pts_s, not line number alone. arkit_timestamp_s is the ARKit monotonic device timestamp."
            )
        case UltrawideRecordingWriter.videoFilename:
            return CaptureExportFileGuide(
                path: archivePath,
                required: required,
                purpose: "Original 0.5x ultrawide observation video obtained from the same ARFrame timeline as metric VIO.",
                howToUse: "Decode with ultrawide_frames.jsonl. This is an observation stream; ARKit VIO still uses the supported 1x camera."
            )
        case UltrawideRecordingWriter.framesFilename:
            return CaptureExportFileGuide(
                path: archivePath,
                required: required,
                purpose: "Per-frame ultrawide timestamps, intrinsics, resolution and reference-relative ARKit metric camera pose bindings.",
                howToUse: "Keep encoded=true rows and join decoded video time using mp4_pts_s. pose_match_delta_s reports the timestamp association error."
            )
        case UltrawideRecordingWriter.previewFilename:
            return CaptureExportFileGuide(
                path: archivePath,
                required: required,
                purpose: "First successfully encoded 0.5x frame for a quick field-of-view and marker visibility check.",
                howToUse: "Inspect visually before training ingestion; use the MP4 and JSONL for actual data processing."
            )
        default:
            return CaptureExportFileGuide(
                path: archivePath,
                required: required,
                purpose: "Segment-level recording metadata and integrity summary.",
                howToUse: "Read before processing. It identifies the physical lens, source/effective resolution and FPS, camera role/data key, empirical calibration, preprocessing, encoded/dropped counts, and finish reason."
            )
        }
    }

    private func makeManifestData(
        _ manifest: CaptureExportManifest
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(manifest)
    }

    private func makeReadmeData(
        _ manifest: CaptureExportManifest
    ) -> Data {
        let provenance = manifest.softwareProvenance
        var lines = [
            "\(provenance.appName) Capture Package / \(provenance.appName) 采集包",
            "",
            "Software: \(provenance.appName) "
                + "\(provenance.marketingVersion) "
                + "(build \(provenance.buildNumber))",
            "Bundle identifier: \(provenance.bundleIdentifier)"
        ]
        lines.append(contentsOf: provenance.attributionLines)
        lines.append(contentsOf: [
            "",
            "This ZIP contains the phone-side artifacts selected for one logical capture.",
            "此 ZIP 包含本次逻辑采集中由导出设置选中的手机端文件。",
            "",
            "Quick use / 快速使用：",
            "1. Read export_selection, archive_names_by_source_name, included_files/excluded_files, and recording_info.json first.",
            "   先读取 export_selection、archive_names_by_source_name、included_files/excluded_files 和 recording_info.json。",
            "2. Use archive_names_by_source_name to locate role-and-time-named RGB media.",
            "   用 archive_names_by_source_name 查找按机位和时间命名的 RGB 文件。",
            "3. When a 1x video is included, stream frames.jsonl and align with mp4_pts_s.",
            "   包含 1× 视频时，逐行读取 frames.jsonl，并用 mp4_pts_s 对齐。",
            "4. camera_pose is the per-frame reference-relative ARKit camera transform.",
            "   camera_pose 是逐帧 reference-relative ARKit 相机位姿。",
            "5. trajectory.json is downsampled preview data, not the RGB frame join table.",
            "   trajectory.json 是降采样预览轨迹，不能代替逐帧对齐表。",
            "",
            "Units / 单位：position = metre; quaternion = qx qy qz qw.",
            "Camera role / 相机角色：\(manifest.cameraRole); data key = \(manifest.dataKey).",
            "",
            "Important / 注意：",
            "- Excluded media remains in the phone capture directory; export selection never deletes it.",
            "- 未加入 ZIP 的媒体仍保存在手机采集目录中；导出选项不会删除源文件。",
            "- Do not mix 1x and 0.5x calibration or use GoPro/wrist-camera intrinsics.",
            "- 不要混用 1×、0.5× 标定，也不要使用 GoPro/腕部相机内参。",
            "- Mac poses.csv is not on the phone. Add it only when full-rate receiver pose or derived motion fields are needed.",
            "- Mac 端 poses.csv 不在手机包内；需要完整频率 VIO 或速度/角速度时另行附加。",
            "",
            "See capture_manifest.json for the exact file list, segment metadata, field guidance, and warnings."
        ])
        if !manifest.warnings.isEmpty {
            lines.append("")
            lines.append("Warnings / 警告：")
            lines.append(contentsOf: manifest.warnings.map { "- \($0)" })
        }
        return Data(lines.joined(separator: "\n").utf8)
    }

    private func classifyProducerURL(
        _ declaredURL: URL,
        expectedBasename: String?,
        canonicalProducerPaths: inout Set<String>,
        trustedSourceRootURL: URL
    ) throws -> URL {
        guard expectedBasename == nil
                || declaredURL.lastPathComponent == expectedBasename else {
            throw CaptureExportError.unexpectedProducerBasename(
                declaredURL.lastPathComponent
            )
        }
        let canonicalURL = try CaptureArtifactIntegrity.canonicalSourceURL(
            declaredURL,
            trustedRootURL: trustedSourceRootURL
        )
        try CaptureArtifactIntegrity.validateRegularFile(
            canonicalURL,
            trustedRootURL: trustedSourceRootURL
        )
        guard canonicalProducerPaths.insert(canonicalURL.path).inserted else {
            throw CaptureExportError.duplicateProducerInput
        }
        return canonicalURL
    }

    private func preservedPartialNames(
        outputDirectoryURL: URL
    ) -> [String] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: outputDirectoryURL,
            includingPropertiesForKeys: nil,
            options: []
        ) else {
            return []
        }
        return urls.compactMap { url in
            let name = url.lastPathComponent
            guard name.hasPrefix("."), name.hasSuffix(".writing"),
                  !name.contains("/"), !name.contains("\\") else {
                return nil
            }
            return name
        }.sorted()
    }

    private func resolveDirectories() throws -> (
        output: URL,
        trustedSourceRoot: URL
    ) {
        let needsDocuments = explicitOutputDirectoryURL == nil
            || explicitTrustedSourceRootURL == nil
        let documentsURL = needsDocuments
            ? documentsDirectoryResolver()?.standardizedFileURL
            : nil
        if needsDocuments, documentsURL == nil {
            throw CaptureExportError.durableOutputDirectoryUnavailable
        }
        let output = explicitOutputDirectoryURL
            ?? documentsURL!.appendingPathComponent(
                "CaptureExportPackages",
                isDirectory: true
            )
        let trustedSourceRoot = explicitTrustedSourceRootURL
            ?? documentsURL!
        return (output.standardizedFileURL, trustedSourceRoot)
    }
}

private struct PackageInput {
    let manifest: CaptureExportManifest
    let fileEntries: [StoredZIPEntry]
}

private struct CaptureExportManifest: Codable {
    let schemaVersion: Int
    let kind: String
    let packageID: String
    let createdAtUnixMs: Int64
    let captureStartedAtUnixMs: Int64?
    let captureEndedAtUnixMs: Int64
    let positionUnit: String
    let quaternionOrder: String
    let poseFrame: String
    let cameraRole: String
    let dataKey: String
    let captureProfile: CaptureProfileSnapshot?
    let captureCoordination: ActiveCaptureCoordination?
    let softwareProvenance: SoftwareProvenance
    let exportSelection: CaptureExportSelection
    let recommendedWorkflow: [String]
    let fileGuide: [CaptureExportFileGuide]
    let rgbSegments: [CaptureExportSegmentGuide]
    let completionState: String
    let integritySchemaVersion: Int
    let artifactIntegrity: [CaptureArtifactDescriptor]
    let preservedPartialNames: [String]
    let warnings: [String]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case kind
        case packageID = "package_id"
        case createdAtUnixMs = "created_at_unix_ms"
        case captureStartedAtUnixMs = "capture_started_at_unix_ms"
        case captureEndedAtUnixMs = "capture_ended_at_unix_ms"
        case positionUnit = "position_unit"
        case quaternionOrder = "quaternion_order"
        case poseFrame = "pose_frame"
        case cameraRole = "camera_role"
        case dataKey = "data_key"
        case captureProfile = "capture_profile"
        case captureCoordination = "capture_coordination"
        case softwareProvenance = "software_provenance"
        case exportSelection = "export_selection"
        case recommendedWorkflow = "recommended_workflow"
        case fileGuide = "file_guide"
        case rgbSegments = "rgb_segments"
        case completionState = "completion_state"
        case integritySchemaVersion = "integrity_schema_version"
        case artifactIntegrity = "artifact_integrity"
        case preservedPartialNames = "preserved_partial_names"
        case warnings
    }
}

private struct CaptureExportFileGuide: Codable {
    let path: String
    let required: Bool
    let purpose: String
    let howToUse: String

    enum CodingKeys: String, CodingKey {
        case path
        case required
        case purpose
        case howToUse = "how_to_use"
    }
}

private struct CaptureExportSegmentGuide: Codable {
    let name: String
    let recordingUUID: String?
    let displayName: String?
    let lensMode: String?
    let physicalCameraType: String?
    let width: Int?
    let height: Int?
    let nominalFPS: Int?
    let includedFiles: [String]
    let archiveNamesBySourceName: [String: String]
    let missingFiles: [String]
    let excludedFiles: [String]

    enum CodingKeys: String, CodingKey {
        case name
        case recordingUUID = "recording_uuid"
        case displayName = "display_name"
        case lensMode = "lens_mode"
        case physicalCameraType = "physical_camera_type"
        case width
        case height
        case nominalFPS = "nominal_fps"
        case includedFiles = "included_files"
        case archiveNamesBySourceName =
            "archive_names_by_source_name"
        case missingFiles = "missing_files"
        case excludedFiles = "excluded_files"
    }
}

struct StoredZIPEntry {
    enum Source {
        case data(Data)
        case file(URL)
    }

    let path: String
    let source: Source
    let descriptor: CaptureArtifactDescriptor?

    init(
        path: String,
        data: Data,
        descriptor: CaptureArtifactDescriptor? = nil
    ) {
        self.path = path
        source = .data(data)
        self.descriptor = descriptor
    }

    init(
        path: String,
        fileURL: URL,
        descriptor: CaptureArtifactDescriptor? = nil
    ) {
        self.path = path
        source = .file(fileURL)
        self.descriptor = descriptor
    }
}

struct StoredZIPWriteResult: Equatable {
    let archiveByteSize: UInt64
    let archiveSHA256: String
}

private final class StoredZIPOutputSink {
    private let handle: FileHandle
    private var hasher = SHA256()
    private(set) var byteSize: UInt64 = 0

    init(handle: FileHandle) {
        self.handle = handle
    }

    func write(_ data: Data) throws {
        guard !data.isEmpty else { return }
        hasher.update(data: data)
        try handle.write(contentsOf: data)
        byteSize += UInt64(data.count)
    }

    func finish() throws -> StoredZIPWriteResult {
        try handle.synchronize()
        return StoredZIPWriteResult(
            archiveByteSize: byteSize,
            archiveSHA256: hasher.finalize().map {
                String(format: "%02x", $0)
            }.joined()
        )
    }
}

enum StoredZIPArchiveWriter {
    private struct CentralRecord {
        let nameData: Data
        let crc32: UInt32
        let size: UInt32
        let localHeaderOffset: UInt32
    }

    @discardableResult
    static func write(
        entries: [StoredZIPEntry],
        to destinationURL: URL,
        cancellationToken: CapturePackageCancellationToken? = nil
    ) throws -> StoredZIPWriteResult {
        guard !entries.isEmpty,
              entries.count <= Int(UInt16.max)
        else {
            throw CaptureExportError.tooManyFiles
        }
        let normalizedEntries = try entries.map {
            (entry: $0, path: try normalizedEntryPath($0.path))
        }
        guard Set(normalizedEntries.map(\.path)).count
                == normalizedEntries.count else {
            throw CaptureExportError.duplicateArchivePath
        }
        let controlPaths = Set(["capture_manifest.json", "README.txt"])
        for item in normalizedEntries {
            if controlPaths.contains(item.path) {
                guard item.entry.descriptor == nil else {
                    throw CaptureExportError.invalidIntegrityEnvelope
                }
            } else {
                guard let descriptor = item.entry.descriptor,
                      descriptor.path == item.path else {
                    throw CaptureExportError.invalidIntegrityEnvelope
                }
            }
        }
        FileManager.default.createFile(
            atPath: destinationURL.path,
            contents: nil
        )
        let outputHandle = try FileHandle(forWritingTo: destinationURL)
        let output = StoredZIPOutputSink(handle: outputHandle)
        defer {
            try? outputHandle.close()
        }

        var offset: UInt64 = 0
        var centralRecords: [CentralRecord] = []
        for item in normalizedEntries {
            try cancellationToken?.throwIfCancelled()
            let entry = item.entry
            let normalizedPath = item.path
            let nameData = Data(normalizedPath.utf8)
            guard nameData.count <= Int(UInt16.max),
                  offset <= UInt64(UInt32.max)
            else {
                throw CaptureExportError.zip64Required
            }
            let expectedSize = try sourceSize(entry.source)
            guard expectedSize <= UInt64(UInt32.max) else {
                throw CaptureExportError.zip64Required
            }
            let localOffset = UInt32(offset)
            var localHeader = Data()
            localHeader.appendLittleEndian(UInt32(0x04034B50))
            localHeader.appendLittleEndian(UInt16(20))
            localHeader.appendLittleEndian(UInt16(0x0808))
            localHeader.appendLittleEndian(UInt16(0))
            localHeader.appendLittleEndian(UInt16(0))
            localHeader.appendLittleEndian(UInt16(33))
            localHeader.appendLittleEndian(UInt32(0))
            localHeader.appendLittleEndian(UInt32(0))
            localHeader.appendLittleEndian(UInt32(0))
            localHeader.appendLittleEndian(UInt16(nameData.count))
            localHeader.appendLittleEndian(UInt16(0))
            localHeader.append(nameData)
            try output.write(localHeader)
            offset += UInt64(localHeader.count)

            let streamed = try stream(
                entry.source,
                to: output,
                cancellationToken: cancellationToken
            )
            guard streamed.size == expectedSize else {
                throw CaptureExportError.fileChangedDuringExport
            }
            if let descriptor = entry.descriptor {
                guard streamed.size == descriptor.byteSize,
                      streamed.sha256 == descriptor.sha256 else {
                    throw CaptureExportError.fileChangedDuringExport
                }
            }
            offset += streamed.size

            var descriptor = Data()
            descriptor.appendLittleEndian(UInt32(0x08074B50))
            descriptor.appendLittleEndian(streamed.crc32)
            descriptor.appendLittleEndian(UInt32(streamed.size))
            descriptor.appendLittleEndian(UInt32(streamed.size))
            try output.write(descriptor)
            offset += UInt64(descriptor.count)
            centralRecords.append(
                CentralRecord(
                    nameData: nameData,
                    crc32: streamed.crc32,
                    size: UInt32(streamed.size),
                    localHeaderOffset: localOffset
                )
            )
        }

        guard offset <= UInt64(UInt32.max) else {
            throw CaptureExportError.zip64Required
        }
        let centralOffset = UInt32(offset)
        for record in centralRecords {
            var header = Data()
            header.appendLittleEndian(UInt32(0x02014B50))
            header.appendLittleEndian(UInt16(0x0314))
            header.appendLittleEndian(UInt16(20))
            header.appendLittleEndian(UInt16(0x0808))
            header.appendLittleEndian(UInt16(0))
            header.appendLittleEndian(UInt16(0))
            header.appendLittleEndian(UInt16(33))
            header.appendLittleEndian(record.crc32)
            header.appendLittleEndian(record.size)
            header.appendLittleEndian(record.size)
            header.appendLittleEndian(UInt16(record.nameData.count))
            header.appendLittleEndian(UInt16(0))
            header.appendLittleEndian(UInt16(0))
            header.appendLittleEndian(UInt16(0))
            header.appendLittleEndian(UInt16(0))
            header.appendLittleEndian(UInt32(0x81A4_0000))
            header.appendLittleEndian(record.localHeaderOffset)
            header.append(record.nameData)
            try output.write(header)
            offset += UInt64(header.count)
        }
        let centralSize64 = offset - UInt64(centralOffset)
        guard centralSize64 <= UInt64(UInt32.max),
              offset <= UInt64(UInt32.max)
        else {
            throw CaptureExportError.zip64Required
        }

        var end = Data()
        end.appendLittleEndian(UInt32(0x06054B50))
        end.appendLittleEndian(UInt16(0))
        end.appendLittleEndian(UInt16(0))
        end.appendLittleEndian(UInt16(centralRecords.count))
        end.appendLittleEndian(UInt16(centralRecords.count))
        end.appendLittleEndian(UInt32(centralSize64))
        end.appendLittleEndian(centralOffset)
        end.appendLittleEndian(UInt16(0))
        try output.write(end)
        guard output.byteSize == offset + UInt64(end.count) else {
            throw CaptureExportError.fileChangedDuringExport
        }
        return try output.finish()
    }

    private static func normalizedEntryPath(
        _ path: String
    ) throws -> String {
        let normalized = path.replacingOccurrences(
            of: "\\",
            with: "/"
        )
        guard !normalized.isEmpty,
              !normalized.hasPrefix("/"),
              !normalized.split(separator: "/").contains("..")
        else {
            throw CaptureExportError.unsafeArchivePath
        }
        return normalized
    }

    private static func sourceSize(
        _ source: StoredZIPEntry.Source
    ) throws -> UInt64 {
        switch source {
        case .data(let data):
            return UInt64(data.count)
        case .file(let url):
            let values = try url.resourceValues(
                forKeys: [.fileSizeKey, .isRegularFileKey]
            )
            guard values.isRegularFile == true,
                  let size = values.fileSize,
                  size >= 0
            else {
                throw CaptureExportError.invalidSourceFile
            }
            return UInt64(size)
        }
    }

    private static func stream(
        _ source: StoredZIPEntry.Source,
        to output: StoredZIPOutputSink,
        cancellationToken: CapturePackageCancellationToken?
    ) throws -> (size: UInt64, crc32: UInt32, sha256: String) {
        var checksum = zlib.crc32(0, nil, 0)
        var hasher = SHA256()
        var total: UInt64 = 0

        func writeChunk(_ data: Data) throws {
            guard !data.isEmpty else {
                return
            }
            try cancellationToken?.throwIfCancelled()
            checksum = data.withUnsafeBytes { bytes in
                zlib.crc32(
                    checksum,
                    bytes.bindMemory(to: Bytef.self).baseAddress,
                    uInt(data.count)
                )
            }
            hasher.update(data: data)
            try output.write(data)
            total += UInt64(data.count)
        }

        switch source {
        case .data(let data):
            try writeChunk(data)
        case .file(let url):
            let input = try FileHandle(forReadingFrom: url)
            defer {
                try? input.close()
            }
            while let chunk = try autoreleasepool(invoking: {
                try input.read(upToCount: 1_048_576)
            }), !chunk.isEmpty {
                try writeChunk(chunk)
            }
        }
        return (
            total,
            UInt32(checksum),
            hasher.finalize().map {
                String(format: "%02x", $0)
            }.joined()
        )
    }
}

enum CaptureExportError: LocalizedError {
    case durableOutputDirectoryUnavailable
    case tooManyFiles
    case zip64Required
    case fileChangedDuringExport
    case invalidSourceFile
    case unsafeArchivePath
    case unexpectedProducerBasename(String)
    case duplicateProducerInput
    case duplicateArchivePath
    case missingRequiredArtifact(String)
    case invalidTrajectoryArchive
    case invalidRecordingInfo
    case noDeclaredProducer
    case invalidIntegrityEnvelope
    case destinationAlreadyExists
    case packageWriteFailed(underlying: Error, preservedPartialURL: URL)

    var errorDescription: String? {
        switch self {
        case .durableOutputDirectoryUnavailable:
            return "The durable Documents capture-package directory is unavailable."
        case .tooManyFiles:
            return "The capture contains too many files for one ZIP package."
        case .zip64Required:
            return "The capture package exceeds the current 4 GB ZIP limit. Share the raw files instead."
        case .fileChangedDuringExport:
            return "A capture file changed while the export package was being prepared."
        case .invalidSourceFile:
            return "A capture artifact is missing or is not a regular file."
        case .unsafeArchivePath:
            return "The capture package contains an unsafe archive path."
        case .unexpectedProducerBasename(let name):
            return "Unexpected capture producer filename: \(name)."
        case .duplicateProducerInput:
            return "A capture producer was declared more than once."
        case .duplicateArchivePath:
            return "The capture package contains a duplicate archive path."
        case .missingRequiredArtifact(let name):
            return "A required capture artifact is missing: \(name)."
        case .invalidTrajectoryArchive:
            return "The trajectory archive is malformed or incomplete."
        case .invalidRecordingInfo:
            return "The RGB recording metadata is malformed or incomplete."
        case .noDeclaredProducer:
            return "No completed capture producer was declared for export."
        case .invalidIntegrityEnvelope:
            return "The capture integrity envelope is incomplete or ambiguous."
        case .destinationAlreadyExists:
            return "A completed capture package already exists at the destination."
        case .packageWriteFailed(let underlying, let partialURL):
            return "Capture package creation did not complete. The non-shareable partial is preserved at \(partialURL.lastPathComponent): \(underlying.localizedDescription)"
        }
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(
        _ value: T
    ) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) {
            append(contentsOf: $0)
        }
    }
}
