import CryptoKit
import Foundation
import XCTest
@testable import UMICapture

final class CaptureExportIntegrityTests: XCTestCase {
    private var rootURL: URL!
    private let fixedProvenance = SoftwareProvenance(
        schemaVersion: 2,
        appName: "UMI Capture",
        marketingVersion: "1.2.3",
        buildNumber: "456",
        bundleIdentifier: "com.example.UMICapture.tests",
        developer: "Xinrui Xiong",
        acknowledgements: [
            "Universal Manipulation Interface",
            "UMI on Legs",
            "iPhUMI",
            "iPhoneVIO"
        ]
    )

    override func setUpWithError() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "UMICapture-Export-Integrity-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let rootURL {
            try? FileManager.default.removeItem(at: rootURL)
        }
        rootURL = nil
    }

    func testMissingRequiredFramesFailsClosed() throws {
        let videoURL = try makeRGBSegment(
            id: "missing-frames",
            includeFrames: false
        )
        let result = build(rgbVideoURLs: [videoURL])

        guard case .failure = result else {
            return XCTFail("Missing frames.jsonl must fail closed.")
        }
        XCTAssertTrue(finalZIPURLs().isEmpty)
    }

    func testSoftwareProvenanceProvidesCompatibleClientMetadata() {
        let metadata = fixedProvenance.clientMetadata

        XCTAssertEqual(metadata["schema_version"] as? Int, 2)
        XCTAssertEqual(metadata["app_name"] as? String, "UMI Capture")
        XCTAssertEqual(metadata["marketing_version"] as? String, "1.2.3")
        XCTAssertEqual(metadata["build_number"] as? String, "456")
        XCTAssertEqual(
            metadata["bundle_identifier"] as? String,
            "com.example.UMICapture.tests"
        )
    }

    func testCompletedPackageDeclaresIntegrityEnvelope() throws {
        let trajectoryURL = try makeTrajectory(id: "complete")
        let videoURL = try makeRGBSegment(id: "complete")
        let result = build(
            trajectoryURL: trajectoryURL,
            rgbVideoURLs: [videoURL],
            softwareProvenance: fixedProvenance
        )
        let package = try result.get()
        let entries = try ZIPEntries.read(package.fileURL)
        let manifestData = try XCTUnwrap(
            entries["capture_manifest.json"]
        )
        let manifest = try XCTUnwrap(
            JSONSerialization.jsonObject(with: manifestData)
                as? [String: Any]
        )

        XCTAssertEqual(manifest["schema_version"] as? Int, 1)
        XCTAssertEqual(
            manifest["kind"] as? String,
            "iphonevio_capture_export"
        )
        XCTAssertEqual(manifest["completion_state"] as? String, "completed")
        XCTAssertEqual(manifest["integrity_schema_version"] as? Int, 1)
        let provenance = try XCTUnwrap(
            manifest["software_provenance"] as? [String: Any]
        )
        XCTAssertEqual(provenance["schema_version"] as? Int, 2)
        XCTAssertEqual(provenance["app_name"] as? String, "UMI Capture")
        XCTAssertEqual(provenance["marketing_version"] as? String, "1.2.3")
        XCTAssertEqual(provenance["build_number"] as? String, "456")
        XCTAssertEqual(
            provenance["bundle_identifier"] as? String,
            "com.example.UMICapture.tests"
        )
        XCTAssertEqual(
            provenance["developer"] as? String,
            "Xinrui Xiong"
        )
        XCTAssertEqual(
            provenance["acknowledgements"] as? [String],
            [
                "Universal Manipulation Interface",
                "UMI on Legs",
                "iPhUMI",
                "iPhoneVIO"
            ]
        )
        let selection = try XCTUnwrap(
            manifest["export_selection"] as? [String: Any]
        )
        XCTAssertNil(selection["include_depth_observation"])
        let readme = try XCTUnwrap(
            String(data: try XCTUnwrap(entries["README.txt"]), encoding: .utf8)
        )
        for expected in [
            "Software: UMI Capture 1.2.3 (build 456)",
            "Bundle identifier: com.example.UMICapture.tests",
            SoftwareProvenance.aboutDescription,
            "Developer: Xinrui Xiong",
            "Inspired by: Universal Manipulation Interface, UMI on Legs, iPhUMI, iPhoneVIO",
            "Feedback/debug: https://github.com/xx3-bot/umi-capture/issues"
        ] {
            XCTAssertTrue(readme.contains(expected), expected)
        }
        let rows = try XCTUnwrap(
            manifest["artifact_integrity"] as? [[String: Any]]
        )
        XCTAssertEqual(rows.count, entries.count - 2)
        XCTAssertEqual(
            Set(rows.compactMap { $0["path"] as? String }),
            Set(entries.keys).subtracting([
                "capture_manifest.json", "README.txt"
            ])
        )
        for row in rows {
            let path = try XCTUnwrap(row["path"] as? String)
            let data = try XCTUnwrap(entries[path])
            XCTAssertEqual(row["byte_size"] as? Int, data.count)
            XCTAssertEqual(
                row["sha256"] as? String,
                SHA256.hash(data: data).map {
                    String(format: "%02x", $0)
                }.joined()
            )
        }
        XCTAssertNil(
            manifestData.range(of: Data(rootURL.path.utf8)),
            "Shared manifest must not expose an absolute sandbox path."
        )
        let packageDigest = try CaptureArtifactIntegrity.digest(
            fileURL: package.fileURL,
            trustedRootURL: rootURL
        )
        XCTAssertEqual(package.identity.sizeBytes, packageDigest.byteSize)
        XCTAssertEqual(package.identity.sha256, packageDigest.sha256)
    }

    func testProfileNamesZIPAndPackagedVideosByRoleAndStartTime()
        throws {
        let videoURL = try makeRGBSegment(
            id: "role-naming",
            includeUMIFile: true,
            umiVideoFilename: "ego_rgb_224.mp4",
            umiEncodedFrameCount: 1,
            includeUltrawide: true
        )
        let profile = CaptureProfileSnapshot.make(
            deviceID: "device",
            profileID: .handheldUMI,
            gripperID: "gripper-a",
            calibrationID: nil,
            lockedAtLocalMonotonicNs: 1
        )
        let package = try build(
            rgbVideoURLs: [videoURL],
            outputSubdirectory: "role-naming",
            captureProfile: profile
        ).get()
        XCTAssertNotNil(
            package.fileURL.lastPathComponent.range(
                of: #"^hand_[0-9]{8}_[0-9]{6}\.zip$"#,
                options: .regularExpression
            )
        )

        let entries = try ZIPEntries.read(package.fileURL)
        let manifestData = try XCTUnwrap(
            entries["capture_manifest.json"]
        )
        let manifest = try XCTUnwrap(
            JSONSerialization.jsonObject(with: manifestData)
                as? [String: Any]
        )
        XCTAssertEqual(manifest["data_key"] as? String, "wrist_rgb")
        let workflow = try XCTUnwrap(
            manifest["recommended_workflow"] as? [String]
        )
        XCTAssertTrue(
            workflow.contains {
                $0.contains("package's wrist_rgb data_key")
            }
        )
        let fileGuide = try XCTUnwrap(
            manifest["file_guide"] as? [[String: Any]]
        )
        let processedGuide = try XCTUnwrap(
            fileGuide.first {
                ($0["path"] as? String)?.hasSuffix(
                    "_rgb_224.mp4"
                ) == true
            }
        )
        XCTAssertTrue(
            try XCTUnwrap(
                processedGuide["how_to_use"] as? String
            ).contains("Use as wrist_rgb.")
        )
        let segments = try XCTUnwrap(
            manifest["rgb_segments"] as? [[String: Any]]
        )
        let mapping = try XCTUnwrap(
            segments.first?["archive_names_by_source_name"]
                as? [String: String]
        )
        for (source, suffix) in [
            ("rgb.mp4", "_rgb.mp4"),
            ("ego_rgb_224.mp4", "_rgb_224.mp4"),
            (UltrawideRecordingWriter.videoFilename,
             "_ultrawide_rgb.mp4")
        ] {
            let packagedName = try XCTUnwrap(mapping[source])
            XCTAssertTrue(packagedName.hasPrefix("hand_"))
            XCTAssertTrue(packagedName.hasSuffix(suffix))
            XCTAssertNotNil(
                entries["rgb/segment_001/\(packagedName)"]
            )
        }
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: videoURL.path),
            "Packaging must not rename or remove the source capture."
        )

        let egoProfile = CaptureProfileSnapshot.make(
            deviceID: "device",
            profileID: .chestEGO,
            gripperID: nil,
            calibrationID: nil,
            lockedAtLocalMonotonicNs: 2
        )
        let firstEgoPackage = try build(
            rgbVideoURLs: [videoURL],
            outputSubdirectory: "role-naming-ego",
            captureProfile: egoProfile
        ).get()
        let secondEgoPackage = try build(
            rgbVideoURLs: [videoURL],
            outputSubdirectory: "role-naming-ego",
            captureProfile: egoProfile
        ).get()
        XCTAssertNotNil(
            firstEgoPackage.fileURL.lastPathComponent.range(
                of: #"^ego_[0-9]{8}_[0-9]{6}\.zip$"#,
                options: .regularExpression
            )
        )
        XCTAssertNotNil(
            secondEgoPackage.fileURL.lastPathComponent.range(
                of: #"^ego_[0-9]{8}_[0-9]{6}_2\.zip$"#,
                options: .regularExpression
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: firstEgoPackage.fileURL.path
            )
        )
        let egoEntries = try ZIPEntries.read(firstEgoPackage.fileURL)
        let egoManifestData = try XCTUnwrap(
            egoEntries["capture_manifest.json"]
        )
        let egoManifest = try XCTUnwrap(
            JSONSerialization.jsonObject(with: egoManifestData)
                as? [String: Any]
        )
        let egoSegments = try XCTUnwrap(
            egoManifest["rgb_segments"] as? [[String: Any]]
        )
        let egoMapping = try XCTUnwrap(
            egoSegments.first?["archive_names_by_source_name"]
                as? [String: String]
        )
        for source in [
            "rgb.mp4",
            "ego_rgb_224.mp4",
            UltrawideRecordingWriter.videoFilename
        ] {
            XCTAssertTrue(try XCTUnwrap(egoMapping[source]).hasPrefix("ego_"))
        }
    }

    func testExportSelectionOmitsLargeMediaWithoutDeletingSources()
        throws {
        let videoURL = try makeRGBSegment(
            id: "selection-none",
            includeUMIFile: true,
            umiVideoFilename: "ego_rgb_224.mp4",
            umiEncodedFrameCount: 1,
            includeUltrawide: true
        )
        let directoryURL = videoURL.deletingLastPathComponent()
        let protectedNames = [
            "rgb.mp4",
            "ego_rgb_224.mp4",
            "frames.jsonl",
            UltrawideRecordingWriter.videoFilename,
            UltrawideRecordingWriter.framesFilename,
            UltrawideRecordingWriter.previewFilename
        ]
        let sourceBytes = try Dictionary(
            uniqueKeysWithValues: protectedNames.map { name in
                (
                    name,
                    try Data(
                        contentsOf: directoryURL.appendingPathComponent(name)
                    )
                )
            }
        )
        let selection = CaptureExportSelection(
            includeRawRGBVideo: false,
            includeProcessedRGBVideo: false,
            includeUltrawideObservation: false
        )
        let package = try build(
            rgbVideoURLs: [videoURL],
            outputSubdirectory: "selection-none",
            selection: selection
        ).get()
        let entries = try ZIPEntries.read(package.fileURL)

        XCTAssertNotNil(
            entries["rgb/segment_001/recording_info.json"]
        )
        for name in protectedNames {
            XCTAssertNil(entries["rgb/segment_001/\(name)"])
            XCTAssertEqual(
                try Data(
                    contentsOf: directoryURL.appendingPathComponent(name)
                ),
                sourceBytes[name]
            )
        }
        let manifestData = try XCTUnwrap(
            entries["capture_manifest.json"]
        )
        let manifest = try XCTUnwrap(
            JSONSerialization.jsonObject(with: manifestData)
                as? [String: Any]
        )
        let storedSelection = try XCTUnwrap(
            manifest["export_selection"] as? [String: Any]
        )
        XCTAssertEqual(
            storedSelection["include_raw_rgb_video"] as? Bool,
            false
        )
        XCTAssertEqual(
            storedSelection["include_processed_rgb_video"] as? Bool,
            false
        )
        XCTAssertEqual(
            storedSelection["include_ultrawide_observation"] as? Bool,
            false
        )
        let segments = try XCTUnwrap(
            manifest["rgb_segments"] as? [[String: Any]]
        )
        XCTAssertEqual(
            Set(segments[0]["excluded_files"] as? [String] ?? []),
            Set(protectedNames)
        )
    }

    func testExportSelectionKeepsRequestedVideoBundlesAndBindings()
        throws {
        let videoURL = try makeRGBSegment(
            id: "selection-bundles",
            includeUMIFile: true,
            umiVideoFilename: "ego_rgb_224.mp4",
            umiEncodedFrameCount: 1,
            includeUltrawide: true
        )
        let selection = CaptureExportSelection(
            includeRawRGBVideo: false,
            includeProcessedRGBVideo: true,
            includeUltrawideObservation: true
        )
        let package = try build(
            rgbVideoURLs: [videoURL],
            outputSubdirectory: "selection-bundles",
            selection: selection
        ).get()
        let entries = try ZIPEntries.read(package.fileURL)
        let prefix = "rgb/segment_001/"

        XCTAssertNil(entries[prefix + "rgb.mp4"])
        XCTAssertNotNil(entries[prefix + "ego_rgb_224.mp4"])
        XCTAssertNotNil(entries[prefix + "frames.jsonl"])
        XCTAssertNotNil(
            entries[prefix + UltrawideRecordingWriter.videoFilename]
        )
        XCTAssertNotNil(
            entries[prefix + UltrawideRecordingWriter.framesFilename]
        )
        XCTAssertNotNil(
            entries[prefix + UltrawideRecordingWriter.previewFilename]
        )
        XCTAssertNotNil(entries[prefix + "recording_info.json"])
    }

    func testUltrawideOnlySegmentUsesMetadataAnchorWithoutRawRGB()
        throws {
        let rawURL = try makeRGBSegment(
            id: "ultrawide-only",
            includeFrames: false,
            includeRawRGB: false,
            rawEncodedFrameCount: 0,
            includeUltrawide: true
        )
        let metadataURL = rawURL.deletingLastPathComponent()
            .appendingPathComponent("recording_info.json")
        let package = try build(
            rgbVideoURLs: [metadataURL],
            outputSubdirectory: "ultrawide-only",
            selection: CaptureExportSelection(
                includeRawRGBVideo: false,
                includeProcessedRGBVideo: false,
                includeUltrawideObservation: true
            )
        ).get()
        let entries = try ZIPEntries.read(package.fileURL)
        let prefix = "rgb/segment_001/"

        XCTAssertNil(entries[prefix + "rgb.mp4"])
        XCTAssertNil(entries[prefix + "ego_rgb_224.mp4"])
        XCTAssertNotNil(
            entries[prefix + UltrawideRecordingWriter.videoFilename]
        )
        XCTAssertNotNil(entries[prefix + "recording_info.json"])
    }

    func testDuplicateDeclaredRGBProducerFailsClosed() throws {
        let videoURL = try makeRGBSegment(id: "duplicate")
        let result = build(rgbVideoURLs: [videoURL, videoURL])

        guard case .failure = result else {
            return XCTFail("Duplicate producer input must fail closed.")
        }
        XCTAssertTrue(finalZIPURLs().isEmpty)
    }

    func testEveryDeclaredProducerIsClassifiedFailClosed() throws {
        let validURL = try makeRGBSegment(id: "classified")
        let missingURL = rootURL
            .appendingPathComponent("missing", isDirectory: true)
            .appendingPathComponent("rgb.mp4")
        let wrongNameURL = validURL.deletingLastPathComponent()
            .appendingPathComponent("renamed.mp4")
        try Data([1]).write(to: wrongNameURL)

        for (id, urls) in [
            ("missing", [missingURL]),
            ("wrong-basename", [wrongNameURL])
        ] {
            let result = build(
                rgbVideoURLs: urls,
                outputSubdirectory: id
            )
            guard case .failure = result else {
                return XCTFail("\(id) producer must fail closed.")
            }
            XCTAssertTrue(finalZIPURLs(subdirectory: id).isEmpty)
        }
    }

    func testEmptyNonregularAndSymlinkProducersFailClosed() throws {
        let validURL = try makeRGBSegment(id: "unsafe-producers")
        let emptyDirectory = rootURL.appendingPathComponent(
            "empty-producer",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: emptyDirectory,
            withIntermediateDirectories: true
        )
        let emptyURL = emptyDirectory.appendingPathComponent("rgb.mp4")
        try Data().write(to: emptyURL)

        let nonregularDirectory = rootURL.appendingPathComponent(
            "nonregular-producer",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: nonregularDirectory.appendingPathComponent(
                "rgb.mp4",
                isDirectory: true
            ),
            withIntermediateDirectories: true
        )
        let nonregularURL = nonregularDirectory.appendingPathComponent(
            "rgb.mp4",
            isDirectory: true
        )

        let symlinkDirectory = rootURL.appendingPathComponent(
            "symlink-producer",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: symlinkDirectory,
            withIntermediateDirectories: true
        )
        let symlinkURL = symlinkDirectory.appendingPathComponent("rgb.mp4")
        try FileManager.default.createSymbolicLink(
            at: symlinkURL,
            withDestinationURL: validURL
        )

        for (id, url) in [
            ("empty", emptyURL),
            ("nonregular", nonregularURL),
            ("symlink", symlinkURL)
        ] {
            guard case .failure = build(
                rgbVideoURLs: [url],
                outputSubdirectory: id
            ) else {
                return XCTFail("\(id) producer must fail closed.")
            }
            XCTAssertTrue(finalZIPURLs(subdirectory: id).isEmpty)
        }
    }

    func testSystemRootAliasIsAcceptedAndCanonicalAliasDuplicateFails()
        throws {
        let privateRoot = URL(fileURLWithPath: "/private/tmp")
            .appendingPathComponent(
                "iphonevio-root-alias-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: privateRoot,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(at: privateRoot)
        }
        let videoURL = try makeRGBSegment(
            id: "root-alias",
            sourceRootURL: privateRoot
        )
        let aliasURL = URL(
            fileURLWithPath: videoURL.path.replacingOccurrences(
                of: "/private/tmp/",
                with: "/tmp/",
                options: [.anchored]
            )
        )

        _ = try build(
            rgbVideoURLs: [aliasURL],
            outputSubdirectory: "root-alias",
            trustedSourceRootURL: privateRoot,
            explicitOutputDirectoryURL: privateRoot.appendingPathComponent(
                "Exports",
                isDirectory: true
            )
        ).get()
        guard case .failure = build(
            rgbVideoURLs: [videoURL, aliasURL],
            outputSubdirectory: "root-alias-duplicate",
            trustedSourceRootURL: privateRoot,
            explicitOutputDirectoryURL: privateRoot.appendingPathComponent(
                "DuplicateExports",
                isDirectory: true
            )
        ) else {
            return XCTFail("Canonical alias duplicates must fail closed.")
        }
    }

    func testProducerDirectorySymlinkFailsClosed() throws {
        let videoURL = try makeRGBSegment(id: "directory-target")
        let aliasDirectory = rootURL.appendingPathComponent(
            "directory-alias",
            isDirectory: true
        )
        try FileManager.default.createSymbolicLink(
            at: aliasDirectory,
            withDestinationURL: videoURL.deletingLastPathComponent()
        )

        guard case .failure = build(
            rgbVideoURLs: [
                aliasDirectory.appendingPathComponent("rgb.mp4")
            ],
            outputSubdirectory: "directory-symlink"
        ) else {
            return XCTFail("Producer directory symlinks must fail closed.")
        }
    }

    func testUMIFilenameIdentityAndDeclaredArtifactAreBound() throws {
        let validURL = try makeRGBSegment(
            id: "umi-valid",
            includeUMIFile: true,
            umiVideoFilename: "ego_rgb_224.mp4",
            umiEncodedFrameCount: 1
        )
        let package = try build(
            rgbVideoURLs: [validURL],
            outputSubdirectory: "umi-valid"
        ).get()
        let validEntries = try ZIPEntries.read(package.fileURL)
        XCTAssertNotNil(
            validEntries["rgb/segment_001/ego_rgb_224.mp4"]
        )

        let wrongNameURL = try makeRGBSegment(
            id: "umi-wrong-name",
            includeUMIFile: true,
            umiVideoFilename: "different.mp4",
            umiEncodedFrameCount: 1
        )
        guard case .failure = build(
            rgbVideoURLs: [wrongNameURL],
            outputSubdirectory: "umi-wrong-name"
        ) else {
            return XCTFail("Wrong UMI metadata filename must fail closed.")
        }

        let missingURL = try makeRGBSegment(
            id: "umi-declared-missing",
            umiVideoFilename: "ego_rgb_224.mp4",
            umiEncodedFrameCount: 1
        )
        guard case .failure = build(
            rgbVideoURLs: [missingURL],
            outputSubdirectory: "umi-declared-missing"
        ) else {
            return XCTFail("Declared missing UMI video must fail closed.")
        }

        let zeroCountURL = try makeRGBSegment(
            id: "umi-zero-count",
            includeUMIFile: true,
            umiVideoFilename: "ego_rgb_224.mp4",
            umiEncodedFrameCount: 0
        )
        guard case .failure = build(
            rgbVideoURLs: [zeroCountURL],
            outputSubdirectory: "umi-zero-count"
        ) else {
            return XCTFail("Declared UMI video needs a positive frame count.")
        }
    }

    func testUndeclaredOrphanUMIFileIsOmittedWithSafeDiagnostic()
        throws {
        let videoURL = try makeRGBSegment(
            id: "umi-orphan",
            includeUMIFile: true
        )
        let package = try build(
            rgbVideoURLs: [videoURL],
            outputSubdirectory: "umi-orphan"
        ).get()
        let entries = try ZIPEntries.read(package.fileURL)
        XCTAssertNil(entries["rgb/segment_001/ego_rgb_224.mp4"])
        let manifest = try XCTUnwrap(entries["capture_manifest.json"])
        XCTAssertNotNil(
            manifest.range(
                of: Data(
                    "segment_001 contains an undeclared "
                        .appending("ego_rgb_224.mp4")
                        .utf8
                )
            )
        )
        XCTAssertNil(manifest.range(of: Data(rootURL.path.utf8)))
    }

    func testUnavailableDocumentsResolverFailsWithoutTemporaryZIP()
        throws {
        let before = temporaryCompletedPackageNames()
        let builder = CaptureExportPackageBuilder(
            documentsDirectoryResolver: { nil }
        )
        let completed = expectation(description: "unavailable Documents")
        var output: Result<CaptureExportPackage, Error>?
        builder.build(
            trajectoryURL: nil,
            rgbVideoURLs: [],
            startedAtUnixMs: nil,
            endedAtUnixMs: 2_000
        ) {
            output = $0
            completed.fulfill()
        }
        wait(for: [completed], timeout: 5)

        guard case .failure(
            CaptureExportError.durableOutputDirectoryUnavailable
        ) = output else {
            return XCTFail("Unavailable Documents must fail closed.")
        }
        XCTAssertEqual(temporaryCompletedPackageNames(), before)
    }

    func testSemanticSnapshotMutationPackagesValidatedBytesOnly() throws {
        let videoURL = try makeRGBSegment(id: "semantic-snapshot")
        let infoURL = videoURL.deletingLastPathComponent()
            .appendingPathComponent("recording_info.json")
        let validatedBytes = try Data(contentsOf: infoURL)
        let result = build(
            rgbVideoURLs: [videoURL],
            outputSubdirectory: "semantic-snapshot",
            afterIntegrityPreflight: {
                try Data("{}".utf8).write(to: infoURL)
            }
        )
        let package = try result.get()
        let packaged = try XCTUnwrap(
            ZIPEntries.read(package.fileURL)[
                "rgb/segment_001/recording_info.json"
            ]
        )

        XCTAssertEqual(packaged, validatedBytes)
        XCTAssertNotEqual(packaged, try Data(contentsOf: infoURL))
    }

    func testStreamingMutationFailsAndPreservesNonshareablePartial()
        throws {
        let videoURL = try makeRGBSegment(id: "stream-mutation")
        let result = build(
            rgbVideoURLs: [videoURL],
            outputSubdirectory: "stream-mutation",
            afterIntegrityPreflight: {
                let handle = try FileHandle(forWritingTo: videoURL)
                try handle.seekToEnd()
                try handle.write(contentsOf: Data([9]))
                try handle.close()
            }
        )

        guard case .failure = result else {
            return XCTFail("Streaming mutation must fail closed.")
        }
        XCTAssertTrue(
            finalZIPURLs(subdirectory: "stream-mutation").isEmpty
        )
        XCTAssertEqual(
            preservedPartialURLs(subdirectory: "stream-mutation").count,
            1
        )
    }

    func testExistingPackagesAndPartialsAreNeverAutomaticallyDeleted()
        throws {
        let outputURL = outputDirectoryURL(
            subdirectory: "preservation"
        )
        try FileManager.default.createDirectory(
            at: outputURL,
            withIntermediateDirectories: true
        )
        let existingZIP = outputURL.appendingPathComponent("existing.zip")
        let existingPartial = outputURL.appendingPathComponent(
            ".previous.writing"
        )
        try Data([1, 2, 3]).write(to: existingZIP)
        try Data([4, 5]).write(to: existingPartial)
        let videoURL = try makeRGBSegment(id: "preservation")
        let package = try build(
            rgbVideoURLs: [videoURL],
            outputSubdirectory: "preservation"
        ).get()
        let manifest = try XCTUnwrap(
            ZIPEntries.read(package.fileURL)["capture_manifest.json"]
        )

        XCTAssertEqual(try Data(contentsOf: existingZIP), Data([1, 2, 3]))
        XCTAssertEqual(try Data(contentsOf: existingPartial), Data([4, 5]))
        XCTAssertNotNil(
            manifest.range(of: Data(".previous.writing".utf8))
        )
        XCTAssertNil(manifest.range(of: Data(outputURL.path.utf8)))
    }

    func testMalformedTrajectoryAndMismatchedSegmentIdentityFailClosed()
        throws {
        let malformedTrajectory = rootURL.appendingPathComponent(
            "trajectory.json"
        )
        try Data("{\"schema_version\":2}".utf8).write(
            to: malformedTrajectory
        )
        guard case .failure = build(
            trajectoryURL: malformedTrajectory,
            rgbVideoURLs: [],
            outputSubdirectory: "bad-trajectory"
        ) else {
            return XCTFail("Malformed trajectory must fail closed.")
        }

        let videoURL = try makeRGBSegment(id: "identity")
        let infoURL = videoURL.deletingLastPathComponent()
            .appendingPathComponent("recording_info.json")
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: infoURL))
                as? [String: Any]
        )
        object["recording_uuid"] = "different"
        try JSONSerialization.data(withJSONObject: object).write(to: infoURL)
        guard case .failure = build(
            rgbVideoURLs: [videoURL],
            outputSubdirectory: "bad-identity"
        ) else {
            return XCTFail("Mismatched producer identity must fail closed.")
        }
    }

    func testArchiveWriterRejectsMissingOrDuplicateDescriptors() throws {
        let data = Data([1, 2, 3])
        let descriptor = try CaptureArtifactIntegrity.descriptor(
            path: "capture/a.bin",
            producerKind: .trajectory,
            producerID: "producer",
            required: true,
            data: data
        )
        XCTAssertThrowsError(
            try StoredZIPArchiveWriter.write(
                entries: [StoredZIPEntry(path: "capture/a.bin", data: data)],
                to: rootURL.appendingPathComponent("missing.zip")
            )
        )
        let mismatchedDescriptor = try CaptureArtifactIntegrity.descriptor(
            path: "capture/b.bin",
            producerKind: .trajectory,
            producerID: "producer",
            required: true,
            data: data
        )
        XCTAssertThrowsError(
            try StoredZIPArchiveWriter.write(
                entries: [
                    StoredZIPEntry(
                        path: "capture/a.bin",
                        data: data,
                        descriptor: mismatchedDescriptor
                    )
                ],
                to: rootURL.appendingPathComponent("mismatched.zip")
            )
        )
        XCTAssertThrowsError(
            try StoredZIPArchiveWriter.write(
                entries: [
                    StoredZIPEntry(
                        path: "capture/a.bin",
                        data: data,
                        descriptor: descriptor
                    ),
                    StoredZIPEntry(
                        path: "capture/a.bin",
                        data: data,
                        descriptor: descriptor
                    )
                ],
                to: rootURL.appendingPathComponent("duplicate.zip")
            )
        )
    }

    func testSourceHasNoAutomaticExpiryOrPartialDeletion() throws {
        let repositoryURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryURL.appendingPathComponent(
                "UMICapture/CaptureExportPackage.swift"
            ),
            encoding: .utf8
        )

        XCTAssertFalse(source.contains("removeExpiredPackages"))
        XCTAssertFalse(source.contains("removeItem(at: temporaryURL)"))
        XCTAssertTrue(source.contains("CaptureExportPackages"))
    }

    private func build(
        trajectoryURL: URL? = nil,
        rgbVideoURLs: [URL],
        outputSubdirectory: String = "default",
        trustedSourceRootURL: URL? = nil,
        explicitOutputDirectoryURL: URL? = nil,
        afterIntegrityPreflight: (() throws -> Void)? = nil,
        selection: CaptureExportSelection = .all,
        captureProfile: CaptureProfileSnapshot? = nil,
        softwareProvenance: SoftwareProvenance = .current()
    ) -> Result<CaptureExportPackage, Error> {
        let completed = expectation(description: "export build")
        var output: Result<CaptureExportPackage, Error>?
        let builder = CaptureExportPackageBuilder(
            outputDirectoryURL: explicitOutputDirectoryURL
                ?? outputDirectoryURL(subdirectory: outputSubdirectory),
            trustedSourceRootURL: trustedSourceRootURL ?? rootURL,
            documentsDirectoryResolver: { nil },
            afterIntegrityPreflight: afterIntegrityPreflight,
            softwareProvenance: softwareProvenance
        )
        builder.build(
            trajectoryURL: trajectoryURL,
            rgbVideoURLs: rgbVideoURLs,
            startedAtUnixMs: 1_000,
            endedAtUnixMs: 2_000,
            selection: selection,
            captureProfile: captureProfile
        ) {
            output = $0
            completed.fulfill()
        }
        wait(for: [completed], timeout: 5)
        return output ?? .failure(TestError.missingCompletion)
    }

    private func makeTrajectory(id: String) throws -> URL {
        let url = rootURL.appendingPathComponent("trajectory.json")
        let archive = TrajectoryArchive(
            recordingID: UUID(
                uuidString: "11111111-1111-4111-8111-111111111111"
            )!,
            startedAtUnixMs: 1_000,
            endedAtUnixMs: 2_000,
            samples: [
                TrajectoryPoseSample(
                    position: .zero,
                    cameraForward: SIMD3<Float>(0, 0, -1),
                    elapsedTimeSeconds: 0,
                    orientationXYZW: SIMD4<Float>(0, 0, 0, 1)
                )
            ]
        )
        try JSONEncoder().encode(archive).write(to: url)
        return url
    }

    private func makeRGBSegment(
        id: String,
        includeFrames: Bool = true,
        includeRawRGB: Bool = true,
        rawEncodedFrameCount: Int = 1,
        includeUMIFile: Bool = false,
        umiVideoFilename: String? = nil,
        umiEncodedFrameCount: Int? = nil,
        includeUltrawide: Bool = false,
        sourceRootURL: URL? = nil
    ) throws -> URL {
        let directoryURL = (sourceRootURL ?? rootURL)
            .appendingPathComponent("RGBCaptures", isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        let videoURL = directoryURL.appendingPathComponent("rgb.mp4")
        if includeRawRGB {
            try Data([0, 1, 2, 3]).write(to: videoURL)
        }
        if includeUMIFile {
            try Data([4, 5, 6]).write(
                to: directoryURL.appendingPathComponent(
                    "ego_rgb_224.mp4"
                )
            )
        }
        if includeFrames {
            try Data("{\"encoded\":true,\"mp4_pts_s\":0}\n".utf8)
                .write(
                    to: directoryURL.appendingPathComponent(
                        "frames.jsonl"
                    )
                )
        }
        if includeUltrawide {
            try Data([7, 8, 9]).write(
                to: directoryURL.appendingPathComponent(
                    UltrawideRecordingWriter.videoFilename
                )
            )
            try Data("{\"encoded\":true,\"mp4_pts_s\":0}\n".utf8)
                .write(
                    to: directoryURL.appendingPathComponent(
                        UltrawideRecordingWriter.framesFilename
                    )
                )
            try Data([0xff, 0xd8, 0xff, 0xd9]).write(
                to: directoryURL.appendingPathComponent(
                    UltrawideRecordingWriter.previewFilename
                )
            )
        }
        var info = RGBRecordingInfo(
            schemaVersion: 3,
            recordingUUID: id,
            width: 1920,
            height: 1440,
            nominalFPS: 60,
            codec: "HEVC/H.265",
            container: "MP4",
            encodedFrameCount: rawEncodedFrameCount,
            droppedFrameCount: 0,
            finishReason: "stop",
            firstFrameCameraIntrinsics: nil,
            displayName: id,
            startedAtUnixMs: 1_000,
            endedAtUnixMs: 2_000,
            dataKey: "ego_rgb",
            cameraRole: "chest_ego_camera",
            iPhoneModel: nil,
            lensMode: nil,
            physicalCameraType: nil,
            fixedInterfaceOrientation: nil,
            captureStartInterfaceOrientation: "portrait",
            empiricalCalibration: nil,
            umiPreprocessing: nil,
            umiVideoFilename: umiVideoFilename,
            framesMetadataFilename: "frames.jsonl",
            umiEncodedFrameCount: umiEncodedFrameCount,
            umiDroppedFrameCount: nil,
            firstFrameUMI224Intrinsics: nil
        )
        if includeUltrawide {
            info.ultrawideVideoFilename =
                UltrawideRecordingWriter.videoFilename
            info.ultrawideFramesMetadataFilename =
                UltrawideRecordingWriter.framesFilename
            info.ultrawidePreviewFilename =
                UltrawideRecordingWriter.previewFilename
            info.ultrawideWidth = 640
            info.ultrawideHeight = 480
            info.ultrawideEncodedFrameCount = 1
            info.ultrawideDroppedFrameCount = 0
        }
        try JSONEncoder().encode(info).write(
            to: directoryURL.appendingPathComponent("recording_info.json")
        )
        return videoURL
    }

    private func outputDirectoryURL(subdirectory: String) -> URL {
        rootURL.appendingPathComponent(
            "CaptureExportPackages-\(subdirectory)"
        )
    }

    private func finalZIPURLs(
        subdirectory: String = "default"
    ) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: outputDirectoryURL(subdirectory: subdirectory),
            includingPropertiesForKeys: nil
        ))?.filter { $0.pathExtension == "zip" } ?? []
    }

    private func preservedPartialURLs(subdirectory: String) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: outputDirectoryURL(subdirectory: subdirectory),
            includingPropertiesForKeys: nil
        ))?.filter {
            $0.lastPathComponent.hasPrefix(".")
                && $0.lastPathComponent.hasSuffix(".writing")
        } ?? []
    }

    private func temporaryCompletedPackageNames() -> Set<String> {
        Set(
            (try? FileManager.default.contentsOfDirectory(
                at: FileManager.default.temporaryDirectory,
                includingPropertiesForKeys: nil
            ))?.filter {
                $0.pathExtension == "zip"
                    && $0.lastPathComponent.hasPrefix("UMICapture_")
            }.map(\.lastPathComponent) ?? []
        )
    }

    private enum TestError: Error {
        case missingCompletion
    }
}

