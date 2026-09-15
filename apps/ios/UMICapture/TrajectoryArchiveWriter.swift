import Foundation

final class TrajectoryArchiveWriter {
    private let queue = DispatchQueue(
        label: "com.umicapture.trajectory-archive-writer",
        qos: .utility
    )
    private let trajectoriesDirectoryURL: URL

    init(documentsDirectoryURL: URL) {
        trajectoriesDirectoryURL = documentsDirectoryURL
            .appendingPathComponent("CaptureLibrary", isDirectory: true)
            .appendingPathComponent("Trajectories", isDirectory: true)
    }

    func write(
        _ archive: TrajectoryArchive,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        queue.async {
            do {
                try FileManager.default.createDirectory(
                    at: self.trajectoriesDirectoryURL,
                    withIntermediateDirectories: true
                )
                let fileName = [
                    CaptureLibraryDate.fileTimestamp(
                        archive.startedAtUnixMs
                    ),
                    "--",
                    CaptureLibraryDate.fileTimestamp(
                        archive.endedAtUnixMs
                    ),
                    "_",
                    archive.recordingID,
                    "_trajectory.json"
                ].joined()
                let destinationURL = self.trajectoriesDirectoryURL
                    .appendingPathComponent(fileName)
                let temporaryURL = self.trajectoriesDirectoryURL
                    .appendingPathComponent(
                        ".\(archive.recordingID).writing"
                    )

                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(archive)
                try? FileManager.default.removeItem(at: temporaryURL)
                try data.write(to: temporaryURL, options: .atomic)

                if FileManager.default.fileExists(
                    atPath: destinationURL.path
                ) {
                    _ = try FileManager.default.replaceItemAt(
                        destinationURL,
                        withItemAt: temporaryURL
                    )
                } else {
                    try FileManager.default.moveItem(
                        at: temporaryURL,
                        to: destinationURL
                    )
                }
                completion(.success(destinationURL))
            } catch {
                completion(.failure(error))
            }
        }
    }
}
