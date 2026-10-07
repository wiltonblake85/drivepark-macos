// Keychain.swift: DrivePark's own secrets, in the login keychain.
//
// One today: the Transom token, which sat in plain text in the preferences
// domain, readable by anything running as this user with `defaults read`
// (audit, Low). The item is created by whichever DrivePark binary saves it,
// so macOS trusts that binary to read it back without asking; the other one
// (the app for a token saved by `park transom token`, or the reverse) gets
// the usual "allow access" prompt once.

import Foundation
import Security

enum Keychain {
    static let service = "com.wiltonblake.drivepark"

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func read(account: String) -> String? {
        var q = query(account)
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        q[kSecReturnData as String] = true
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// - Returns: the OSStatus, errSecSuccess when it was stored.
    @discardableResult
    static func write(_ value: String, account: String, label: String) -> OSStatus {
        let data = Data(value.utf8)
        let updated = SecItemUpdate(query(account) as CFDictionary,
                                    [kSecValueData as String: data] as CFDictionary)
        guard updated == errSecItemNotFound else { return updated }
        var add = query(account)
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = label
        return SecItemAdd(add as CFDictionary, nil)
    }

    /// - Returns: true when there is no such item afterwards.
    @discardableResult
    static func delete(account: String) -> Bool {
        let status = SecItemDelete(query(account) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
