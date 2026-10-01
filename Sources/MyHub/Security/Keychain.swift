import Foundation
import Security

/// Generic-password storage for every secret MyHub owns.
///
/// Items are this-device-only and never synchronised. The Security framework
/// is thread-safe, so these functions may be called from any isolation.
enum Keychain {
    static let service = "com.orazz.myhub.credentials"

    enum Failure: Error, Equatable {
        case status(OSStatus)
        case notUTF8
    }

    static func store(_ secret: Redacted<String>, account: String, service: String = Keychain.service) throws {
        let query = itemQuery(account: account, service: service)
        let attributes: [String: Any] = [
            kSecValueData as String: Data(secret.exposed.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let updated = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        switch updated {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var add = query.merging(attributes) { $1 }
            add[kSecAttrSynchronizable as String] = false
            let added = SecItemAdd(add as CFDictionary, nil)
            guard added == errSecSuccess else { throw Failure.status(added) }
        default:
            throw Failure.status(updated)
        }
    }

    static func secret(account: String, service: String = Keychain.service) throws -> Redacted<String>? {
        guard let data = try copyData(itemQuery(account: account, service: service)) else { return nil }
        guard let string = String(data: data, encoding: .utf8) else { throw Failure.notUTF8 }
        return Redacted(string)
    }

    static func remove(account: String, service: String = Keychain.service) throws {
        let status = SecItemDelete(itemQuery(account: account, service: service) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure.status(status) }
    }

    /// Reads an item that belongs to another app (e.g. Claude Code's OAuth
    /// credentials). Read-only by construction: there is no matching write.
    /// macOS asks the user before handing it over, so call this only after the
    /// user enabled the provider and was told what is about to happen.
    static func foreignItem(service: String, account: String? = nil) throws -> Redacted<Data>? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        if let account { query[kSecAttrAccount as String] = account }
        return try copyData(query).map(Redacted.init)
    }

    /// Whether another app's item exists, from its attributes alone. Asking
    /// for attributes never shows a prompt; only asking for the data does.
    static func foreignItemExists(service: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    // MARK: - Private

    private static func itemQuery(account: String, service: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static func copyData(_ query: [String: Any]) throws -> Data? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw Failure.status(status) }
        return result as? Data
    }
}
