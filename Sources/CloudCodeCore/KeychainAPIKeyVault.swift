import Foundation
import Security

public final class KeychainAPIKeyVault: APIKeyVault, @unchecked Sendable {
    private let service: String

    public init(service: String = "CloudCodeIOS.ProviderKey") {
        self.service = service
    }

    public func set(_ value: String, for reference: String) throws {
        guard !reference.isEmpty, !value.isEmpty else { throw ProviderError.missingAPIKey }
        let data = Data(value.utf8)
        let query = baseQuery(reference: reference)
        let update: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw statusError(updateStatus) }

        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw statusError(status) }
    }

    public func remove(_ reference: String) throws {
        let status = SecItemDelete(baseQuery(reference: reference) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw statusError(status) }
    }

    public func contains(_ reference: String) -> Bool {
        var query = baseQuery(reference: reference)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    public func key(for reference: String) async throws -> String {
        var query = baseQuery(reference: reference)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty else {
            if status == errSecItemNotFound { throw ProviderError.missingAPIKey }
            if status != errSecSuccess { throw statusError(status) }
            throw ProviderError.missingAPIKey
        }
        return value
    }

    private func baseQuery(reference: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: reference
        ]
    }

    private func statusError(_ status: OSStatus) -> NSError {
        NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [
            NSLocalizedDescriptionKey: SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)"
        ])
    }
}
