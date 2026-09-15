import Combine
import Foundation

final class CaptureLibrary: ObservableObject {
    static let shared = CaptureLibrary()

    @Published private(set) var trajectories: [TrajectoryCaptureRecord] = []
    @Published private(set) var rgbVideos: [RGBCaptureRecord] = []
    @Published private(set) var exportPackages: [CaptureExportPackageRecord] = []
    @Published private(set) var exportRecovery: [CaptureExportRecoveryRecord] = []
    @Published private(set) var diagnosticErrors: [String] = []

    private let ioQueue = DispatchQueue(
        label: "com.umicapture.capture-library",
        qos: .utility
    )
    private let documentsDirectoryURL: URL
    private let trajectoriesDirectoryURL: URL
    private let rgbCapturesDirectoryURL: URL
    private let exportPackagesDirectoryURL: URL
    private let exportPackageIndex: CaptureExportPackageIndex
    private let trajectoryWriter: TrajectoryArchiveWriter

    init(documentsDirectoryURL: URL? = nil) {
        let resolvedDocumentsURL =
            documentsDirectoryURL
            ?? Self.defaultDocumentsDirectoryURL()
        self.documentsDirectoryURL = resolvedDocumentsURL
        trajectoriesDirectoryURL = resolvedDocumentsURL
            .appendingPathComponent("CaptureLibrary", isDirectory: true)
            .appendingPathComponent("Trajectories", isDirectory: true)
        rgbCapturesDirectoryURL = resolvedDocumentsURL
            .appendingPathComponent("RGBCaptures", isDirectory: true)
        let packagesDirectoryURL = resolvedDocumentsURL
            .appendingPathComponent("CaptureExportPackages", isDirectory: true)
        exportPackagesDirectoryURL = packagesDirectoryURL
        let preexistingWriting = CaptureExportPackageIndex
            .capturePreexistingWritingIdentities(
                directoryURL: packagesDirectoryURL
            )
        exportPackageIndex = CaptureExportPackageIndex(
            directoryURL: packagesDirectoryURL,
            preexistingWritingIdentities: preexistingWriting
        )
        trajectoryWriter = TrajectoryArchiveWriter(
            documentsDirectoryURL: resolvedDocumentsURL
        )
        refresh()
    }

    func archiveTrajectory(
        samples: [TrajectoryPoseSample],
        startedAtUnixMs: Int64,
        endedAtUnixMs: Int64,
        captureProfile: CaptureProfileSnapshot? = nil,
        captureCoordination: ActiveCaptureCoordination? = nil,
        completion: ((TrajectoryCaptureRecord?) -> Void)? = nil
    ) {
        guard !samples.isEmpty else {
            DispatchQueue.main.async {
                completion?(nil)
            }
            return
        }

        let archive = TrajectoryArchive(
            recordingID: UUID(),
            startedAtUnixMs: startedAtUnixMs,
            endedAtUnixMs: endedAtUnixMs,
            samples: samples,
            captureProfile: captureProfile,
            captureCoordination: captureCoordination
        )
        trajectoryWriter.write(archive) { [weak self] result in
            guard let self else {
                DispatchQueue.main.async {
                    completion?(nil)
                }
                return
            }
            self.ioQueue.async {
                var extraErrors: [String] = []
                if case .failure(let error) = result {
                    extraErrors.append(
                        "Trajectory archive failed: "
                            + error.localizedDescription
                    )
                }
                let snapshot = self.loadSnapshot(
                    additionalErrors: extraErrors
                )
                let record = snapshot.trajectories.first {
                    $0.id == archive.recordingID
                }
                self.publish(snapshot)
                DispatchQueue.main.async {
                    completion?(record)
                }
            }
        }
    }

