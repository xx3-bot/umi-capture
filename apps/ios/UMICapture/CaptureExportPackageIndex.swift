import CryptoKit
import Darwin
import Foundation
import zlib

struct CaptureExportPackageIndex {
    struct Snapshot {
        let completed: [CaptureExportPackageRecord]
        let recovery: [CaptureExportRecoveryRecord]
        let diagnostics: [String]

        static let empty = Snapshot(
            completed: [],
            recovery: [],
            diagnostics: []
        )
    }

    private static let manifestLimit = 2 * 1_024 * 1_024
    private static let readmeLimit = 1 * 1_024 * 1_024

    let directoryURL: URL
    let preexistingWritingIdentities: [String: CaptureFileIdentity]

    static func capturePreexistingWritingIdentities(
        directoryURL: URL
    ) -> [String: CaptureFileIdentity] {
        guard (try? validatedManagedRoot(directoryURL)) != nil else {
            return [:]
        }
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: []
        ) else {
            return [:]
        }
        return Dictionary(
            uniqueKeysWithValues: urls.compactMap { url in
                guard url.lastPathComponent.hasSuffix(".writing"),
                      let identity = try? regularDirectChildIdentity(
                          url,
                          directoryURL: directoryURL
                      )
                else {
                    return nil
                }
                return (url.lastPathComponent, identity)
            }
        )
    }

    func scan() -> Snapshot {
        guard FileManager.default.fileExists(atPath: directoryURL.path)
        else {
            return .empty
        }
        guard (try? Self.validatedManagedRoot(directoryURL)) != nil else {
            return Snapshot(
                completed: [],
                recovery: [],
                diagnostics: ["Ignored unsafe capture package directory."]
            )
        }
        let urls: [URL]
        do {
            urls = try FileManager.default.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: nil,
                options: []
            )
        } catch {
            return Snapshot(
                completed: [],
                recovery: [],
                diagnostics: ["Could not read capture packages."]
            )
        }

        var completed: [CaptureExportPackageRecord] = []
        var recovery: [CaptureExportRecoveryRecord] = []
        var diagnostics: [String] = []
        for url in urls.sorted(by: {
            $0.lastPathComponent < $1.lastPathComponent
        }) {
            let name = url.lastPathComponent
            let identity: CaptureFileIdentity
            do {
                identity = try Self.regularDirectChildIdentity(
                    url,
                    directoryURL: directoryURL
                )
            } catch {
                diagnostics.append("Ignored unsafe package entry: \(name)")
                continue
            }

            if name.hasSuffix(".writing") {
                let isPreexisting = preexistingWritingIdentities[name]
                    == identity
                recovery.append(
                    CaptureExportRecoveryRecord(
                        id: "writing:\(identity.device):\(identity.inode)",
                        displayName: name,
                        fileURL: url,
                        identity: identity,
                        state: .incompleteWriting,
                        isDeletionEligible: isPreexisting,
                        diagnostic: isPreexisting
                            ? "Incomplete export preserved from a previous launch."
                            : "Export is active or was created during this launch."
                    )
                )
                continue
            }
            guard url.pathExtension.lowercased() == "zip" else {
                diagnostics.append("Ignored unrecognized package entry: \(name)")
                continue
            }

            do {
                let manifest = try Self.validateArchive(url)
                completed.append(
                    CaptureExportPackageRecord(
                        id: "zip:\(identity.device):\(identity.inode)",
                        packageID: manifest.packageID,
                        displayName: name,
                        fileURL: url,
                        identity: identity,
                        createdAtUnixMs: manifest.createdAtUnixMs
                    )
                )
            } catch {
                recovery.append(
                    CaptureExportRecoveryRecord(
                        id: "corrupt:\(identity.device):\(identity.inode)",
                        displayName: name,
                        fileURL: url,
                        identity: identity,
                        state: .corruptPackage,
                        isDeletionEligible: true,
                        diagnostic: "Package is incomplete or corrupt and cannot be shared."
                    )
                )
            }
        }

        let duplicateIDs = Set(
            Dictionary(grouping: completed, by: \.packageID)
                .filter { $0.value.count > 1 }
                .keys
        )
        if !duplicateIDs.isEmpty {
            let conflicted = completed.filter {
                duplicateIDs.contains($0.packageID)
            }
            completed.removeAll { duplicateIDs.contains($0.packageID) }
            recovery.append(contentsOf: conflicted.map { record in
                CaptureExportRecoveryRecord(
                    id: record.id,
                    displayName: record.displayName,
                    fileURL: record.fileURL,
                    identity: record.identity,
                    state: .identityConflict,
                    isDeletionEligible: true,
                    diagnostic: "Duplicate package identity; package is not shareable."
                )
            })
        }
        completed.sort { $0.createdAtUnixMs > $1.createdAtUnixMs }
        recovery.sort { $0.displayName > $1.displayName }
        return Snapshot(
            completed: completed,
            recovery: recovery,
            diagnostics: diagnostics
        )
    }

    static func identityStillMatches(
        url: URL,
        expected: CaptureFileIdentity,
        directoryURL: URL
    ) -> Bool {
        (try? regularDirectChildIdentity(
            url,
            directoryURL: directoryURL
        )) == expected
    }
}

