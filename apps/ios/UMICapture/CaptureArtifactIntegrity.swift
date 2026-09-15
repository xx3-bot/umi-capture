import CryptoKit
import Foundation

struct CaptureArtifactDescriptor: Codable, Equatable {
    enum ProducerKind: String, Codable {
        case trajectory
        case rgbSegment = "rgb_segment"
    }

    let path: String
    let producerKind: ProducerKind
    let producerID: String
    let required: Bool
    let byteSize: UInt64
    let sha256: String

    enum CodingKeys: String, CodingKey {
        case path
        case producerKind = "producer_kind"
        case producerID = "producer_id"
        case required
        case byteSize = "byte_size"
        case sha256
    }
}

enum CaptureArtifactIntegrity {
    struct Digest: Equatable {
        let byteSize: UInt64
        let sha256: String
    }

    static func readSemanticData(
        from url: URL,
        trustedRootURL: URL
    ) throws -> Data {
        let canonicalURL = try validateRegularFile(
            url,
            trustedRootURL: trustedRootURL
        )
        let data = try Data(contentsOf: canonicalURL)
        guard !data.isEmpty else {
            throw CaptureArtifactIntegrityError.emptyFile(
                url.lastPathComponent
            )
        }
        return data
    }

    static func descriptor(
        path: String,
        producerKind: CaptureArtifactDescriptor.ProducerKind,
        producerID: String,
        required: Bool,
        data: Data
    ) throws -> CaptureArtifactDescriptor {
        guard !producerID.isEmpty else {
            throw CaptureArtifactIntegrityError.emptyProducerID
        }
        let normalizedPath = try normalizeArchivePath(path)
        guard !data.isEmpty else {
            throw CaptureArtifactIntegrityError.emptyFile(normalizedPath)
        }
        let digest = digest(data: data)
        return CaptureArtifactDescriptor(
            path: normalizedPath,
            producerKind: producerKind,
            producerID: producerID,
            required: required,
            byteSize: digest.byteSize,
            sha256: digest.sha256
        )
    }

    static func descriptor(
        path: String,
        producerKind: CaptureArtifactDescriptor.ProducerKind,
        producerID: String,
        required: Bool,
        fileURL: URL,
        trustedRootURL: URL
    ) throws -> CaptureArtifactDescriptor {
        guard !producerID.isEmpty else {
            throw CaptureArtifactIntegrityError.emptyProducerID
        }
        let normalizedPath = try normalizeArchivePath(path)
        let digest = try digest(
            fileURL: fileURL,
            trustedRootURL: trustedRootURL
        )
        guard digest.byteSize > 0 else {
            throw CaptureArtifactIntegrityError.emptyFile(
                fileURL.lastPathComponent
            )
        }
        return CaptureArtifactDescriptor(
            path: normalizedPath,
            producerKind: producerKind,
            producerID: producerID,
            required: required,
            byteSize: digest.byteSize,
            sha256: digest.sha256
        )
    }

    static func digest(data: Data) -> Digest {
        Digest(
            byteSize: UInt64(data.count),
            sha256: hex(SHA256.hash(data: data))
        )
    }

    static func digest(
        fileURL: URL,
        trustedRootURL: URL
    ) throws -> Digest {
        let canonicalURL = try validateRegularFile(
            fileURL,
            trustedRootURL: trustedRootURL
        )
        let input = try FileHandle(forReadingFrom: canonicalURL)
        defer {
            try? input.close()
        }
        var hasher = SHA256()
        var total: UInt64 = 0
        while let chunk = try autoreleasepool(invoking: {
            try input.read(upToCount: 1_048_576)
        }), !chunk.isEmpty {
            hasher.update(data: chunk)
            total += UInt64(chunk.count)
        }
        return Digest(
            byteSize: total,
            sha256: hex(hasher.finalize())
        )
    }

    static func normalizeArchivePath(_ path: String) throws -> String {
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        let components = normalized.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        guard !normalized.isEmpty,
              !normalized.hasPrefix("/"),
              !components.contains(".."),
              !components.contains("")
        else {
            throw CaptureArtifactIntegrityError.unsafeArchivePath(path)
        }
        return normalized
    }

