import BackgroundTasks
import Foundation
import Observation
import SwiftData
import UIKit

/// Schedules a later attempt when trips are still waiting to upload.
@MainActor
protocol SyncRetryScheduler {
    func scheduleRetry()
}

/// Retries via a background app refresh task, so trips that failed to upload (no signal at the
/// end of a drive, server down) go up later even if the user never opens the app.
struct BackgroundRefreshRetryScheduler: SyncRetryScheduler {
    /// Must match BGTaskSchedulerPermittedIdentifiers in Info.plist.
    static let taskIdentifier = "com.aisleweb.MilesProSync.sync"
    /// iOS decides the actual time from usage patterns; this is only the earliest it may run.
    static let retryDelay: TimeInterval = 15 * 60

    func scheduleRetry() {
        let request = BGAppRefreshTaskRequest(identifier: Self.taskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: Self.retryDelay)
        // Replaces any earlier request with the same identifier. Fails on the simulator and when
        // Background App Refresh is off; the foreground and next-trip triggers still apply.
        try? BGTaskScheduler.shared.submit(request)
    }
}

/// Uploads finished trips to the website's sync API. A trip is pending whenever its `revision` differs from
/// `uploadedRevision`, so it goes up once when it finishes and again after any later edit
/// (addresses filled in, reclassified). Pending state lives in the SwiftData store, so trips that
/// finish offline or while the app is suspended upload on the next attempt: after the next trip,
/// on launch, when the app comes to the foreground, from a scheduled background refresh, or from
/// Sync Now in Settings.
@Observable
@MainActor
final class TripSyncService {
    /// Non-nil while connected to the cloud (empty if the server didn't return an email).
    /// Connecting happens when an Apple ID is linked for website sync; see `connectWithApple`.
    private(set) var signedInEmail: String?
    private(set) var isSyncing = false
    private(set) var lastSyncedAt: Date?
    private(set) var lastError: String?
    private(set) var pendingCount = 0
    /// True while trips are being downloaded from the account after signing in on a new or
    /// reinstalled app.
    private(set) var isRestoring = false
    /// How many trips the latest restore added to this device.
    private(set) var restoredCount = 0
    /// Turn on to have each sync also delete the trips the person deleted on the website. Off in
    /// the service's own tests; the app enables it (`UserSession`).
    @ObservationIgnored var appliesWebDeletions = false

    var isConfigured: Bool { client != nil }

    /// Hooks for what syncs alongside trips (the account's settings): the account connected (with
    /// its ID), it was disconnected, and a sync pass is starting.
    @ObservationIgnored var onSignedIn: ((String) -> Void)?
    @ObservationIgnored var onSignedOut: (() -> Void)?
    @ObservationIgnored var onSync: (() -> Void)?

    @ObservationIgnored private let container: ModelContainer
    @ObservationIgnored private let client: APIClient?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let retryScheduler: any SyncRetryScheduler
    @ObservationIgnored private var hasRestoredSession = false
    @ObservationIgnored private var needsAnotherPass = false
    /// Bumped on sign-in, sign-out and account deletion. A pass that started under an earlier
    /// value must not report results or mark trips uploaded: they belong to another session.
    @ObservationIgnored private var accountEpoch = 0
    @ObservationIgnored private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    @ObservationIgnored private var debouncedSync: Task<Void, Never>?
    /// The server-side sign-out in flight. A new sign-in waits for it, so it can't revoke the new session.
    @ObservationIgnored private var signOutTask: Task<Void, Never>?
    @ObservationIgnored private var saveObserver: (any NSObjectProtocol)?

    private static let lastUserIDKey = "sync.lastUserID"
    /// The account whose trips still need pulling down. Set on sign-in, cleared once every page has
    /// been stored, so a restore cut short (offline, app closed) resumes on the next sync.
    private static let restoreUserIDKey = "sync.restoreUserID"
    private static let restorePageSize = 20

