import AuthenticationServices
import BackgroundTasks
import Foundation
import Observation
import SwiftData
import SwiftUI

/// Everything that belongs to the device's account: its trip store, its settings, and the
/// services that record and upload its trips. Created at launch and kept for the life of the app;
/// linking or unlinking an Apple ID only changes whether trips upload.
@MainActor
final class UserSession: Identifiable {
    let storageKey: String
    let container: ModelContainer
    let defaults: UserDefaults
    let tripSync: TripSyncService
    let driveDetection: DriveDetectionService
    /// The website's API, for team features; nil when this build has no server configured.
    let apiClient: APIClient?

    nonisolated var id: String { storageKey }

    init(storageKey: String, apiConfig: APIConfig?, storageRoot: URL, legacyDefaults: UserDefaults) throws {
        self.storageKey = storageKey
        defaults = UserStorage.defaults(for: storageKey)
        container = try UserStorage.makeContainer(
            for: storageKey, root: storageRoot, defaults: defaults, legacyDefaults: legacyDefaults
        )

        let client = apiConfig.map {
            APIClient(config: $0, tokenStore: KeychainTokenStore(userKey: UserStorage.folderName(for: storageKey)))
        }
        apiClient = client
        let tripSync = TripSyncService(container: container, client: client, defaults: defaults)
        self.tripSync = tripSync
        driveDetection = DriveDetectionService(modelContainer: container, defaults: defaults)
        // After the free period, with no subscription, new drives aren't recorded.
        driveDetection.isRecordingAllowed = { AccessStore.isRecordingAllowed() }
        driveDetection.onTripFinished = { tripSync.syncNow() }
        // Settings from before reimbursement methods existed: settle which one this account was using.
        AppSettings.resolveRateMode(defaults: defaults)
    }

    func start() {
        _ = try? TripRetention.purgeExpiredDeletedTrips(in: container)
        tripSync.start()
        driveDetection.start()
        // A new year's IRS rate reaches people on the default rate without an app release.
        if let baseURL = apiClient?.config.baseURL {
            Task { await IRSRates.refresh(baseURL: baseURL) }
        }
    }

    func stop() {
        driveDetection.stop()
        tripSync.stop()
    }

    var tripCount: Int {
        (try? ModelContext(container).fetchCount(FetchDescriptor<Trip>())) ?? 0
    }
}

/// App-wide account state. The app records trips from first launch with no sign-in. Signing in
/// with Apple is optional: it links an Apple ID so trips upload for viewing on the website.
@Observable
@MainActor
final class AppSession {
    private(set) var account: DeviceAccount?
    private(set) var current: UserSession?
    /// Why linking an Apple ID failed, shown in Settings → Website Sync.
    private(set) var linkError: String?
    /// Why the trip store couldn't be opened, shown instead of the trip list.
    private(set) var launchError: String?

    @ObservationIgnored private let accountStore: any AccountStore
    @ObservationIgnored private let apiConfig: APIConfig?
    @ObservationIgnored private let storageRoot: URL
    @ObservationIgnored private let startsServices: Bool
    @ObservationIgnored private let legacyDefaults: UserDefaults
    @ObservationIgnored private var pendingNonce: SignInNonce?

    var isCloudConfigured: Bool { apiConfig != nil }

    /// The Miles Pro Sync website that synced trips can be viewed on; nil when this build has no
    /// server configured.
    var websiteURL: URL? { apiConfig?.baseURL }

