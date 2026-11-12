import Foundation
import Security

extension ASCManager {
    /// Fresh native-browser export for the bundled legacy scripts only. The
    /// canonical ASC session is owned exclusively by the validated helper import.
    static func exportNativeWebSession(_ session: IrisSession) throws {
        let bridge = ASCAuthBridge()
        let existing = try? Data(contentsOf: bridge.webSessionURL)
        let data = try ASCWebSessionStore.mergedData(storing: session, into: existing)
        try bridge.syncWebSession(data)
    }

    static func removeNativeWebSessionExport(email: String?) {
        let bridge = ASCAuthBridge()
        guard let existing = try? Data(contentsOf: bridge.webSessionURL) else { return }
        do {
            if let updated = try ASCWebSessionStore.removingSession(email: email, from: existing) {
                try bridge.syncWebSession(updated)
            } else {
                bridge.removeWebSession()
            }
        } catch {
            // Do not delete an unrelated canonical CLI cache on an export error.
        }
    }

    static func readKeychainItem(service: String, account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    static func syncWebSessionFileFromKeychain() {
        // Intentionally no backfill. An old native/aggregate Keychain snapshot
        // cannot prove it is newer or stronger than the current CLI session.
        // A fresh browser login exports its own ASC cookies after validation.
    }
}
