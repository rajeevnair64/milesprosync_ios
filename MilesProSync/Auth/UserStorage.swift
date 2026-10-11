import CryptoKit
import Foundation
import SwiftData

/// Where an account keeps its data: its own SwiftData store and its own settings (UserDefaults
/// suite), named by `DeviceAccount.storageKey`. Accounts saved when sign-in was required use
/// their Apple user ID as the key.
enum UserStorage {
    /// Directory and key name for an account: a hash, so an Apple user ID used as a key doesn't
    /// appear in file paths or preference names.
    static func folderName(for key: String) -> String {
        let digest = SHA256.hash(data: Data(key.utf8))
        return "user-" + digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    private static let storeFileName = "MilesProSync.store"

    static var applicationSupport: URL {
        URL.applicationSupportDirectory
    }

    static func directory(for key: String, root: URL) -> URL {
        root.appending(path: "Users", directoryHint: .isDirectory)
            .appending(path: folderName(for: key), directoryHint: .isDirectory)
    }

    static func storeURL(for key: String, root: URL) -> URL {
        directory(for: key, root: root).appending(path: storeFileName)
    }

    static func defaults(for key: String) -> UserDefaults {
        UserDefaults(suiteName: "com.aisleweb.MilesProSync.\(folderName(for: key))") ?? .standard
    }

    /// SwiftData's store from before sign-in existed.
    static func legacyStoreURL(root: URL) -> URL {
        root.appending(path: "default.store")
    }

    private static let keyFileName = "storage-key"

    /// Notes the storage key inside the account's folder (the folder name is only a hash). If the
    /// Keychain account is lost while the store survives (restore to a new iPhone: Keychain items
    /// here don't migrate, app data does), the key is read back from here.
    private static func recordKey(_ key: String, root: URL) {
        try? Data(key.utf8).write(to: directory(for: key, root: root).appending(path: keyFileName), options: .atomic)
    }

    /// Storage keys of the accounts that have a trip store on this device.
    static func existingStorageKeys(root: URL) -> [String] {
        let usersDirectory = root.appending(path: "Users", directoryHint: .isDirectory)
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: usersDirectory, includingPropertiesForKeys: nil
        )) ?? []
        return folders.compactMap { folder in
            guard FileManager.default.fileExists(atPath: folder.appending(path: storeFileName).path()),
                  let data = try? Data(contentsOf: folder.appending(path: keyFileName)),
                  let key = String(data: data, encoding: .utf8), !key.isEmpty else { return nil }
            return key
        }
    }

    /// True once any account on this device has a trip store.
    static func anyStoreExists(root: URL) -> Bool {
        let usersDirectory = root.appending(path: "Users", directoryHint: .isDirectory)
        let accounts = (try? FileManager.default.contentsOfDirectory(
            at: usersDirectory, includingPropertiesForKeys: nil
        )) ?? []
        return accounts.contains {
            FileManager.default.fileExists(atPath: $0.appending(path: storeFileName).path())
        }
    }

    static func storeExists(for key: String, root: URL) -> Bool {
        FileManager.default.fileExists(atPath: storeURL(for: key, root: root).path())
    }

    /// Opens (creating if needed) the account's store. The first account ever opened on this
    /// device takes over trips and settings recorded before per-account storage existed, so
    /// nothing recorded earlier is lost; later accounts start empty.
    static func makeContainer(
        for key: String,
        root: URL = applicationSupport,
        defaults: UserDefaults,
        legacyDefaults: UserDefaults = .standard
    ) throws -> ModelContainer {
        let fileManager = FileManager.default
        // "First" means no account has a store yet, not merely that `Users/` is missing: if adopting
        // the legacy store fails, the next launch must try again instead of starting empty.
        let isFirstAccount = !anyStoreExists(root: root)
        try fileManager.createDirectory(at: directory(for: key, root: root), withIntermediateDirectories: true)

        if isFirstAccount {
            try adoptLegacyStore(from: legacyStoreURL(root: root), to: storeURL(for: key, root: root))
            adoptLegacySettings(from: legacyDefaults, to: defaults)
        }

        recordKey(key, root: root)

        let configuration = ModelConfiguration(url: storeURL(for: key, root: root))
        return try ModelContainer(for: Trip.self, RoutePoint.self, configurations: configuration)
    }

    /// Moves the store and its SQLite side files (-shm, -wal).
    private static func adoptLegacyStore(from legacy: URL, to destination: URL) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: legacy.path()),
              !fileManager.fileExists(atPath: destination.path()) else { return }
        // Side files first, the main file last: a crash part-way leaves the main file at the legacy
        // path, so the next launch still sees a legacy store to adopt and the WAL is never stranded.
        for suffix in ["-wal", "-shm", ""] {
            let source = URL(filePath: legacy.path() + suffix)
            guard fileManager.fileExists(atPath: source.path()) else { continue }
            try fileManager.moveItem(at: source, to: URL(filePath: destination.path() + suffix))
        }
    }

    private static func adoptLegacySettings(from legacy: UserDefaults, to defaults: UserDefaults) {
        for key in [AppSettings.Key.countryCode, AppSettings.Key.mileageRate, AppSettings.Key.rateMode] {
            guard defaults.object(forKey: key) == nil, let value = legacy.object(forKey: key) else { continue }
            defaults.set(value, forKey: key)
            legacy.removeObject(forKey: key)
        }
    }
}