    func registerFinalizedRGB(
        videoURL: URL,
        completion: ((RGBCaptureRecord?) -> Void)? = nil
    ) {
        ioQueue.async { [weak self] in
            guard let self else {
                DispatchQueue.main.async {
                    completion?(nil)
                }
                return
            }

            let directoryURL = videoURL.deletingLastPathComponent()
            var errors: [String] = []
            guard self.isDirectChild(
                directoryURL,
                of: self.rgbCapturesDirectoryURL
            ) else {
                errors.append(
                    "Ignored RGB file outside the app capture directory: "
                        + videoURL.lastPathComponent
                )
                let snapshot = self.loadSnapshot(
                    additionalErrors: errors
                )
                self.publish(snapshot)
                DispatchQueue.main.async {
                    completion?(nil)
                }
                return
            }

            let infoURL = directoryURL.appendingPathComponent(
                "recording_info.json"
            )
            guard videoURL.lastPathComponent == "rgb.mp4",
                  FileManager.default.fileExists(atPath: videoURL.path),
                  FileManager.default.fileExists(atPath: infoURL.path)
            else {
                errors.append(
                    "RGB segment was not registered because its MP4 "
                        + "or metadata is incomplete."
                )
                let snapshot = self.loadSnapshot(
                    additionalErrors: errors
                )
                self.publish(snapshot)
                DispatchQueue.main.async {
                    completion?(nil)
                }
                return
            }

            let snapshot = self.loadSnapshot(
                additionalErrors: errors
            )
            let record = snapshot.rgbVideos.first {
                $0.videoURL.standardizedFileURL
                    == videoURL.standardizedFileURL
            }
            self.publish(snapshot)
            DispatchQueue.main.async {
                completion?(record)
            }
        }
    }

    func refresh(completion: (() -> Void)? = nil) {
        ioQueue.async { [weak self] in
            guard let self else {
                DispatchQueue.main.async {
                    completion?()
                }
                return
            }
            self.publish(self.loadSnapshot())
            DispatchQueue.main.async {
                completion?()
            }
        }
    }

    func deleteTrajectory(
        _ record: TrajectoryCaptureRecord,
        completion: (() -> Void)? = nil
    ) {
        ioQueue.async { [weak self] in
            guard let self else {
                return
            }
            var errors: [String] = []
            do {
                guard self.isDirectChild(
                    record.fileURL,
                    of: self.trajectoriesDirectoryURL
                ) else {
                    throw CaptureLibraryError.unsafePath
                }
                if FileManager.default.fileExists(
                    atPath: record.fileURL.path
                ) {
                    try FileManager.default.removeItem(
                        at: record.fileURL
                    )
                }
            } catch {
                errors.append(
                    "Could not delete trajectory: "
                        + error.localizedDescription
                )
            }
            self.publish(self.loadSnapshot(additionalErrors: errors))
            DispatchQueue.main.async {
                completion?()
            }
        }
    }

    func deleteRGBVideo(
        _ record: RGBCaptureRecord,
        completion: (() -> Void)? = nil
    ) {
        ioQueue.async { [weak self] in
            guard let self else {
                return
            }
            var errors: [String] = []
            do {
                guard self.isDirectChild(
                    record.directoryURL,
                    of: self.rgbCapturesDirectoryURL
                ) else {
                    throw CaptureLibraryError.unsafePath
                }
                if FileManager.default.fileExists(
                    atPath: record.directoryURL.path
                ) {
                    try FileManager.default.removeItem(
                        at: record.directoryURL
                    )
                }
            } catch {
                errors.append(
                    "Could not delete RGB capture: "
                        + error.localizedDescription
                )
            }
            self.publish(self.loadSnapshot(additionalErrors: errors))
            DispatchQueue.main.async {
                completion?()
            }
        }
    }

    func deleteAllTrajectories(
        completion: (() -> Void)? = nil
    ) {
        ioQueue.async { [weak self] in
            guard let self else {
                return
            }
            var errors: [String] = []
            let records = self.loadTrajectories(errors: &errors)
            for record in records {
                do {
                    guard self.isDirectChild(
                        record.fileURL,
                        of: self.trajectoriesDirectoryURL
                    ) else {
                        throw CaptureLibraryError.unsafePath
                    }
                    try FileManager.default.removeItem(
                        at: record.fileURL
                    )
                } catch {
                    errors.append(
                        "Could not delete trajectory "
                            + "\(record.fileURL.lastPathComponent): "
                            + error.localizedDescription
                    )
                }
            }
            self.publish(self.loadSnapshot(additionalErrors: errors))
            DispatchQueue.main.async {
                completion?()
            }
        }
    }

