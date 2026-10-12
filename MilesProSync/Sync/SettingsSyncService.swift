import Foundation

/// Keeps the reimbursement settings (`SettingsPayload`) the same on every device and on the
/// website. The server's copy is the reference; this device remembers the last copy it matched
/// (`payloadKey`) and the server time it carried (`baseKey`), so:
///   - settings never saved for this account: the server's copy is applied if there is one,
///     otherwise this device's is uploaded;
///   - this device's settings differ from the last matched copy: they are uploaded, and if the
///     server's are newer (another device saved first) the server's are applied instead;
///   - otherwise the server is checked now and then, so a change made elsewhere arrives.
/// Failures are silent: the next sync attempt (launch, foreground, a trip, a settings change) retries.
@MainActor
final class SettingsSyncService {
    static let baseKey = "settings.sync.baseUpdatedAt"
    static let payloadKey = "settings.sync.payload"
    static let userIDKey = "settings.sync.userID"
    /// How long a matched copy is trusted before the server is asked again.
    static let pullInterval: TimeInterval = 5 * 60

    private let client: APIClient?
    private let defaults: UserDefaults
    private let isSignedIn: () -> Bool
    private let now: () -> Date
    private var lastPull: Date?
    private var isSyncing = false
    private var needsAnotherPass = false
    /// Bumped on sign-in and sign-out; a pass that started earlier must not write its result.
    private var epoch = 0
    private var debounced: Task<Void, Never>?
    private var observer: (any NSObjectProtocol)?

    init(
        client: APIClient?, defaults: UserDefaults, isSignedIn: @escaping () -> Bool,
        now: @escaping () -> Date = Date.init
    ) {
        self.client = client
        self.defaults = defaults
        self.isSignedIn = isSignedIn
        self.now = now
    }

    /// Starts watching for settings changes on this device.
    func start() {
        guard client != nil, observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: defaults, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.settingsMayHaveChanged() }
        }
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        debounced?.cancel()
    }

    /// The account is connected: check the server right away. A different account than the one
    /// these settings last matched starts over, so another person's saved time is never reused.
    func didSignIn(userID: String) {
        epoch += 1
        if defaults.string(forKey: Self.userIDKey) != userID {
            defaults.removeObject(forKey: Self.baseKey)
            defaults.removeObject(forKey: Self.payloadKey)
            defaults.set(userID, forKey: Self.userIDKey)
        }
        lastPull = nil
        syncNow()
    }

    func didSignOut() {
        epoch += 1
        lastPull = nil
        debounced?.cancel()
    }

    func syncNow() {
        Task { await sync() }
    }

    private func settingsMayHaveChanged() {
        guard isSignedIn() else { return }
        debounced?.cancel()
        debounced = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await sync()
        }
    }

    func sync() async {
        guard client != nil, isSignedIn() else { return }
        guard !isSyncing else {
            needsAnotherPass = true
            return
        }
        isSyncing = true
        defer { isSyncing = false }
        repeat {
            needsAnotherPass = false
            await pass()
        } while needsAnotherPass && isSignedIn()
    }

    private var base: String? { defaults.string(forKey: Self.baseKey) }

    private var lastMatched: SettingsPayload? {
        defaults.data(forKey: Self.payloadKey).flatMap { try? JSONDecoder().decode(SettingsPayload.self, from: $0) }
    }

    private func pass() async {
        guard let client else { return }
        let passEpoch = epoch
        let current = SettingsPayload(defaults: defaults)
        do {
            if base == nil {
                // Never matched with this account.
                if let remote = try await client.fetchSettings() {
                    finish(.pulled(remote), passEpoch)
                } else {
                    finish(.pushed(try await client.saveSettings(current, baseUpdatedAt: nil)), passEpoch)
                }
            } else if current != lastMatched {
                do {
                    finish(.pushed(try await client.saveSettings(current, baseUpdatedAt: base)), passEpoch)
                } catch SyncError.server(status: 409, _) {
                    // Another device saved after this one last synced: theirs wins.
                    if let remote = try await client.fetchSettings() { finish(.pulled(remote), passEpoch) }
                }
            } else if lastPull.map({ now().timeIntervalSince($0) >= Self.pullInterval }) ?? true {
                if let remote = try await client.fetchSettings(), remote.updatedAt != base {
                    finish(.pulled(remote), passEpoch)
                } else {
                    lastPull = now()
                }
            }
        } catch {
            // Offline, rate limited or signed out: try again at the next trigger.
        }
    }

    private enum Outcome {
        case pushed(SettingsRecord)
        case pulled(SettingsRecord)

        var record: SettingsRecord {
            switch self {
            case .pushed(let record), .pulled(let record): record
            }
        }
    }

    /// Remembers the server's copy as matched and makes this device equal to it. Writing the
    /// device's settings too (even after an upload) keeps values the server rounded in step, so
    /// they are not uploaded again.
    private func finish(_ outcome: Outcome, _ passEpoch: Int) {
        guard passEpoch == epoch, isSignedIn() else { return }
        let record = outcome.record
        guard let data = try? JSONEncoder().encode(record.settings),
              record.settings.apply(to: defaults) else { return }
        defaults.set(record.updatedAt, forKey: Self.baseKey)
        defaults.set(data, forKey: Self.payloadKey)
        lastPull = now()
    }
}
