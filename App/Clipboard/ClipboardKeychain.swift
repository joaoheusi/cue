import CryptoKit
import CueKit
import Foundation
import Security

enum ClipboardKeychain {
    enum Kind: String, Sendable {
        case dataProtection = "data-protection", legacy
    }

    static let account = "history-key"

    static func load(service: String, create: Bool) throws -> (SymmetricKey, Kind)? {
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

    static func base(_ service: String, _ kind: Kind, account: String = account) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if kind == .dataProtection { query[kSecUseDataProtectionKeychain as String] = true }
        return query
    }
}

enum ClaudeKey {
    private static let account = "anthropic-api-key"

    static func load(service: String) -> String? {
        for kind in [ClipboardKeychain.Kind.dataProtection, .legacy] {
            var query = ClipboardKeychain.base(service, kind, account: account)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: CFTypeRef?
            if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data {
                return String(decoding: data, as: UTF8.self)
            }
        }
        return nil
    }

    static func save(_ key: String, service: String) throws(CueError) {
        let data = Data(key.utf8)
        for kind in [ClipboardKeychain.Kind.dataProtection, .legacy] {
            let entry = ClipboardKeychain.base(service, kind, account: account)
            var status = SecItemUpdate(entry as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            if status == errSecItemNotFound {
                var added = entry
                added[kSecValueData as String] = data
                if kind == .dataProtection { added[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly }
                added[kSecAttrLabel as String] = "Cue Anthropic API key"
                status = SecItemAdd(added as CFDictionary, nil)
            }
            if status == errSecSuccess {
                let other: ClipboardKeychain.Kind = kind == .dataProtection ? .legacy : .dataProtection
                SecItemDelete(ClipboardKeychain.base(service, other, account: account) as CFDictionary)
                return
            }
            if status != errSecMissingEntitlement { break }
        }
        throw CueError("KEY_SAVE_FAILED", "Cue could not save the key in the Keychain. Make sure your login keychain is unlocked, then try again.")
    }

    static func delete(service: String) {
        for kind in [ClipboardKeychain.Kind.dataProtection, .legacy] {
            SecItemDelete(ClipboardKeychain.base(service, kind, account: account) as CFDictionary)
        }
    }
}