    private static var pendingTrips: FetchDescriptor<Trip> {
        FetchDescriptor(predicate: #Predicate { !$0.isInProgress && $0.revision != $0.uploadedRevision })
    }

    init(
        container: ModelContainer,
        client: APIClient?,
        defaults: UserDefaults = .standard,
        retryScheduler: any SyncRetryScheduler = BackgroundRefreshRetryScheduler()
    ) {
        self.container = container
        self.client = client
        self.defaults = defaults
        self.retryScheduler = retryScheduler
    }

    /// Restores the saved cloud session, starts watching for edits, and uploads anything pending.
    func start() {
        refreshPendingCount()
        guard client != nil else { return }
        observeEdits()
        syncNow()
    }

    /// Stops watching for edits and cancels scheduled work.
    func stop() {
        if let saveObserver {
            NotificationCenter.default.removeObserver(saveObserver)
        }
        saveObserver = nil
        debouncedSync?.cancel()
        endBackgroundTask()
    }

    /// Reads the saved session once. A background relaunch can reach `sync()` before `start()`'s
    /// work has run, so every sync entry point goes through this.
    private func restoreSessionIfNeeded() async {
        guard !hasRestoredSession, let client else { return }
        hasRestoredSession = true
        if signedInEmail == nil, let session = await client.session {
            signedInEmail = session.email ?? ""
        }
    }

    /// Call when the app moves to the background: if anything is still waiting, make sure a
    /// retry is scheduled.
    func appDidEnterBackground() {
        refreshPendingCount()
        if signedInEmail != nil, pendingCount > 0 {
            retryScheduler.scheduleRetry()
        }
    }

    // MARK: - Account

    /// Connects cloud sync with a fresh Sign in with Apple identity token, creating the cloud
    /// account on first use.
    func connectWithApple(identityToken: String, nonce: String) async throws {
        guard let client else { return }
        let epoch = accountEpoch
        await signOutTask?.value
        do {
            let session = try await client.signInWithApple(identityToken: identityToken, nonce: nonce)
            guard epoch == accountEpoch else { return }
            didSignIn(session)
        } catch {
            // Turning sync off also dismisses the pending connection's errors.
            guard epoch == accountEpoch else { return }
            throw error
        }
    }

    /// Shows why connecting failed (e.g. offline at sign-in) in Settings → Website Sync.
    func reportConnectionError(_ error: Error) {
        lastError = error.localizedDescription
    }

    func signOut() {
        guard let client else { return }
        hasRestoredSession = true
        accountEpoch += 1
        debouncedSync?.cancel()
        defaults.removeObject(forKey: Self.restoreUserIDKey)
        signOutTask = Task { await client.signOut() }
        signedInEmail = nil
        lastError = nil
        lastSyncedAt = nil
        onSignedOut?()
    }

    /// Deletes the account on the server and signs out. Trips stay on this device, and in the
    /// cloud until the four-year retention purge.
    func deleteAccount() async throws {
        guard let client else { return }
        try await client.deleteAccount()
        hasRestoredSession = true
        accountEpoch += 1
        debouncedSync?.cancel()
        defaults.removeObject(forKey: Self.restoreUserIDKey)
        signedInEmail = nil
        lastError = nil
        lastSyncedAt = nil
        onSignedOut?()
    }

    private func didSignIn(_ session: AuthSession) {
        // Before the reset below, so an upload still in flight can't mark trips uploaded afterwards.
        accountEpoch += 1
        if defaults.string(forKey: Self.lastUserIDKey) != session.userID {
            // A different account has none of these trips yet, so everything uploads again.
            resetUploadState()
            defaults.set(session.userID, forKey: Self.lastUserIDKey)
        }
        // Always pulled on sign-in: a reinstalled app has no trips, and an app that already has some
        // only gains the ones it is missing.
        defaults.set(session.userID, forKey: Self.restoreUserIDKey)
        signedInEmail = session.email ?? ""
        lastError = nil
        onSignedIn?(session.userID)
        syncNow()
    }

    private func resetUploadState() {
        let context = ModelContext(container)
        guard let trips = try? context.fetch(FetchDescriptor<Trip>()) else { return }
        for trip in trips {
            trip.uploadedRevision = 0
        }
        try? context.save()
        refreshPendingCount()
    }

    // MARK: - Syncing

    func syncNow() {
        Task { await sync() }
    }

    /// Uploads until nothing is pending, or queues one more pass if a sync is already running.
    /// Asks iOS for background time, since this often runs right after a trip ends with the app
    /// in the background. Schedules a background retry if anything is left.
    func sync() async {
        await restoreSessionIfNeeded()
        guard client != nil, signedInEmail != nil else { return }
        onSync?()
        guard !isSyncing else {
            needsAnotherPass = true
            return
        }
        isSyncing = true
        beginBackgroundTask()
        let restoreError = await restoreTripsIfNeeded()
        if appliesWebDeletions { await applyWebDeletions() }
        repeat {
            needsAnotherPass = false
            await syncPendingTrips()
        } while needsAnotherPass && lastError == nil && signedInEmail != nil && !Task.isCancelled
        // Uploading still ran, but a restore that failed is shown (the upload pass clears errors).
        if let restoreError, lastError == nil, signedInEmail != nil { lastError = restoreError }
        isSyncing = false
        endBackgroundTask()
        if signedInEmail != nil, pendingCount > 0 || restoreError != nil {
            retryScheduler.scheduleRetry()
        }
    }

    /// Downloads the account's trips that this device doesn't have, a page at a time, so signing in
    /// on a reinstalled app or a new device brings the history back. Trips already on the device are
    /// left alone (the device's copy wins), and restored trips are stored as already uploaded.
    /// Runs before uploading, so a trip is never sent back just because it was missing locally.
    /// Returns the error's text if the restore failed and will be retried; nil otherwise.
    @discardableResult
    func restoreTripsIfNeeded() async -> String? {
        guard let client, let userID = defaults.string(forKey: Self.restoreUserIDKey) else { return nil }
        let epoch = accountEpoch
        isRestoring = true
        defer { isRestoring = false }
        var cursor: UUID?
        var added = 0
        do {
            repeat {
                let page = try await client.restoreTrips(after: cursor, limit: Self.restorePageSize)
                guard epoch == accountEpoch else { return nil }
                added += try storeRestored(page.trips)
                cursor = page.next
            } while cursor != nil && !Task.isCancelled
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled { return nil }
            guard epoch == accountEpoch else { return nil }
            lastError = error.localizedDescription
            if case SyncError.sessionExpired = error { signedInEmail = nil }
            restoredCount = added
            return error.localizedDescription
        }
        guard !Task.isCancelled, epoch == accountEpoch else { return nil }
        restoredCount = added
        // Only the account that was restored is marked done (a sign-in as someone else meanwhile
        // would have changed the key).
        if defaults.string(forKey: Self.restoreUserIDKey) == userID {
            defaults.removeObject(forKey: Self.restoreUserIDKey)
        }
        refreshPendingCount()
        return nil
    }

    /// Deletes, on this device, the trips the person deleted on the website. Each goes through
    /// `markDeleted()`, so it is kept as a record like any deleted trip and the deletion uploads.
    /// A failure is ignored here (the next sync tries again); only an expired session matters.
    func applyWebDeletions() async {
        guard let client, signedInEmail != nil else { return }
        let epoch = accountEpoch
        do {
            let ids = try await client.webDeletedTripIDs()
            guard epoch == accountEpoch, !ids.isEmpty else { return }
            let context = ModelContext(container)
            let trips = try context.fetch(FetchDescriptor<Trip>(predicate: #Predicate { ids.contains($0.id) && $0.deletedAt == nil }))
            guard !trips.isEmpty else { return }
            trips.forEach { $0.markDeleted() }
            try context.save()
            refreshPendingCount()
        } catch SyncError.sessionExpired {
            guard epoch == accountEpoch else { return }
            signedInEmail = nil
        } catch {
            return
        }
    }

    /// Inserts the trips this device doesn't have yet; returns how many were added.
    private func storeRestored(_ trips: [RestoredTrip]) throws -> Int {
        guard !trips.isEmpty else { return 0 }
        let context = ModelContext(container)
        let ids = trips.map(\.id)
        let existing = Set(try context.fetch(FetchDescriptor<Trip>(predicate: #Predicate { ids.contains($0.id) })).map(\.id))
        var added = 0
        for restored in trips where !existing.contains(restored.id) {
            _ = restored.makeTrip(inserting: context)
            added += 1
        }
        try context.save()
        return added
    }

    /// One upload pass over every pending trip, in batches. Stops at the first failure (or when
    /// cancelled) and leaves the rest pending for the next attempt.
    func syncPendingTrips() async {
        guard let client else { return }
        defer { refreshPendingCount() }
        let epoch = accountEpoch

        let pending: [(payload: TripPayload, revision: Int)]
        do {
            // A fresh context per pass reads what the recorder and UI have saved, not a stale cache.
            pending = try ModelContext(container).fetch(Self.pendingTrips).map { (TripPayload(trip: $0), $0.revision) }
        } catch {
            lastError = error.localizedDescription
            return
        }

        // Trips carry their full GPS route, so requests are limited by size as well as by count.
        for batch in UploadBatching.batches(pending, size: { $0.payload.estimatedBytes }) {
            if Task.isCancelled { return }
            do {
                try await client.upsertTrips(batch.map(\.payload))
                guard epoch == accountEpoch else { return }
                try markUploaded(batch)
            } catch {
                // Cancelled by iOS ending a background task, or signed out meanwhile: not an
                // error to show. The trips stay pending.
                if error is CancellationError || (error as? URLError)?.code == .cancelled { return }
                guard epoch == accountEpoch else { return }
                lastError = error.localizedDescription
                if case SyncError.sessionExpired = error {
                    signedInEmail = nil
                }
                return
            }
        }
        guard epoch == accountEpoch else { return }
        lastError = nil
        lastSyncedAt = Date()
    }

    /// Marks each trip uploaded at the revision that was sent. A trip edited while its upload was
    /// in flight has a newer revision, so it stays pending and goes up on the next pass.
    private func markUploaded(_ batch: [(payload: TripPayload, revision: Int)]) throws {
        let context = ModelContext(container)
        let ids = batch.map(\.payload.id)
        let sentRevisions = Dictionary(uniqueKeysWithValues: batch.map { ($0.payload.id, $0.revision) })
        let trips = try context.fetch(FetchDescriptor<Trip>(predicate: #Predicate { ids.contains($0.id) }))
        for trip in trips where sentRevisions[trip.id] == trip.revision {
            trip.uploadedRevision = trip.revision
        }
        try context.save()
    }

    private func refreshPendingCount() {
        pendingCount = (try? ModelContext(container).fetchCount(Self.pendingTrips)) ?? 0
    }

    /// Edits in the UI (e.g. reclassifying a trip) are saved on the main context; upload them a
    /// couple of seconds later so a burst of changes goes up as one request.
    private func observeEdits() {
        saveObserver = NotificationCenter.default.addObserver(
            forName: ModelContext.didSave,
            object: container.mainContext,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.scheduleSync()
            }
        }
    }

    private func scheduleSync() {
        refreshPendingCount()
        debouncedSync?.cancel()
        debouncedSync = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            syncNow()
        }
    }

    /// Runs a scheduled background retry (registered app-wide in `AppSession`).
    func handleBackgroundRetry(_ task: BGTask) {
        let work = Task { await sync() }
        // iOS gives refresh tasks about 30 seconds; stop cleanly when it asks. Anything not
        // uploaded stays pending and `sync()` schedules the next retry.
        task.expirationHandler = { work.cancel() }
        Task {
            await work.value
            task.setTaskCompleted(success: pendingCount == 0)
        }
    }

    private func beginBackgroundTask() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "TripSync") { [weak self] in
            MainActor.assumeIsolated {
                self?.endBackgroundTask()
            }
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
}
