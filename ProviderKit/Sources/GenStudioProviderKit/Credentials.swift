import Foundation
import Security

public protocol CloudCredentialStore: Sendable {
    func apiKey(for provider: CloudProvider) throws -> String?
    func setAPIKey(_ apiKey: String, for provider: CloudProvider) throws
    func deleteAPIKey(for provider: CloudProvider) throws
}

public struct KeychainCredentialStore: CloudCredentialStore, Sendable {
    public static let service = "studio.gen.GenStudio.ProviderKit"

    public init() {}

    public func apiKey(for provider: CloudProvider) throws -> String? {
        var query = baseQuery(provider: provider)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8) else {
            throw CloudProviderError.credentialStoreFailure
        }
        return key
    }

    public func setAPIKey(_ apiKey: String, for provider: CloudProvider) throws {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CloudProviderError.invalidAPIKey
        }
        guard let data = apiKey.data(using: .utf8) else {
            throw CloudProviderError.invalidAPIKey
        }
        let query = baseQuery(provider: provider)
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw CloudProviderError.credentialStoreFailure
        }
        var newItem = query
        newItem[kSecValueData as String] = data
        let addStatus = SecItemAdd(newItem as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw CloudProviderError.credentialStoreFailure
        }
    }

    public func deleteAPIKey(for provider: CloudProvider) throws {
        let status = SecItemDelete(baseQuery(provider: provider) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CloudProviderError.credentialStoreFailure
        }
    }

    private func baseQuery(provider: CloudProvider) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: provider.rawValue
        ]
    }
}