private enum ZIPEntries {
    static func read(_ url: URL) throws -> [String: Data] {
        let bytes = try Data(contentsOf: url)
        guard let endOffset = bytes.lastRange(
            of: Data([0x50, 0x4b, 0x05, 0x06])
        )?.lowerBound else {
            throw ZIPError.invalidArchive
        }
        let count = Int(try bytes.uint16(at: endOffset + 10))
        var cursor = Int(try bytes.uint32(at: endOffset + 16))
        var result: [String: Data] = [:]
        for _ in 0..<count {
            guard try bytes.uint32(at: cursor) == 0x02014b50 else {
                throw ZIPError.invalidArchive
            }
            let size = Int(try bytes.uint32(at: cursor + 20))
            let nameLength = Int(try bytes.uint16(at: cursor + 28))
            let extraLength = Int(try bytes.uint16(at: cursor + 30))
            let commentLength = Int(try bytes.uint16(at: cursor + 32))
            let localOffset = Int(try bytes.uint32(at: cursor + 42))
            let nameData = bytes.subdata(
                in: (cursor + 46)..<(cursor + 46 + nameLength)
            )
            guard let name = String(data: nameData, encoding: .utf8),
                  try bytes.uint32(at: localOffset) == 0x04034b50
            else {
                throw ZIPError.invalidArchive
            }
            let localNameLength = Int(
                try bytes.uint16(at: localOffset + 26)
            )
            let localExtraLength = Int(
                try bytes.uint16(at: localOffset + 28)
            )
            let dataStart = localOffset + 30
                + localNameLength + localExtraLength
            result[name] = bytes.subdata(in: dataStart..<(dataStart + size))
            cursor += 46 + nameLength + extraLength + commentLength
        }
        return result
    }

    private enum ZIPError: Error {
        case invalidArchive
    }
}

private extension Data {
    func uint16(at offset: Int) throws -> UInt16 {
        guard offset >= 0, offset + 2 <= count else {
            throw ZIPReadError.outOfBounds
        }
        return UInt16(self[offset]) | (UInt16(self[offset + 1]) << 8)
    }

    func uint32(at offset: Int) throws -> UInt32 {
        guard offset >= 0, offset + 4 <= count else {
            throw ZIPReadError.outOfBounds
        }
        return UInt32(self[offset])
            | (UInt32(self[offset + 1]) << 8)
            | (UInt32(self[offset + 2]) << 16)
            | (UInt32(self[offset + 3]) << 24)
    }

    func lastRange(of needle: Data) -> Range<Data.Index>? {
        range(of: needle, options: .backwards)
    }

    private enum ZIPReadError: Error {
        case outOfBounds
    }
}
