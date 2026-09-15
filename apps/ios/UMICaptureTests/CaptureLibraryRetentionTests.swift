import Foundation
import XCTest
@testable import UMICapture

final class CaptureLibraryRetentionTests: XCTestCase {
    private var documentsURL: URL!

    override func setUpWithError() throws {
        documentsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "UMICapture-Retention-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: documentsURL,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let documentsURL {
            try? FileManager.default.removeItem(at: documentsURL)
        }
        documentsURL = nil
    }

    func testFiveTrajectoriesSurviveRefreshAndReload() throws {
        let urls = try (0..<5).map(makeTrajectory)

        let library = CaptureLibrary(
            documentsDirectoryURL: documentsURL
        )
        waitForRefresh(library, label: "initial trajectory refresh")
        assertTrajectoryOrder(library, expectedCount: 5)

        waitForRefresh(library, label: "second trajectory refresh")
        assertTrajectoryOrder(library, expectedCount: 5)

        let reloaded = CaptureLibrary(
            documentsDirectoryURL: documentsURL
        )
        waitForRefresh(reloaded, label: "trajectory reload")
        assertTrajectoryOrder(reloaded, expectedCount: 5)
        XCTAssertTrue(urls.allSatisfy {
            FileManager.default.fileExists(atPath: $0.path)
        })
    }

    func testFiveFinalizedRGBRecordsSurviveRefreshAndReload() throws {
        let videoURLs = try (0..<5).map(makeRGBSegment)

        let library = CaptureLibrary(
            documentsDirectoryURL: documentsURL
        )
        waitForRefresh(library, label: "initial RGB refresh")
        assertRGBOrder(library, expectedCount: 5)

        waitForRefresh(library, label: "second RGB refresh")
        assertRGBOrder(library, expectedCount: 5)

        let reloaded = CaptureLibrary(
            documentsDirectoryURL: documentsURL
        )
        waitForRefresh(reloaded, label: "RGB reload")
        assertRGBOrder(reloaded, expectedCount: 5)
        XCTAssertTrue(videoURLs.allSatisfy {
            FileManager.default.fileExists(atPath: $0.path)
        })
    }

    func testIncompleteAndCorruptArtifactsRemainButAreNotCompleted() throws {
        let trajectoryDirectory = documentsURL
            .appendingPathComponent(
                "CaptureLibrary/Trajectories",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: trajectoryDirectory,
            withIntermediateDirectories: true
        )
        let damagedTrajectoryURL = trajectoryDirectory
            .appendingPathComponent("damaged.json")
        try Data("{ damaged".utf8).write(to: damagedTrajectoryURL)

        let incompleteRGBDirectory = documentsURL
            .appendingPathComponent("RGBCaptures", isDirectory: true)
            .appendingPathComponent("incomplete-rgb", isDirectory: true)
        try FileManager.default.createDirectory(
            at: incompleteRGBDirectory,
            withIntermediateDirectories: true
        )
        let incompleteVideoURL = incompleteRGBDirectory
            .appendingPathComponent("rgb.mp4")
        try Data([0, 1, 2, 3]).write(to: incompleteVideoURL)

        let emptyVideoURL = try makeRGBSegment(index: 6)
        try Data().write(to: emptyVideoURL)

        let mismatchedVideoURL = try makeRGBSegment(index: 7)
        let mismatchedInfoURL = mismatchedVideoURL
            .deletingLastPathComponent()
            .appendingPathComponent("recording_info.json")
        try JSONEncoder().encode(
            makeRGBInfo(recordingUUID: "different-recording", index: 7)
        ).write(to: mismatchedInfoURL)

        let corruptMetadataVideoURL = try makeRGBSegment(index: 8)
        let corruptInfoURL = corruptMetadataVideoURL
            .deletingLastPathComponent()
            .appendingPathComponent("recording_info.json")
        try Data("{ corrupt".utf8).write(to: corruptInfoURL)

        let library = CaptureLibrary(
            documentsDirectoryURL: documentsURL
        )
        waitForRefresh(library, label: "incomplete refresh")

        XCTAssertTrue(library.trajectories.isEmpty)
        XCTAssertTrue(library.rgbVideos.isEmpty)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: damagedTrajectoryURL.path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: incompleteVideoURL.path
            )
        )
        for retainedURL in [
            emptyVideoURL,
            mismatchedVideoURL,
            mismatchedInfoURL,
            corruptMetadataVideoURL,
            corruptInfoURL
        ] {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: retainedURL.path)
            )
        }
        XCTAssertTrue(library.diagnosticErrors.contains {
            $0.contains("Skipped damaged trajectory")
        })
        XCTAssertTrue(library.diagnosticErrors.contains {
            $0.contains("Skipped incomplete RGB capture")
        })
        for identifier in ["rgb-6", "rgb-7", "rgb-8"] {
            XCTAssertTrue(library.diagnosticErrors.contains {
                $0.contains("Skipped damaged RGB capture \(identifier)")
            })
        }
    }

    func testExplicitManualDeleteRemovesOnlySelectedRecord() throws {
        let urls = try (0..<2).map(makeTrajectory)
        let library = CaptureLibrary(
            documentsDirectoryURL: documentsURL
        )
        waitForRefresh(library, label: "manual delete setup")
        XCTAssertEqual(library.trajectories.count, 2)

        let selected = try XCTUnwrap(library.trajectories.first)
        let deletion = expectation(description: "explicit trajectory delete")
        library.deleteTrajectory(selected) {
            deletion.fulfill()
        }
        wait(for: [deletion], timeout: 3)

        XCTAssertEqual(library.trajectories.count, 1)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: selected.fileURL.path)
        )
        XCTAssertEqual(
            urls.filter {
                FileManager.default.fileExists(atPath: $0.path)
            }.count,
            1
        )
    }

    func testSourceHasNoAutomaticRetentionOrImmediateSwipeDeletion() throws {
        let repositoryURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let librarySource = try String(
            contentsOf: repositoryURL
                .appendingPathComponent("UMICapture/CaptureLibrary.swift"),
            encoding: .utf8
        )
        let viewSource = try String(
            contentsOf: repositoryURL
                .appendingPathComponent("UMICapture/RecentCapturesView.swift"),
            encoding: .utf8
        )

        for forbidden in [
            "maximumRecordCount",
            "loadAndTrim",
            "trimTrajectories",
            "trimRGBVideos",
            "dropFirst(maximumRecordCount)"
        ] {
            XCTAssertFalse(
                librarySource.contains(forbidden),
                "Unexpected automatic retention path: \(forbidden)"
            )
        }
        XCTAssertFalse(viewSource.contains(" / 3"))
        XCTAssertTrue(viewSource.contains("pendingDeletion"))
        XCTAssertTrue(viewSource.contains(".alert("))
        XCTAssertTrue(
            viewSource.contains(
                "pendingDeletion =\n"
                    + "                                            .trajectory(record)"
            )
        )
        XCTAssertTrue(
            viewSource.contains(
                "pendingDeletion =\n"
                    + "                                            .rgbVideo(record)"
            )
        )
        XCTAssertTrue(viewSource.contains("role: .cancel"))
        XCTAssertTrue(viewSource.contains("performPendingDeletion()"))
    }

    func testTrajectoryModelKeepsCameraPosesDeviceLocal() throws {
        let repositoryURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryURL.appendingPathComponent(
                "UMICapture/CaptureLibraryModels.swift"
            ),
            encoding: .utf8
        )

        for forbidden in [
            "sharedBoardDisplayFrame",
            "sharedWorldCalibration",
            "initialTCPDisplayFrame",
            "cameraTTCP",
            "tcpOriginSamplesInDisplayFrame"
        ] {
            XCTAssertFalse(source.contains(forbidden), forbidden)
        }
        XCTAssertTrue(
            source.contains("? Self.physicalTCPDisplayFrame")
        )
        XCTAssertTrue(source.contains(": Self.robotDisplayFrame"))
    }

    func testConfirmationUsesOneTypedSurfaceWithVisibleCancel() throws {
        let repositoryURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let viewSource = try String(
            contentsOf: repositoryURL
                .appendingPathComponent("UMICapture/RecentCapturesView.swift"),
            encoding: .utf8
        )

        XCTAssertEqual(
            viewSource.components(separatedBy: ".alert(").count - 1,
            1
        )
        XCTAssertFalse(viewSource.contains(".confirmationDialog("))
        XCTAssertTrue(
            viewSource.contains(
                "@State private var pendingDeletion: CaptureDeletion?"
            )
        )
        XCTAssertFalse(viewSource.contains("pendingCaptureDeletion"))
        XCTAssertFalse(viewSource.contains("pendingBulkDeletion"))
        for captureCase in [
            "case trajectory(TrajectoryCaptureRecord)",
            "case rgbVideo(RGBCaptureRecord)",
            "case allTrajectories",
            "case allRGBVideos",
            "case allCaptures"
        ] {
            XCTAssertTrue(viewSource.contains(captureCase), captureCase)
        }
        XCTAssertTrue(viewSource.contains("role: .destructive"))
        XCTAssertTrue(viewSource.contains("role: .cancel"))
        XCTAssertTrue(
            viewSource.contains("language.text(\"Cancel\", \"取消\")")
        )
        XCTAssertTrue(viewSource.contains("performPendingDeletion()"))

        let dispatcher = try XCTUnwrap(
            viewSource.range(of: "    private func performPendingDeletion()")
        )
        let presentationSource = viewSource[..<dispatcher.lowerBound]
        XCTAssertFalse(presentationSource.contains("library.delete"))
    }

    private func makeTrajectory(index: Int) throws -> URL {
        let directoryURL = documentsURL
            .appendingPathComponent(
                "CaptureLibrary/Trajectories",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        let archive = TrajectoryArchive(
            recordingID: UUID(),
            startedAtUnixMs: Int64(1_000 + index * 1_000),
            endedAtUnixMs: Int64(1_500 + index * 1_000),
            samples: [
                TrajectoryPoseSample(
                    position: SIMD3<Float>(Float(index), 0, 0),
                    cameraForward: SIMD3<Float>(0, 0, -1),
                    elapsedTimeSeconds: 0,
                    orientationXYZW: SIMD4<Float>(0, 0, 0, 1)
                )
            ]
        )
        let url = directoryURL.appendingPathComponent(
            "\(archive.recordingID)_trajectory.json"
        )
        try JSONEncoder().encode(archive).write(to: url)
        return url
    }

    private func makeRGBSegment(index: Int) throws -> URL {
        let recordingUUID = "rgb-\(index)"
        let directoryURL = documentsURL
            .appendingPathComponent("RGBCaptures", isDirectory: true)
            .appendingPathComponent(recordingUUID, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )

        let videoURL = directoryURL.appendingPathComponent("rgb.mp4")
        try Data([0, 1, 2, 3]).write(to: videoURL)
        let info = makeRGBInfo(
            recordingUUID: recordingUUID,
            index: index
        )
        try JSONEncoder().encode(info).write(
            to: directoryURL.appendingPathComponent(
                "recording_info.json"
            )
        )
        return videoURL
    }

    private func makeRGBInfo(
        recordingUUID: String,
        index: Int
    ) -> RGBRecordingInfo {
        let start = Int64(1_000 + index * 1_000)
        let end = Int64(1_500 + index * 1_000)
        return RGBRecordingInfo(
            schemaVersion: 1,
            recordingUUID: recordingUUID,
            width: 1920,
            height: 1440,
            nominalFPS: 60,
            codec: "HEVC/H.265",
            container: "MP4",
            encodedFrameCount: 100,
            droppedFrameCount: 0,
            finishReason: "stop",
            firstFrameCameraIntrinsics: nil,
            displayName: CaptureLibraryDate.displayRange(
                startUnixMs: start,
                endUnixMs: end
            ),
            startedAtUnixMs: start,
            endedAtUnixMs: end,
            dataKey: nil,
            cameraRole: nil,
            iPhoneModel: nil,
            lensMode: nil,
            physicalCameraType: nil,
            fixedInterfaceOrientation: nil,
            captureStartInterfaceOrientation: nil,
            empiricalCalibration: nil,
            umiPreprocessing: nil,
            umiVideoFilename: nil,
            framesMetadataFilename: nil,
            umiEncodedFrameCount: nil,
            umiDroppedFrameCount: nil,
            firstFrameUMI224Intrinsics: nil
        )
    }

    private func waitForRefresh(
        _ library: CaptureLibrary,
        label: String
    ) {
        let refreshed = expectation(description: label)
        library.refresh {
            refreshed.fulfill()
        }
        wait(for: [refreshed], timeout: 3)
    }

    private func assertTrajectoryOrder(
        _ library: CaptureLibrary,
        expectedCount: Int
    ) {
        XCTAssertEqual(library.trajectories.count, expectedCount)
        XCTAssertEqual(
            library.trajectories.map(\.archive.endedAtUnixMs),
            [5_500, 4_500, 3_500, 2_500, 1_500]
        )
    }

    private func assertRGBOrder(
        _ library: CaptureLibrary,
        expectedCount: Int
    ) {
        XCTAssertEqual(library.rgbVideos.count, expectedCount)
        XCTAssertEqual(
            library.rgbVideos.map(\.sortTimestampUnixMs),
            [5_500, 4_500, 3_500, 2_500, 1_500]
        )
    }
}
