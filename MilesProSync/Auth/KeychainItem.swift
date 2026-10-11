import Foundation
import Security

/// One generic-password Keychain item. Readable after first unlock, so the app can still reach
/// the device account and cloud session when iOS relaunches it in the background while the
/// phone is locked (e.g. a trip ending in a parked car).
struct KeychainItem: Sendable {
    static let accountService = "com.aisleweb.MilesProSync.account"
    static let cloudSessionService = "com.aisleweb.MilesProSync.cloudSession"

    let service: String
    let account: String

    func read() -> Data? {
        var query = baseQuery
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    /// Replaces the item in place (so a failed write never loses the previous value), or deletes
    /// it when `data` is nil. Returns whether the Keychain now holds what was asked for.
    @discardableResult
    func write(_ data: Data?) -> Bool {
        guard let data else {
            let status = SecItemDelete(baseQuery as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }
        let updates: [CFString: Any] = [
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(baseQuery as CFDictionary, updates as CFDictionary)
        guard status == errSecItemNotFound else { return status == errSecSuccess }
        return SecItemAdd(baseQuery.merging(updates) { $1 } as CFDictionary, nil) == errSecSuccess
    }

    private var baseQuery: [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
    }

    private static let installMarkerKey = "app.installMarker"

    /// Keychain items survive deleting the app, but UserDefaults doesn't. On the first launch of
    /// a fresh install, remove everything this app keeps in the Keychain so a reinstall starts
    /// signed out, as the privacy policy promises. A build that predates the marker but already
    /// has a trip store is an upgrade, not a reinstall, so its items are kept.
    static func clearAllIfFreshInstall(
        defaults: UserDefaults = .standard,
        storageRoot: URL = UserStorage.applicationSupport
    ) {
        guard !defaults.bool(forKey: installMarkerKey) else { return }
        defer { defaults.set(true, forKey: installMarkerKey) }
        guard !UserStorage.anyStoreExists(root: storageRoot) else { return }
        for service in [accountService, cloudSessionService] {
            SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service] as CFDictionary)
        }
    }
}
