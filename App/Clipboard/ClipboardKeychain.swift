import CryptoKit
import CueKit
import Foundation
import Security

/// The clipboard-history master key, stored as a generic password.
/// Tries the data-protection keychain first. Ad-hoc signed builds lack its entitlement, so they use the legacy keychain.
enum ClipboardKeychain {
    enum Kind: String, Sendable {
        case dataProtection = "data-protection", legacy
    }

    private static let account = "history-key"

    /// Returns the stored key. When none exists, creates one if `create` is true, otherwise returns nil.
    /// Blocking: run it off the main actor, because the legacy keychain may show a system prompt.
    static func load(service: String, create: Bool) throws -> (SymmetricKey, Kind)? {
        // Search both keychains before concluding the key is missing: a key saved by an ad-hoc build
        // must still be found by a later, properly signed build.
        for kind in [Kind.dataProtection, .legacy] {
            var query = base(service, kind)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: CFTypeRef?
            switch SecItemCopyMatching(query as CFDictionary, &result) {
            case errSecSuccess:
                guard let data = result as? Data, data.count == 32 else { throw ClipboardStore.keyUnavailable }
                return (SymmetricKey(data: data), kind)
            case errSecItemNotFound, errSecMissingEntitlement:
                continue
            default:
                throw ClipboardStore.keyUnavailable
            }
        }
        guard create else { return nil }
        let key = SymmetricKey(size: .bits256)
        for kind in [Kind.dataProtection, .legacy] {
            var query = base(service, kind)
            query[kSecValueData as String] = key.withUnsafeBytes { Data($0) }
            // The legacy keychain does not support this attribute (see SecItem.h).
            if kind == .dataProtection { query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly }
            query[kSecAttrLabel as String] = "Cue clipboard history key"
            let status = SecItemAdd(query as CFDictionary, nil)
            if status == errSecSuccess { return (key, kind) }
            if status != errSecMissingEntitlement { break }
        }
        throw CueError("HISTORY_KEY_CREATE_FAILED", "Cue could not save its clipboard key in the Keychain. Make sure your login keychain is unlocked, then try again.")
    }

    static func delete(service: String) {
        for kind in [Kind.dataProtection, .legacy] { SecItemDelete(base(service, kind) as CFDictionary) }
    }

    private static func base(_ service: String, _ kind: Kind) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if kind == .dataProtection { query[kSecUseDataProtectionKeychain as String] = true }
        return query
    }
}