    /// Opens the device's account synchronously, creating one on first launch, so a background
    /// relaunch (trip in progress, significant location change) resumes recording before launch
    /// finishes.
    init(
        accountStore: any AccountStore,
        apiConfig: APIConfig?,
        storageRoot: URL = UserStorage.applicationSupport,
        legacyDefaults: UserDefaults = .standard,
        startsServices: Bool = true
    ) {
        self.accountStore = accountStore
        self.apiConfig = apiConfig
        self.storageRoot = storageRoot
        self.legacyDefaults = legacyDefaults
        self.startsServices = startsServices
        let account = accountStore.load() ?? {
            // No saved account but this device's own trip store exists (restored from a backup, or
            // the Keychain wasn't readable yet): keep using it rather than starting an empty one.
            // Stores keyed by an Apple user ID belong to a signed-out account and come back only
            // by linking that Apple ID.
            let existing = UserStorage.existingStorageKeys(root: storageRoot).filter { $0.hasPrefix("device-") }
            let account = existing.count == 1
                ? DeviceAccount(storageKey: existing[0], appleUserID: nil, email: nil)
                : DeviceAccount.makeLocal()
            accountStore.save(account)
            return account
        }()
        self.account = account
        activate(storageKey: account.storageKey)
        NotificationCenter.default.addObserver(
            forName: ASAuthorizationAppleIDProvider.credentialRevokedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.unlinkApple() }
        }
    }

    // MARK: - Sign in with Apple (optional, for website sync)

    /// Configures the Sign in with Apple request. Only the email is requested; the app has no use
    /// for the user's name.
    func prepare(_ request: ASAuthorizationAppleIDRequest) {
        let nonce = SignInNonce.make()
        pendingNonce = nonce
        request.requestedScopes = [.email]
        request.nonce = nonce.sha256
    }

    func complete(_ result: Result<ASAuthorization, Error>) {
        let nonce = pendingNonce
        pendingNonce = nil
        switch result {
        case .failure(let error):
            if (error as? ASAuthorizationError)?.code == .canceled { return }
            linkError = error.localizedDescription
        case .success(let authorization):
            guard let credential = AppleCredential(authorization: authorization) else {
                linkError = "Sign in with Apple didn't return an Apple ID."
                return
            }
            linkApple(with: credential, nonce: nonce)
        }
    }

    /// Links an Apple ID for website sync (or, when the same one is already linked, reconnects).
    /// Trips already on the device stay where they are and upload once connected.
    func linkApple(with credential: AppleCredential, nonce: SignInNonce?) {
        linkError = nil
        guard var account else { return }
        if let linked = account.appleUserID, linked != credential.userID {
            linkError = "Website sync is linked to a different Apple ID. Turn it off first."
            return
        }
        if !account.isLinked {
            account = adoptingStoreFromBeforeSignInWasOptional(account, appleUserID: credential.userID)
            account.appleUserID = credential.userID
            account.email = credential.email ?? account.email
            accountStore.save(account)
            self.account = account
        }
        guard let current else { return }
        guard let token = credential.identityToken, let nonce else {
            // Linked, but nothing to exchange for a cloud session: say so rather than looking connected.
            if apiConfig != nil {
                linkError = "Sign in with Apple didn't return a sign-in token. Try connecting again."
            }
            return
        }
        Task {
            do {
                try await current.tripSync.connectWithApple(identityToken: token, nonce: nonce.raw)
            } catch {
                // Recording is unaffected; Settings → Website Sync offers to connect again.
                current.tripSync.reportConnectionError(error)
            }
        }
    }

    /// Someone who signed out while sign-in was required has their trips in a store keyed by
    /// their Apple user ID, not in the device store created since. If the device store is still
    /// empty, switch to theirs so linking the same Apple ID brings those trips back.
    private func adoptingStoreFromBeforeSignInWasOptional(_ account: DeviceAccount, appleUserID: String) -> DeviceAccount {
        guard account.storageKey != appleUserID,
              UserStorage.storeExists(for: appleUserID, root: storageRoot),
              current?.tripCount == 0 else { return account }
        current?.stop()
        current = nil
        activate(storageKey: appleUserID)
        return DeviceAccount(storageKey: appleUserID, appleUserID: nil, email: account.email)
    }

    /// Turns off website sync: stops uploading and forgets the cloud session. Recording carries
    /// on and every trip stays on the device.
    func unlinkApple() {
        guard var account, account.isLinked else { return }
        current?.tripSync.signOut()
        account.appleUserID = nil
        account.email = nil
        accountStore.save(account)
        self.account = account
        linkError = nil
    }

    /// Deletes the website account (see `TripSyncService.deleteAccount`), then unlinks.
    func deleteWebsiteAccount() async throws {
        guard let current else { return }
        try await current.tripSync.deleteAccount()
        unlinkApple()
    }

    /// Ends the trip being recorded (the driver tapped Finish Trip); the next drive is a new trip.
    func finishCurrentTrip() {
        current?.driveDetection.finishCurrentTrip()
    }

    // MARK: - Lifecycle

    /// Checks with Apple that the linked Apple ID still authorizes this app (the user can
    /// revoke it in Settings → Apple ID → Sign-In & Security); if not, turns off website sync.
    /// Called when the app becomes active.
    func verifyAppleCredential() {
        guard let userID = account?.appleUserID else { return }
        ASAuthorizationAppleIDProvider().getCredentialState(forUserID: userID) { [weak self] state, error in
            guard error == nil, state == .revoked || state == .notFound else { return }
            Task { @MainActor in
                guard let self, self.account?.appleUserID == userID else { return }
                self.unlinkApple()
            }
        }
    }

    func scenePhaseChanged(to phase: ScenePhase) {
        switch phase {
        case .active:
            verifyAppleCredential()
            current?.tripSync.syncNow()
        case .background:
            current?.tripSync.appDidEnterBackground()
        default:
            break
        }
    }

    /// Background retry task (see `BackgroundRefreshRetryScheduler`), registered once at launch
    /// because iOS requires registration before launch finishes.
    func handleBackgroundRetry(_ task: BGTask) {
        guard let current else {
            task.setTaskCompleted(success: true)
            return
        }
        current.tripSync.handleBackgroundRetry(task)
    }

    static func registerBackgroundRetry(for session: AppSession) {
        let registered = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: BackgroundRefreshRetryScheduler.taskIdentifier,
            using: .main
        ) { [weak session] task in
            MainActor.assumeIsolated {
                guard let session else {
                    task.setTaskCompleted(success: true)
                    return
                }
                session.handleBackgroundRetry(task)
            }
        }
        assert(registered, "Add \(BackgroundRefreshRetryScheduler.taskIdentifier) to BGTaskSchedulerPermittedIdentifiers")
    }

    private func activate(storageKey: String) {
        do {
            let session = try UserSession(
                storageKey: storageKey, apiConfig: apiConfig, storageRoot: storageRoot, legacyDefaults: legacyDefaults
            )
            current = session
            launchError = nil
            if startsServices { session.start() }
        } catch {
            launchError = "Couldn't open your trips: \(error.localizedDescription)"
        }
    }
}
