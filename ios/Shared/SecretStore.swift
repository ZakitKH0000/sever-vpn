import Foundation
import Security

enum SecretStore {
    private static let service = "dev.sever.vpn"

    private static func query(_ account: String, shared: Bool) throws -> [String: Any] {
        let result: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                     kSecAttrService as String: service,
                                     kSecAttrAccount as String: account]
        // Both targets declare the same first Keychain access group. Let iOS use that
        // default group so re-signing does not leave a hard-coded developer Team ID in Info.plist.
        // The signer must retain the common group entitlement in both targets.
        return result
    }

    @discardableResult
    static func write(_ data: Data, account: String, shared: Bool = false) throws -> Data {
        let base = try query(account, shared: shared)
        let update = [kSecValueData as String: data]
        let status = SecItemUpdate(base as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = base
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else {
                throw SeverError.message("Не удалось сохранить данные в Keychain. Проверьте подпись приложения")
            }
        } else if status != errSecSuccess {
            throw SeverError.message("Keychain недоступен. Проверьте подпись приложения")
        }
        var lookup = base
        lookup[kSecReturnPersistentRef as String] = true
        var reference: CFTypeRef?
        guard SecItemCopyMatching(lookup as CFDictionary, &reference) == errSecSuccess,
              let value = reference as? Data else { throw SeverError.message("Не удалось получить ссылку Keychain") }
        return value
    }

    static func read(account: String, shared: Bool = false) throws -> Data? {
        var lookup = try query(account, shared: shared)
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw SeverError.message("Не удалось прочитать Keychain")
        }
        return data
    }

    static func read(reference: Data) throws -> Data {
        let lookup: [String: Any] = [kSecValuePersistentRef as String: reference,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(lookup as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else {
            throw SeverError.message("VPN-расширение не получило доступ к конфигурации. Проверьте общую группу Keychain при подписи")
        }
        return data
    }
}
