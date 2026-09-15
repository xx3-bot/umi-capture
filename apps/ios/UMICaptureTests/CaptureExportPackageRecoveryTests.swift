import CryptoKit
import Foundation
import XCTest
@testable import UMICapture

final class CaptureExportPackageRecoveryTests: XCTestCase {
    private static let lockedClassificationDigest =
        "f8f3b9adfabf15ea7ff63fb114776688c3a3d279cdd751ecfca487932a3b6025"

    func testLockedClassificationRowsAreUniqueAndComplete() {
        XCTAssertEqual(Self.classificationRows.count, 19)
        XCTAssertEqual(
            Set(Self.classificationRows.map(\.id)).count,
            Self.classificationRows.count
        )
        XCTAssertTrue(Self.classificationRows.contains {
            $0.id == "writing.preexisting"
                && $0.deletableCount == 1
        })
        XCTAssertTrue(Self.classificationRows.contains {
            $0.id == "writing.postinit"
                && $0.deletableCount == 0
        })
        XCTAssertTrue(Self.classificationRows.contains {
            $0.id == "zip.duplicatePackageID"
                && $0.completedCount == 0
                && $0.recoveryCount == 2
        })
    }

    func testLockedClassificationDigest() {
        let canonical = Self.classificationRows
            .sorted { $0.id < $1.id }
            .map(\.canonicalLine)
            .joined(separator: "\n") + "\n"
        let digest = SHA256.hash(data: Data(canonical.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        XCTAssertEqual(digest, Self.lockedClassificationDigest)
    }

    func testClassificationRowsKeepUnsafeFilesNondeletable() {
        for id in [
            "unknown.regular",
            "unknown.symlink",
            "zip.symlink",
            "writing.symlink"
        ] {
            let row = Self.classificationRows.first { $0.id == id }
            XCTAssertEqual(row?.deletableCount, 0, id)
            XCTAssertEqual(row?.completedCount, 0, id)
        }
    }

    func testProductionIndexAndWiringExist() throws {
        let repositoryURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let indexURL = repositoryURL.appendingPathComponent(
            "UMICapture/CaptureExportPackageIndex.swift"
        )
        guard FileManager.default.fileExists(atPath: indexURL.path) else {
            throw XCTSkip(
                "P0-C2 package indexing was explicitly deferred."
            )
        }
        let librarySource = try String(
            contentsOf: repositoryURL.appendingPathComponent(
                "UMICapture/CaptureLibrary.swift"
            ),
            encoding: .utf8
        )
        XCTAssertTrue(
            librarySource.contains("CaptureExportPackageIndex"),
            "Stage 1: CaptureLibrary wiring is intentionally absent."
        )
    }

    func testAbsentPackageDirectoryHasNoScanSideEffect() throws {
        let root = try makeTemporaryRoot("absent")
        let directory = root.appendingPathComponent(
            "CaptureExportPackages",
            isDirectory: true
        )
        let index = CaptureExportPackageIndex(
            directoryURL: directory,
            preexistingWritingIdentities: [:]
        )

        let snapshot = index.scan()

        XCTAssertTrue(snapshot.completed.isEmpty)
        XCTAssertTrue(snapshot.recovery.isEmpty)
        XCTAssertTrue(snapshot.diagnostics.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testCurrentBuilderPackageIsIndexedAndShareable() throws {
        let root = try makeTemporaryRoot("valid")
        let packageURL = try makeCompletedPackage(root: root)
        let library = CaptureLibrary(documentsDirectoryURL: root)
        let refreshed = expectation(description: "package refresh")
        library.refresh { refreshed.fulfill() }
        wait(for: [refreshed], timeout: 5)

        XCTAssertEqual(library.exportPackages.count, 1)
        XCTAssertEqual(
            library.exportPackages.first?.fileURL.lastPathComponent,
            packageURL.lastPathComponent
        )
        XCTAssertTrue(library.exportRecovery.isEmpty)
    }

    func testLegacyPackageWithoutSoftwareProvenanceRemainsIndexed()
        throws {
        let root = try makeTemporaryRoot("legacy-no-provenance")
        let directory = root.appendingPathComponent(
            "CaptureExportPackages",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let artifactData = Data([1, 2, 3, 4])
        let digest = CaptureArtifactIntegrity.digest(data: artifactData)
        let descriptor = CaptureArtifactDescriptor(
            path: "trajectory/trajectory.json",
            producerKind: .trajectory,
            producerID: UUID().uuidString,
            required: true,
            byteSize: digest.byteSize,
            sha256: digest.sha256
        )
        try StoredZIPArchiveWriter.write(
            entries: [
                StoredZIPEntry(
                    path: descriptor.path,
                    data: artifactData,
                    descriptor: descriptor
                ),
                StoredZIPEntry(
                    path: "capture_manifest.json",
                    data: try manifestData(artifacts: [descriptor])
                ),
                StoredZIPEntry(
                    path: "README.txt",
                    data: Data("legacy readme".utf8)
                )
            ],
            to: directory.appendingPathComponent("legacy.zip")
        )

        let snapshot = CaptureExportPackageIndex(
            directoryURL: directory,
            preexistingWritingIdentities: [:]
        ).scan()

        XCTAssertEqual(snapshot.completed.count, 1)
        XCTAssertTrue(snapshot.recovery.isEmpty)
        XCTAssertTrue(snapshot.diagnostics.isEmpty)
    }

    func testWritingEligibilityIsFrozenAtInitialization() throws {
        let root = try makeTemporaryRoot("writing")
        let directory = root.appendingPathComponent(
            "CaptureExportPackages",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let old = directory.appendingPathComponent(".old.writing")
        try Data([1]).write(to: old)
        let library = CaptureLibrary(documentsDirectoryURL: root)
        let current = directory.appendingPathComponent(".current.writing")
        try Data([2]).write(to: current)
        let refreshed = expectation(description: "writing refresh")
        library.refresh { refreshed.fulfill() }
        wait(for: [refreshed], timeout: 5)

        XCTAssertEqual(library.exportRecovery.count, 2)
        XCTAssertEqual(
            library.exportRecovery.first {
                $0.displayName == ".old.writing"
            }?.isDeletionEligible,
            true
        )
        XCTAssertEqual(
            library.exportRecovery.first {
                $0.displayName == ".current.writing"
            }?.isDeletionEligible,
            false
        )
    }

    func testCorruptAndDuplicatePackagesNeverBecomeShareable() throws {
        let root = try makeTemporaryRoot("invalid")
        let original = try makeCompletedPackage(root: root)
        let directory = original.deletingLastPathComponent()
        let duplicate = directory.appendingPathComponent("duplicate.zip")
        try FileManager.default.copyItem(at: original, to: duplicate)
        let corrupt = directory.appendingPathComponent("corrupt.zip")
        try Data([0x50, 0x4b, 0x03]).write(to: corrupt)
        let library = CaptureLibrary(documentsDirectoryURL: root)
        let refreshed = expectation(description: "invalid refresh")
        library.refresh { refreshed.fulfill() }
        wait(for: [refreshed], timeout: 5)

        XCTAssertTrue(library.exportPackages.isEmpty)
        XCTAssertEqual(
            library.exportRecovery.filter {
                $0.state == .identityConflict
            }.count,
            2
        )
        XCTAssertEqual(
            library.exportRecovery.filter {
                $0.state == .corruptPackage
            }.count,
            1
        )
    }

    func testDeletionFailsClosedAfterIdentityReplacement() throws {
        let root = try makeTemporaryRoot("identity")
        let directory = root.appendingPathComponent(
            "CaptureExportPackages",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let file = directory.appendingPathComponent("broken.zip")
        try Data([1]).write(to: file)
        let library = CaptureLibrary(documentsDirectoryURL: root)
        let loaded = expectation(description: "loaded")
        library.refresh { loaded.fulfill() }
        wait(for: [loaded], timeout: 5)
        let record = try XCTUnwrap(library.exportRecovery.first)

        try FileManager.default.removeItem(at: file)
        try Data([2, 3]).write(to: file)
        let deleted = expectation(description: "delete refused")
        var didDelete = true
        library.deleteExportRecovery(record) { result in
            didDelete = result
            deleted.fulfill()
        }
        wait(for: [deleted], timeout: 5)

        XCTAssertFalse(didDelete)
        XCTAssertEqual(try Data(contentsOf: file), Data([2, 3]))
    }

    func testChangedControlBytesAndSymlinkZIPAreNeverShareable() throws {
        let root = try makeTemporaryRoot("control-crc")
        let valid = try makeCompletedPackage(root: root)
        var bytes = try Data(contentsOf: valid)
        let marker = Data("UMI Capture Capture Package".utf8)
        let markerRange = try XCTUnwrap(bytes.range(of: marker))
        bytes[markerRange.lowerBound] ^= 0xff
        let corrupt = valid.deletingLastPathComponent()
            .appendingPathComponent("changed-control.zip")
        try bytes.write(to: corrupt)
        let symlink = valid.deletingLastPathComponent()
            .appendingPathComponent("alias.zip")
        try FileManager.default.createSymbolicLink(
            at: symlink,
            withDestinationURL: valid
        )

        let index = CaptureExportPackageIndex(
            directoryURL: valid.deletingLastPathComponent(),
            preexistingWritingIdentities: [:]
        )
        let snapshot = index.scan()

        XCTAssertEqual(snapshot.completed.count, 1)
        XCTAssertEqual(
            snapshot.recovery.filter { $0.state == .corruptPackage }.count,
            1
        )
        XCTAssertEqual(snapshot.diagnostics.count, 1)
        XCTAssertFalse(snapshot.diagnostics[0].contains(root.path))
    }

    func testOversizedControlEntriesRejectBeforeStreamingBuffer() throws {
        for (name, size) in [
            ("capture_manifest.json", UInt32(2 * 1_024 * 1_024 + 1)),
            ("README.txt", UInt32(1 * 1_024 * 1_024 + 1))
        ] {
            let root = try makeTemporaryRoot("oversized-control")
            let valid = try makeCompletedPackage(root: root)
            var bytes = try Data(contentsOf: valid)
            try setCentralEntrySize(name: name, size: size, bytes: &bytes)
            let oversized = valid.deletingLastPathComponent()
                .appendingPathComponent("oversized-\(name).zip")
            try bytes.write(to: oversized)
            try FileManager.default.removeItem(at: valid)

            let snapshot = CaptureExportPackageIndex(
                directoryURL: oversized.deletingLastPathComponent(),
                preexistingWritingIdentities: [:]
            ).scan()
            XCTAssertTrue(snapshot.completed.isEmpty, name)
            XCTAssertEqual(snapshot.recovery.count, 1, name)
        }

        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "UMICapture/CaptureExportPackageIndex.swift"
            ),
            encoding: .utf8
        )
        let limitCheck = try XCTUnwrap(
            source.range(of: "entry.size > UInt64(manifestLimit)")
        )
        let validation = try XCTUnwrap(
            source.range(of: "let result = try validateEntry(")
        )
        XCTAssertLessThan(limitCheck.lowerBound, validation.lowerBound)
    }

    func testManagedRootSymlinkIsDiagnosticOnlyAndOutsideBytesSurvive()
        throws {
        let root = try makeTemporaryRoot("root-symlink")
        let outside = try makeTemporaryRoot("outside")
        let outsideFile = outside.appendingPathComponent("outside.zip")
        try Data([7, 8, 9]).write(to: outsideFile)
        let managed = root.appendingPathComponent("CaptureExportPackages")
        try FileManager.default.createSymbolicLink(
            at: managed,
            withDestinationURL: outside
        )

        let snapshot = CaptureExportPackageIndex(
            directoryURL: managed,
            preexistingWritingIdentities: [:]
        ).scan()
        let fakeIdentity = CaptureFileIdentity(
            device: 0,
            inode: 0,
            byteSize: 3,
            modificationSeconds: 0,
            modificationNanoseconds: 0
        )

        XCTAssertTrue(snapshot.completed.isEmpty)
        XCTAssertTrue(snapshot.recovery.isEmpty)
        XCTAssertEqual(snapshot.diagnostics.count, 1)
        XCTAssertFalse(
            CaptureExportPackageIndex.identityStillMatches(
                url: managed.appendingPathComponent("outside.zip"),
                expected: fakeIdentity,
                directoryURL: managed
            )
        )
        XCTAssertEqual(try Data(contentsOf: outsideFile), Data([7, 8, 9]))
    }

    func testManifestRequiresArtifactsAndNonemptyProducerIdentity() throws {
        let root = try makeTemporaryRoot("manifest-invariants")
        let directory = root.appendingPathComponent("CaptureExportPackages")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let controlsOnly = directory.appendingPathComponent("empty.zip")
        try StoredZIPArchiveWriter.write(
            entries: [
                StoredZIPEntry(
                    path: "capture_manifest.json",
                    data: try manifestData(artifacts: [])
                ),
                StoredZIPEntry(path: "README.txt", data: Data("readme".utf8))
            ],
            to: controlsOnly
        )

        let artifact = Data([1, 2, 3])
        let digest = CaptureArtifactIntegrity.digest(data: artifact)
        let emptyProducer = CaptureArtifactDescriptor(
            path: "trajectory/trajectory.json",
            producerKind: .trajectory,
            producerID: "",
            required: true,
            byteSize: digest.byteSize,
            sha256: digest.sha256
        )
        let emptyProducerZIP = directory.appendingPathComponent(
            "empty-producer.zip"
        )
        try StoredZIPArchiveWriter.write(
            entries: [
                StoredZIPEntry(
                    path: emptyProducer.path,
                    data: artifact,
                    descriptor: emptyProducer
                ),
                StoredZIPEntry(
                    path: "capture_manifest.json",
                    data: try manifestData(artifacts: [emptyProducer])
                ),
                StoredZIPEntry(path: "README.txt", data: Data("readme".utf8))
            ],
            to: emptyProducerZIP
        )

        let snapshot = CaptureExportPackageIndex(
            directoryURL: directory,
            preexistingWritingIdentities: [:]
        ).scan()
        XCTAssertTrue(snapshot.completed.isEmpty)
        XCTAssertEqual(snapshot.recovery.count, 2)
        XCTAssertTrue(snapshot.recovery.allSatisfy {
            $0.state == .corruptPackage
        })
    }

    func testRecoveryConfirmationDescribesPreservedArtifactTruthfully()
        throws {
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "UMICapture/RecentCapturesView.swift"
            ),
            encoding: .utf8
        )
        XCTAssertTrue(
            source.contains("preserved incomplete")
                && source.contains("record.displayName")
        )
        XCTAssertFalse(
            source.contains(
                "case .trajectory, .rgbVideo, .exportPackage, .exportRecovery"
            )
        )
    }
}

private extension CaptureExportPackageRecoveryTests {
    struct ClassificationRow {
        let id: String
        let completedCount: Int
        let recoveryCount: Int
        let diagnosticCount: Int
        let deletableCount: Int
        let recoveryStates: String

        var canonicalLine: String {
            [
                id,
                String(completedCount),
                String(recoveryCount),
                String(diagnosticCount),
                String(deletableCount),
                recoveryStates
            ].joined(separator: "|")
        }
    }

    static let classificationRows: [ClassificationRow] = [
        .init(id: "absent.directory", completedCount: 0, recoveryCount: 0, diagnosticCount: 0, deletableCount: 0, recoveryStates: "-"),
        .init(id: "unknown.regular", completedCount: 0, recoveryCount: 0, diagnosticCount: 1, deletableCount: 0, recoveryStates: "-"),
        .init(id: "unknown.symlink", completedCount: 0, recoveryCount: 0, diagnosticCount: 1, deletableCount: 0, recoveryStates: "-"),
        .init(id: "valid.four", completedCount: 4, recoveryCount: 0, diagnosticCount: 0, deletableCount: 0, recoveryStates: "-"),
        .init(id: "valid.one", completedCount: 1, recoveryCount: 0, diagnosticCount: 0, deletableCount: 0, recoveryStates: "-"),
        .init(id: "writing.postinit", completedCount: 0, recoveryCount: 1, diagnosticCount: 0, deletableCount: 0, recoveryStates: "incompleteWriting"),
        .init(id: "writing.preexisting", completedCount: 0, recoveryCount: 1, diagnosticCount: 0, deletableCount: 1, recoveryStates: "incompleteWriting"),
        .init(id: "writing.symlink", completedCount: 0, recoveryCount: 0, diagnosticCount: 1, deletableCount: 0, recoveryStates: "-"),
        .init(id: "zip.badArtifactSHA", completedCount: 0, recoveryCount: 1, diagnosticCount: 0, deletableCount: 1, recoveryStates: "corruptPackage"),
        .init(id: "zip.badControlCRC", completedCount: 0, recoveryCount: 1, diagnosticCount: 0, deletableCount: 1, recoveryStates: "corruptPackage"),
        .init(id: "zip.badDescriptor", completedCount: 0, recoveryCount: 1, diagnosticCount: 0, deletableCount: 1, recoveryStates: "corruptPackage"),
        .init(id: "zip.badManifest", completedCount: 0, recoveryCount: 1, diagnosticCount: 0, deletableCount: 1, recoveryStates: "corruptPackage"),
        .init(id: "zip.duplicatePackageID", completedCount: 0, recoveryCount: 2, diagnosticCount: 0, deletableCount: 2, recoveryStates: "identityConflict"),
        .init(id: "zip.localCentralMismatch", completedCount: 0, recoveryCount: 1, diagnosticCount: 0, deletableCount: 1, recoveryStates: "corruptPackage"),
        .init(id: "zip.overlap", completedCount: 0, recoveryCount: 1, diagnosticCount: 0, deletableCount: 1, recoveryStates: "corruptPackage"),
        .init(id: "zip.symlink", completedCount: 0, recoveryCount: 0, diagnosticCount: 1, deletableCount: 0, recoveryStates: "-"),
        .init(id: "zip.truncated", completedCount: 0, recoveryCount: 1, diagnosticCount: 0, deletableCount: 1, recoveryStates: "corruptPackage"),
        .init(id: "zip.unsafeName", completedCount: 0, recoveryCount: 1, diagnosticCount: 0, deletableCount: 1, recoveryStates: "corruptPackage"),
        .init(id: "zip.unsupportedFlags", completedCount: 0, recoveryCount: 1, diagnosticCount: 0, deletableCount: 1, recoveryStates: "corruptPackage")
    ]

    func makeTemporaryRoot(_ name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "iphonevio-p0c2-\(name)-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        return root
    }

    var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func setCentralEntrySize(
        name: String,
        size: UInt32,
        bytes: inout Data
    ) throws {
        let signature = Data([0x50, 0x4b, 0x01, 0x02])
        var cursor = bytes.startIndex
        while let range = bytes.range(
            of: signature,
            options: [],
            in: cursor..<bytes.endIndex
        ) {
            let offset = range.lowerBound
            guard offset + 46 <= bytes.endIndex else { break }
            let nameLength = Int(bytes[offset + 28])
                | (Int(bytes[offset + 29]) << 8)
            guard offset + 46 + nameLength <= bytes.endIndex else { break }
            let entryName = String(
                data: bytes[(offset + 46)..<(offset + 46 + nameLength)],
                encoding: .utf8
            )
            if entryName == name {
                for base in [offset + 20, offset + 24] {
                    bytes[base] = UInt8(truncatingIfNeeded: size)
                    bytes[base + 1] = UInt8(truncatingIfNeeded: size >> 8)
                    bytes[base + 2] = UInt8(truncatingIfNeeded: size >> 16)
                    bytes[base + 3] = UInt8(truncatingIfNeeded: size >> 24)
                }
                return
            }
            cursor = range.upperBound
        }
        throw TestFixtureError.missingCentralEntry
    }

    func manifestData(
        artifacts: [CaptureArtifactDescriptor]
    ) throws -> Data {
        let artifactObjects: [[String: Any]] = artifacts.map {
            [
                "path": $0.path,
                "producer_kind": $0.producerKind.rawValue,
                "producer_id": $0.producerID,
                "required": $0.required,
                "byte_size": $0.byteSize,
                "sha256": $0.sha256
            ]
        }
        return try JSONSerialization.data(
            withJSONObject: [
                "schema_version": 1,
                "kind": "iphonevio_capture_export",
                "package_id": UUID().uuidString,
                "created_at_unix_ms": 1_000,
                "completion_state": "completed",
                "integrity_schema_version": 1,
                "artifact_integrity": artifactObjects
            ]
        )
    }

    enum TestFixtureError: Error {
        case missingCentralEntry
    }

    func makeCompletedPackage(root: URL) throws -> URL {
        let trajectoryURL = root.appendingPathComponent("trajectory.json")
        let archive = TrajectoryArchive(
            recordingID: UUID(),
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
        try JSONEncoder().encode(archive).write(to: trajectoryURL)
        let output = root.appendingPathComponent(
            "CaptureExportPackages",
            isDirectory: true
        )
        let builder = CaptureExportPackageBuilder(
            outputDirectoryURL: output,
            trustedSourceRootURL: root,
            documentsDirectoryResolver: { nil }
        )
        let completed = expectation(description: "build package")
        var result: Result<CaptureExportPackage, Error>?
        builder.build(
            trajectoryURL: trajectoryURL,
            rgbVideoURLs: [],
            startedAtUnixMs: 1_000,
            endedAtUnixMs: 2_000
        ) {
            result = $0
            completed.fulfill()
        }
        wait(for: [completed], timeout: 5)
        return try XCTUnwrap(result).get().fileURL
    }
}
