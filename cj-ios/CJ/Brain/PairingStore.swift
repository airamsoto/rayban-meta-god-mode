import Foundation
import Security

/// Remembers which brain this iPhone is paired with: the address in UserDefaults, the token in the Keychain.
enum PairingStore {
    private static let urlKey = "brain_url"
    private static let service = "com.airamsoto.cj.pairing"
    private static let account = "token"

    static func load() -> Pairing? {
        guard let url = UserDefaults.standard.string(forKey: urlKey), let token = readToken() else { return nil }
        return Pairing(url: url, token: token)
    }

    static func save(_ pairing: Pairing) {
        UserDefaults.standard.set(pairing.url.trimmingCharacters(in: .whitespacesAndNewlines), forKey: urlKey)
        writeToken(pairing.token.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: urlKey)
        SecItemDelete(query() as CFDictionary)
    }

    private static func query() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    private static func readToken() -> String? {
        var q = query()
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func writeToken(_ token: String) {
        SecItemDelete(query() as CFDictionary)
        var q = query()
        q[kSecValueData as String] = Data(token.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
    }
}