    static func canonicalSourceURL(
        _ url: URL,
        trustedRootURL: URL
    ) throws -> URL {
        let standardizedRoot = trustedRootURL.standardizedFileURL
        let resolvedRoot = standardizedRoot.resolvingSymlinksInPath()
            .standardizedFileURL
        let standardizedCandidate = url.standardizedFileURL
        let resolvedCandidate = standardizedCandidate
            .resolvingSymlinksInPath()
            .standardizedFileURL

        guard contains(resolvedCandidate, in: resolvedRoot),
              let sourceRootRepresentation = sourceRootRepresentation(
                for: standardizedCandidate,
                resolvingTo: resolvedRoot
              )
        else {
            throw CaptureArtifactIntegrityError.outsideTrustedRoot(
                url.lastPathComponent
            )
        }
        try rejectSymlinksBelowRoot(
            candidate: standardizedCandidate,
            sourceRootRepresentation: sourceRootRepresentation
        )
        return resolvedCandidate
    }

    @discardableResult
    static func validateRegularFile(
        _ url: URL,
        trustedRootURL: URL
    ) throws -> URL {
        let canonical = try canonicalSourceURL(
            url,
            trustedRootURL: trustedRootURL
        )
        let values: URLResourceValues
        do {
            values = try canonical.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            )
        } catch {
            throw CaptureArtifactIntegrityError.missingOrUnreadableFile(
                url.lastPathComponent
            )
        }
        guard values.isSymbolicLink != true,
              values.isRegularFile == true
        else {
            throw CaptureArtifactIntegrityError.nonRegularFile(
                url.lastPathComponent
            )
        }
        return canonical
    }

    private static func contains(
        _ candidate: URL,
        in root: URL
    ) -> Bool {
        let rootPath = root.path == "/"
            ? "/"
            : root.path + "/"
        return candidate.path == root.path
            || candidate.path.hasPrefix(rootPath)
    }

    private static func sourceRootRepresentation(
        for candidate: URL,
        resolvingTo resolvedRoot: URL
    ) -> URL? {
        var ancestor = candidate
        while true {
            if ancestor.resolvingSymlinksInPath().standardizedFileURL.path
                == resolvedRoot.path {
                return ancestor
            }
            let parent = ancestor.deletingLastPathComponent()
            if parent.path == ancestor.path {
                return nil
            }
            ancestor = parent
        }
    }

    private static func rejectSymlinksBelowRoot(
        candidate: URL,
        sourceRootRepresentation: URL
    ) throws {
        let rootComponents = sourceRootRepresentation.pathComponents
        let candidateComponents = candidate.pathComponents
        guard candidateComponents.count >= rootComponents.count,
              Array(candidateComponents.prefix(rootComponents.count))
                == rootComponents
        else {
            throw CaptureArtifactIntegrityError.outsideTrustedRoot(
                candidate.lastPathComponent
            )
        }

        var current = sourceRootRepresentation
        for component in candidateComponents.dropFirst(
            rootComponents.count
        ) {
            current.appendPathComponent(component)
            if (try? FileManager.default.destinationOfSymbolicLink(
                atPath: current.path
            )) != nil {
                throw CaptureArtifactIntegrityError.symlinkSource(
                    component
                )
            }
        }
    }

    private static func hex<D: Sequence>(_ digest: D) -> String
    where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

enum CaptureArtifactIntegrityError: LocalizedError, Equatable {
    case missingOrUnreadableFile(String)
    case nonRegularFile(String)
    case symlinkSource(String)
    case outsideTrustedRoot(String)
    case emptyFile(String)
    case emptyProducerID
    case unsafeArchivePath(String)

    var errorDescription: String? {
        switch self {
        case .missingOrUnreadableFile(let name):
            return "Required capture artifact is missing or unreadable: \(name)."
        case .nonRegularFile(let name):
            return "Capture artifact is not a regular file: \(name)."
        case .symlinkSource(let name):
            return "Capture artifact uses an ambiguous symlink path: \(name)."
        case .outsideTrustedRoot(let name):
            return "Capture artifact is outside the trusted source root: \(name)."
        case .emptyFile(let name):
            return "Required capture artifact is empty: \(name)."
        case .emptyProducerID:
            return "Capture artifact producer identity is empty."
        case .unsafeArchivePath(let path):
            return "Capture artifact has an unsafe archive path: \(path)."
        }
    }
}
