import Foundation

struct ReceiverConnectionTarget: Equatable {
    let host: String
    let port: Int
    let displayName: String?

    init(host: String, port: Int, displayName: String? = nil) {
        self.host = host
        self.port = port
        self.displayName = displayName
    }
}

struct ReceiverSelectionCredentialDecision: Equatable {
    let token: String

    static func resolve(
        userEnteredToken: String,
        storedToken: String?
    ) -> ReceiverSelectionCredentialDecision {
        let entered = userEnteredToken.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        if !entered.isEmpty {
            return ReceiverSelectionCredentialDecision(
                token: entered
            )
        }
        let stored = storedToken?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ) ?? ""
        return ReceiverSelectionCredentialDecision(
            token: stored
        )
    }
}

struct ReceiverEndpoint: Identifiable, Equatable, Hashable {
    static let serviceType = "_umicapture._tcp"
    static let protocolVersion = "1"

    let stableID: UUID
    let displayName: String
    let host: String
    let port: Int
    let serviceName: String

    var id: String {
        stableID.uuidString.lowercased()
    }

    var connectionTarget: ReceiverConnectionTarget {
        ReceiverConnectionTarget(
            host: host,
            port: port,
            displayName: displayName
        )
    }

    static func decode(
        txtRecord: Data?,
        host: String,
        port: Int,
        serviceName: String
    ) -> ReceiverEndpoint? {
        guard
            let txtRecord,
            port > 0,
            port <= 65_535
        else {
            return nil
        }

        let fields = NetService.dictionary(fromTXTRecord: txtRecord)
        guard Set(fields.keys) == ["id", "name", "version"] else {
            return nil
        }
        guard
            let stableIDText = utf8Value(fields["id"]),
            let stableID = UUID(uuidString: stableIDText),
            let displayName = utf8Value(fields["name"]),
            !displayName.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty,
            utf8Value(fields["version"]) == protocolVersion
        else {
            return nil
        }

        let normalizedHost = host.hasSuffix(".")
            ? String(host.dropLast())
            : host
        guard !normalizedHost.isEmpty else {
            return nil
        }

        return ReceiverEndpoint(
            stableID: stableID,
            displayName: displayName,
            host: normalizedHost,
            port: port,
            serviceName: serviceName
        )
    }

    private static func utf8Value(_ data: Data?) -> String? {
        guard let data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}

struct ReceiverEndpointStore {
    private struct Entry {
        let endpoint: ReceiverEndpoint
        let sequence: UInt64
    }

    private var entriesByServiceKey: [String: Entry] = [:]
    private var sequence: UInt64 = 0

    var endpoints: [ReceiverEndpoint] {
        var latestByStableID: [String: Entry] = [:]
        for entry in entriesByServiceKey.values {
            let key = entry.endpoint.id
            if let current = latestByStableID[key],
               current.sequence > entry.sequence {
                continue
            }
            latestByStableID[key] = entry
        }
        return latestByStableID.values
            .map(\.endpoint)
            .sorted {
                if $0.displayName == $1.displayName {
                    return $0.id < $1.id
                }
                return $0.displayName.localizedStandardCompare(
                    $1.displayName
                ) == .orderedAscending
            }
    }

    mutating func upsert(
        _ endpoint: ReceiverEndpoint,
        serviceKey: String
    ) {
        sequence &+= 1
        entriesByServiceKey[serviceKey] = Entry(
            endpoint: endpoint,
            sequence: sequence
        )
    }

    mutating func remove(serviceKey: String) {
        entriesByServiceKey.removeValue(forKey: serviceKey)
    }

    mutating func removeAll() {
        entriesByServiceKey.removeAll()
    }

    func preferred(stableID: String) -> ReceiverEndpoint? {
        endpoints.first {
            $0.id.caseInsensitiveCompare(stableID) == .orderedSame
        }
    }
}