    func deleteAllRGBVideos(
        completion: (() -> Void)? = nil
    ) {
        ioQueue.async { [weak self] in
            guard let self else {
                return
            }
            var errors: [String] = []
            let records = self.loadRGBVideos(errors: &errors)
            for record in records {
                do {
                    guard self.isDirectChild(
                        record.directoryURL,
                        of: self.rgbCapturesDirectoryURL
                    ) else {
                        throw CaptureLibraryError.unsafePath
                    }
                    try FileManager.default.removeItem(
                        at: record.directoryURL
                    )
                } catch {
                    errors.append(
                        "Could not delete RGB capture "
                            + "\(record.directoryURL.lastPathComponent): "
                            + error.localizedDescription
                    )
                }
            }
            self.publish(self.loadSnapshot(additionalErrors: errors))
            DispatchQueue.main.async {
                completion?()
            }
        }
    }

    func deleteAllCaptures(
        completion: (() -> Void)? = nil
    ) {
        ioQueue.async { [weak self] in
            guard let self else {
                return
            }
            var errors: [String] = []
            let trajectories = self.loadTrajectories(
                errors: &errors
            )
            let rgbVideos = self.loadRGBVideos(errors: &errors)

            for record in trajectories {
                do {
                    guard self.isDirectChild(
                        record.fileURL,
                        of: self.trajectoriesDirectoryURL
                    ) else {
                        throw CaptureLibraryError.unsafePath
                    }
                    try FileManager.default.removeItem(
                        at: record.fileURL
                    )
                } catch {
                    errors.append(
                        "Could not delete trajectory "
                            + "\(record.fileURL.lastPathComponent): "
                            + error.localizedDescription
                    )
                }
            }
            for record in rgbVideos {
                do {
                    guard self.isDirectChild(
                        record.directoryURL,
                        of: self.rgbCapturesDirectoryURL
                    ) else {
                        throw CaptureLibraryError.unsafePath
                    }
                    try FileManager.default.removeItem(
                        at: record.directoryURL
                    )
                } catch {
                    errors.append(
                        "Could not delete RGB capture "
                            + "\(record.directoryURL.lastPathComponent): "
                            + error.localizedDescription
                    )
                }
            }
            self.publish(self.loadSnapshot(additionalErrors: errors))
            DispatchQueue.main.async {
                completion?()
            }
        }
    }

    func deleteExportPackage(
        _ record: CaptureExportPackageRecord,
        completion: ((Bool) -> Void)? = nil
    ) {
        deleteExportFile(
            url: record.fileURL,
            identity: record.identity,
            isEligible: true,
            completion: completion
        )
    }

    func deleteExportRecovery(
        _ record: CaptureExportRecoveryRecord,
        completion: ((Bool) -> Void)? = nil
    ) {
        deleteExportFile(
            url: record.fileURL,
            identity: record.identity,
            isEligible: record.isDeletionEligible,
            completion: completion
        )
    }

    private func deleteExportFile(
        url: URL,
        identity: CaptureFileIdentity,
        isEligible: Bool,
        completion: ((Bool) -> Void)?
    ) {
        ioQueue.async { [weak self] in
            guard let self else { return }
            var errors: [String] = []
            var removed = false
            if isEligible,
               CaptureExportPackageIndex.identityStillMatches(
                   url: url,
                   expected: identity,
                   directoryURL: self.exportPackagesDirectoryURL
               ) {
                do {
                    try FileManager.default.removeItem(at: url)
                    removed = true
                } catch {
                    errors.append(
                        "Could not delete export package \(url.lastPathComponent): "
                            + error.localizedDescription
                    )
                }
            } else {
                errors.append(
                    "Export package changed or is not deletion-eligible: "
                        + url.lastPathComponent
                )
            }
            self.publish(self.loadSnapshot(additionalErrors: errors))
            DispatchQueue.main.async { completion?(removed) }
        }
    }