private extension CaptureExportPackageIndex {
    // Keep the indexing envelope independent of additive package metadata.
    // Legacy ZIPs omit software_provenance, while current ZIPs include it.
    struct Manifest: Decodable {
        let schemaVersion: Int
        let kind: String
        let packageID: String
        let createdAtUnixMs: Int64
        let completionState: String
        let integritySchemaVersion: Int
        let artifactIntegrity: [CaptureArtifactDescriptor]

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case kind
            case packageID = "package_id"
            case createdAtUnixMs = "created_at_unix_ms"
            case completionState = "completion_state"
            case integritySchemaVersion = "integrity_schema_version"
            case artifactIntegrity = "artifact_integrity"
        }
    }

    struct CentralEntry {
        let name: String
        let crc32: UInt32
        let size: UInt64
        let localOffset: UInt64
    }

    static func validateArchive(_ url: URL) throws -> Manifest {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let fileSize = try handle.seekToEnd()
        guard fileSize >= 22, fileSize <= UInt64(UInt32.max) else {
            throw IndexError.invalidArchive
        }
        let tailSize = min(fileSize, UInt64(65_557))
        try handle.seek(toOffset: fileSize - tailSize)
        let tail = try readExactly(handle, count: Int(tailSize))
        guard let relativeEOCD = tail.lastRange(
            of: Data([0x50, 0x4b, 0x05, 0x06])
        )?.lowerBound else {
            throw IndexError.invalidArchive
        }
        let eocd = fileSize - tailSize + UInt64(relativeEOCD)
        guard eocd + 22 == fileSize,
              try tail.u16(relativeEOCD + 4) == 0,
              try tail.u16(relativeEOCD + 6) == 0,
              try tail.u16(relativeEOCD + 8)
                == tail.u16(relativeEOCD + 10),
              try tail.u16(relativeEOCD + 20) == 0
        else {
            throw IndexError.invalidArchive
        }
        let count = Int(try tail.u16(relativeEOCD + 10))
        let centralSize = UInt64(try tail.u32(relativeEOCD + 12))
        let centralOffset = UInt64(try tail.u32(relativeEOCD + 16))
        guard centralOffset + centralSize == eocd, count > 0 else {
            throw IndexError.invalidArchive
        }

        var cursor = centralOffset
        var entries: [CentralEntry] = []
        var names: Set<String> = []
        for _ in 0..<count {
            try handle.seek(toOffset: cursor)
            let fixed = try readExactly(handle, count: 46)
            guard try fixed.u32(0) == 0x02014b50,
                  try fixed.u16(8) == 0x0808,
                  try fixed.u16(10) == 0,
                  try fixed.u32(20) == fixed.u32(24)
            else {
                throw IndexError.invalidArchive
            }
            let nameLength = Int(try fixed.u16(28))
            let extraLength = Int(try fixed.u16(30))
            let commentLength = Int(try fixed.u16(32))
            let nameData = try readExactly(handle, count: nameLength)
            guard let name = String(data: nameData, encoding: .utf8),
                  try safeArchiveName(name),
                  names.insert(name).inserted
            else {
                throw IndexError.invalidArchive
            }
            if extraLength + commentLength > 0 {
                _ = try readExactly(
                    handle,
                    count: extraLength + commentLength
                )
            }
            entries.append(
                CentralEntry(
                    name: name,
                    crc32: try fixed.u32(16),
                    size: UInt64(try fixed.u32(20)),
                    localOffset: UInt64(try fixed.u32(42))
                )
            )
            cursor += UInt64(46 + nameLength + extraLength + commentLength)
        }
        guard cursor == centralOffset + centralSize else {
            throw IndexError.invalidArchive
        }

        var occupied: [Range<UInt64>] = []
        var controlData: [String: Data] = [:]
        var artifactDigests: [String: CaptureArtifactIntegrity.Digest] = [:]
        for entry in entries {
            if entry.name == "capture_manifest.json",
               entry.size > UInt64(manifestLimit) {
                throw IndexError.invalidArchive
            }
            if entry.name == "README.txt",
               entry.size > UInt64(readmeLimit) {
                throw IndexError.invalidArchive
            }
            let result = try validateEntry(
                entry,
                handle: handle,
                centralOffset: centralOffset
            )
            guard !occupied.contains(where: { $0.overlaps(result.range) })
            else {
                throw IndexError.invalidArchive
            }
            occupied.append(result.range)
            if entry.name == "capture_manifest.json" {
                controlData[entry.name] = result.controlData
            } else if entry.name == "README.txt" {
                controlData[entry.name] = result.controlData
            } else {
                artifactDigests[entry.name] = result.digest
            }
        }
        guard let manifestData = controlData["capture_manifest.json"],
              controlData["README.txt"] != nil
        else {
            throw IndexError.invalidArchive
        }
        let manifest = try JSONDecoder().decode(
            Manifest.self,
            from: manifestData
        )
        guard manifest.schemaVersion == 1,
              manifest.kind == "iphonevio_capture_export",
              !manifest.packageID.isEmpty,
              manifest.completionState == "completed",
              manifest.integritySchemaVersion == 1,
              !manifest.artifactIntegrity.isEmpty,
              manifest.artifactIntegrity.count == artifactDigests.count,
              Set(manifest.artifactIntegrity.map(\.path)).count
                == manifest.artifactIntegrity.count
        else {
            throw IndexError.invalidArchive
        }
        for descriptor in manifest.artifactIntegrity {
            guard !descriptor.producerID.isEmpty,
                  try safeArchiveName(descriptor.path),
                  let digest = artifactDigests[descriptor.path],
                  digest.byteSize == descriptor.byteSize,
                  digest.sha256 == descriptor.sha256
            else {
                throw IndexError.invalidArchive
            }
        }
        return manifest
    }

    static func validateEntry(
        _ entry: CentralEntry,
        handle: FileHandle,
        centralOffset: UInt64
    ) throws -> (
        range: Range<UInt64>,
        digest: CaptureArtifactIntegrity.Digest,
        controlData: Data
    ) {
        guard entry.localOffset + 30 <= centralOffset else {
            throw IndexError.invalidArchive
        }
        try handle.seek(toOffset: entry.localOffset)
        let local = try readExactly(handle, count: 30)
        guard try local.u32(0) == 0x04034b50,
              try local.u16(6) == 0x0808,
              try local.u16(8) == 0,
              try local.u32(14) == 0,
              try local.u32(18) == 0,
              try local.u32(22) == 0,
              try local.u16(28) == 0
        else {
            throw IndexError.invalidArchive
        }
        let nameLength = Int(try local.u16(26))
        let localNameData = try readExactly(handle, count: nameLength)
        guard String(data: localNameData, encoding: .utf8) == entry.name
        else {
            throw IndexError.invalidArchive
        }
        let dataStart = entry.localOffset + UInt64(30 + nameLength)
        let descriptorOffset = dataStart + entry.size
        let end = descriptorOffset + 16
        guard end <= centralOffset else {
            throw IndexError.invalidArchive
        }
        try handle.seek(toOffset: dataStart)
        var checksum = zlib.crc32(0, nil, 0)
        var hasher = SHA256()
        var remaining = entry.size
        var control = Data()
        while remaining > 0 {
            let count = Int(min(remaining, 1_048_576))
            let chunk = try readExactly(handle, count: count)
            checksum = chunk.withUnsafeBytes { bytes in
                zlib.crc32(
                    checksum,
                    bytes.bindMemory(to: Bytef.self).baseAddress,
                    uInt(chunk.count)
                )
            }
            hasher.update(data: chunk)
            if entry.name == "capture_manifest.json"
                || entry.name == "README.txt" {
                control.append(chunk)
            }
            remaining -= UInt64(chunk.count)
        }
        let descriptor = try readExactly(handle, count: 16)
        guard try descriptor.u32(0) == 0x08074b50,
              try descriptor.u32(4) == entry.crc32,
              try descriptor.u32(8) == UInt32(entry.size),
              try descriptor.u32(12) == UInt32(entry.size),
              UInt32(checksum) == entry.crc32
        else {
            throw IndexError.invalidArchive
        }
        return (
            entry.localOffset..<end,
            CaptureArtifactIntegrity.Digest(
                byteSize: entry.size,
                sha256: hasher.finalize().map {
                    String(format: "%02x", $0)
                }.joined()
            ),
            control
        )
    }

    static func regularDirectChildIdentity(
        _ url: URL,
        directoryURL: URL
    ) throws -> CaptureFileIdentity {
        let root = try validatedManagedRoot(directoryURL)
        let candidate = url.standardizedFileURL
        guard candidate.deletingLastPathComponent().path
                == directoryURL.standardizedFileURL.path,
              candidate.lastPathComponent != ".",
              candidate.lastPathComponent != ".."
        else {
            throw IndexError.unsafeFile
        }
        var value = stat()
        guard lstat(candidate.path, &value) == 0,
              (value.st_mode & S_IFMT) == S_IFREG,
              candidate.resolvingSymlinksInPath().standardizedFileURL
                .deletingLastPathComponent().path == root.path
        else {
            throw IndexError.unsafeFile
        }
        return CaptureFileIdentity(
            device: UInt64(value.st_dev),
            inode: UInt64(value.st_ino),
            byteSize: UInt64(max(0, value.st_size)),
            modificationSeconds: Int64(value.st_mtimespec.tv_sec),
            modificationNanoseconds: Int64(value.st_mtimespec.tv_nsec)
        )
    }

    static func validatedManagedRoot(_ directoryURL: URL) throws -> URL {
        let standardized = directoryURL.standardizedFileURL
        var value = stat()
        guard lstat(standardized.path, &value) == 0,
              (value.st_mode & S_IFMT) == S_IFDIR
        else {
            throw IndexError.unsafeFile
        }
        return standardized.resolvingSymlinksInPath().standardizedFileURL
    }

    static func safeArchiveName(_ name: String) throws -> Bool {
        try CaptureArtifactIntegrity.normalizeArchivePath(name) == name
    }

    static func readExactly(
        _ handle: FileHandle,
        count: Int
    ) throws -> Data {
        guard count >= 0,
              let data = try handle.read(upToCount: count),
              data.count == count
        else {
            throw IndexError.invalidArchive
        }
        return data
    }

    enum IndexError: Error {
        case invalidArchive
        case unsafeFile
    }
}

private extension Data {
    func u16(_ offset: Int) throws -> UInt16 {
        guard offset >= 0, offset + 2 <= count else {
            throw CaptureExportPackageIndex.IndexError.invalidArchive
        }
        return UInt16(self[offset])
            | (UInt16(self[offset + 1]) << 8)
    }

    func u32(_ offset: Int) throws -> UInt32 {
        guard offset >= 0, offset + 4 <= count else {
            throw CaptureExportPackageIndex.IndexError.invalidArchive
        }
        return UInt32(self[offset])
            | (UInt32(self[offset + 1]) << 8)
            | (UInt32(self[offset + 2]) << 16)
            | (UInt32(self[offset + 3]) << 24)
    }
}
