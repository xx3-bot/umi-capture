import Foundation
import Security

enum CaptureDeviceIdentity {
    private static let defaultsKey = "UMICapture.captureDeviceID"

    static func stableDeviceID(
        defaults: UserDefaults = .standard
    ) -> String {
        if let existing = defaults.string(forKey: defaultsKey),
           UUID(uuidString: existing) != nil {
            return existing.lowercased()
        }
        let created = UUID().uuidString.lowercased()
        defaults.set(created, forKey: defaultsKey)
        return created
    }
}

enum ReceiverCredentialStore {
    private static let service = "org.umicapture.capture.receiver-token"

    static func token(receiverID: String) -> String? {
        var query = baseQuery(receiverID: receiverID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(
            query as CFDictionary,
            &result
        ) == errSecSuccess,
        let data = result as? Data,
        let token = String(data: data, encoding: .utf8),
        !token.isEmpty else {
            return nil
        }
        return token
    }

    static func store(token: String?, receiverID: String) -> Bool {
        let normalized = token?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ) ?? ""
        let query = baseQuery(receiverID: receiverID)
        SecItemDelete(query as CFDictionary)
        guard !normalized.isEmpty else {
            return true
        }
        var item = query
        item[kSecValueData as String] = Data(normalized.utf8)
        item[kSecAttrAccessible as String] =
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    private static func baseQuery(receiverID: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: receiverID.lowercased()
        ]
    }
}