    private func loadSnapshot(
        additionalErrors: [String] = []
    ) -> LibrarySnapshot {
        var errors = additionalErrors
        let packageSnapshot = exportPackageIndex.scan()
        errors.append(contentsOf: packageSnapshot.diagnostics)
        return LibrarySnapshot(
            trajectories: loadTrajectories(errors: &errors),
            rgbVideos: loadRGBVideos(errors: &errors),
            exportPackages: packageSnapshot.completed,
            exportRecovery: packageSnapshot.recovery,
            errors: errors
        )
    }

    private func loadTrajectories(
        errors: inout [String]
    ) -> [TrajectoryCaptureRecord] {
        do {
            try FileManager.default.createDirectory(
                at: trajectoriesDirectoryURL,
                withIntermediateDirectories: true
            )
            let urls = try FileManager.default.contentsOfDirectory(
                at: trajectoriesDirectoryURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            let decoder = JSONDecoder()
            return urls
                .filter {
                    $0.pathExtension.lowercased() == "json"
                }
                .compactMap { url in
                    do {
                        let archive = try decoder.decode(
                            TrajectoryArchive.self,
                            from: Data(contentsOf: url)
                        )
                        guard (1...2).contains(
                                  archive.schemaVersion
                              ),
                              archive.kind == "trajectory",
                              archive.pointCount
                                == archive.samples.count,
                              archive.poseSamples != nil
                        else {
                            throw CaptureLibraryError
                                .invalidTrajectoryArchive
                        }
                        return TrajectoryCaptureRecord(
                            id: archive.recordingID,
                            archive: archive,
                            fileURL: url
                        )
                    } catch {
                        errors.append(
                            "Skipped damaged trajectory "
                                + "\(url.lastPathComponent): "
                                + error.localizedDescription
                        )
                        return nil
                    }
                }
                .sorted {
                    $0.archive.endedAtUnixMs
                        > $1.archive.endedAtUnixMs
                }
        } catch {
            errors.append(
                "Could not read trajectory library: "
                    + error.localizedDescription
            )
            return []
        }
    }

    private func loadRGBVideos(
        errors: inout [String]
    ) -> [RGBCaptureRecord] {
        do {
            try FileManager.default.createDirectory(
                at: rgbCapturesDirectoryURL,
                withIntermediateDirectories: true
            )
            let directoryURLs = try FileManager.default
                .contentsOfDirectory(
                    at: rgbCapturesDirectoryURL,
                    includingPropertiesForKeys: [
                        .isDirectoryKey,
                        .contentModificationDateKey
                    ],
                    options: [.skipsHiddenFiles]
                )
            let decoder = JSONDecoder()
            return directoryURLs.compactMap { directoryURL in
                do {
                    guard isDirectChild(
                        directoryURL,
                        of: rgbCapturesDirectoryURL
                    ) else {
                        throw CaptureLibraryError.unsafePath
                    }
                    let values = try directoryURL.resourceValues(
                        forKeys: [
                            .isDirectoryKey,
                            .contentModificationDateKey
                        ]
                    )
                    guard values.isDirectory == true else {
                        return nil
                    }
                    let videoURL = directoryURL.appendingPathComponent(
                        "rgb.mp4"
                    )
                    let infoURL = directoryURL.appendingPathComponent(
                        "recording_info.json"
                    )
                    guard FileManager.default.fileExists(
                        atPath: videoURL.path
                    ),
                    FileManager.default.fileExists(atPath: infoURL.path)
                    else {
                        throw CaptureLibraryError.incompleteRGBCapture
                    }
                    let videoValues = try videoURL.resourceValues(
                        forKeys: [.fileSizeKey]
                    )
                    guard (videoValues.fileSize ?? 0) > 0 else {
                        throw CaptureLibraryError.emptyVideo
                    }
                    let info = try decoder.decode(
                        RGBRecordingInfo.self,
                        from: Data(contentsOf: infoURL)
                    )
                    guard info.recordingUUID
                            == directoryURL.lastPathComponent
                    else {
                        throw CaptureLibraryError
                            .mismatchedRecordingUUID
                    }

                    let fallbackUnixMs = CaptureLibraryDate
                        .unixMilliseconds(
                            values.contentModificationDate ?? Date()
                        )
                    let startUnixMs =
                        info.startedAtUnixMs ?? fallbackUnixMs
                    let endUnixMs =
                        info.endedAtUnixMs ?? fallbackUnixMs
                    return RGBCaptureRecord(
                        id: info.recordingUUID,
                        info: info,
                        directoryURL: directoryURL,
                        videoURL: videoURL,
                        infoURL: infoURL,
                        displayName: info.displayName
                            ?? CaptureLibraryDate.displayRange(
                                startUnixMs: startUnixMs,
                                endUnixMs: endUnixMs
                            ),
                        sortTimestampUnixMs: endUnixMs
                    )
                } catch CaptureLibraryError.incompleteRGBCapture {
                    errors.append(
                        "Skipped incomplete RGB capture "
                            + "\(directoryURL.lastPathComponent): "
                            + CaptureLibraryError.incompleteRGBCapture
                                .localizedDescription
                    )
                    return nil
                } catch {
                    errors.append(
                        "Skipped damaged RGB capture "
                            + "\(directoryURL.lastPathComponent): "
                            + error.localizedDescription
                    )
                    return nil
                }
            }
            .sorted {
                $0.sortTimestampUnixMs > $1.sortTimestampUnixMs
            }
        } catch {
            errors.append(
                "Could not read RGB library: "
                    + error.localizedDescription
            )
            return []
        }
    }

    private func publish(_ snapshot: LibrarySnapshot) {
        DispatchQueue.main.async { [weak self] in
            self?.trajectories = snapshot.trajectories
            self?.rgbVideos = snapshot.rgbVideos
            self?.exportPackages = snapshot.exportPackages
            self?.exportRecovery = snapshot.exportRecovery
            self?.diagnosticErrors = snapshot.errors
        }
    }

    private func isDirectChild(
        _ candidateURL: URL,
        of rootURL: URL
    ) -> Bool {
        let candidate = candidateURL.standardizedFileURL
            .resolvingSymlinksInPath()
        let root = rootURL.standardizedFileURL
            .resolvingSymlinksInPath()
        return candidate != root
            && candidate.deletingLastPathComponent() == root
    }

    private static func defaultDocumentsDirectoryURL() -> URL {
        do {
            return try FileManager.default.url(
                for: .documentDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
        } catch {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "UMICapture-Documents-Fallback",
                    isDirectory: true
                )
        }
    }
}

private struct LibrarySnapshot {
    let trajectories: [TrajectoryCaptureRecord]
    let rgbVideos: [RGBCaptureRecord]
    let exportPackages: [CaptureExportPackageRecord]
    let exportRecovery: [CaptureExportRecoveryRecord]
    let errors: [String]
}

private enum CaptureLibraryError: LocalizedError {
    case invalidTrajectoryArchive
    case incompleteRGBCapture
    case mismatchedRecordingUUID
    case emptyVideo
    case unsafePath

    var errorDescription: String? {
        switch self {
        case .invalidTrajectoryArchive:
            return "The trajectory JSON has inconsistent fields."
        case .incompleteRGBCapture:
            return "The finalized MP4 or its metadata is missing."
        case .mismatchedRecordingUUID:
            return "The metadata UUID does not match its directory."
        case .emptyVideo:
            return "The finalized MP4 is empty."
        case .unsafePath:
            return "The requested file is outside the managed directory."
        }
    }
}
