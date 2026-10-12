import Foundation
import SwiftData
import Testing
@testable import MilesProSync

/// End-to-end flows through `TripSyncService` and `APIClient` against a scripted server: signing
/// in and pushing trips, refreshing an expiring session, pushing a deletion, and deleting or
/// signing out of the website account.
@MainActor
struct SyncLifecycleTests {
    private let container: ModelContainer
    private let server = FakeServer()
    private let tokens: InMemoryTokenStore
    private let service: TripSyncService

    init() throws {
        try self.init(session: SyncFixtures.session())
    }

    private init(session: AuthSession?) throws {
        container = try ModelContainer(
            for: Trip.self, RoutePoint.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let store = InMemoryTokenStore(session)
        tokens = store
        service = TripSyncService(
            container: container,
            client: APIClient(config: SyncFixtures.config, tokenStore: store, transport: server.transport),
            defaults: UserDefaults(suiteName: UUID().uuidString)!,
            retryScheduler: RecordingRetryScheduler()
        )
    }

    // MARK: - Helpers

    @discardableResult
    private func insertTrip() throws -> UUID {
        let context = ModelContext(container)
        let trip = Trip(
            startDate: .now, endDate: .now, distanceMiles: 3,
            startLatitude: 0, startLongitude: 0, endLatitude: 0, endLongitude: 0
        )
        context.insert(trip)
        try context.save()
        return trip.id
    }

    private func deleteTrip(_ id: UUID) throws {
        let context = ModelContext(container)
        let trip = try #require(try context.fetch(FetchDescriptor<Trip>(predicate: #Predicate { $0.id == id })).first)
        trip.markDeleted()
        try context.save()
    }

    private var tripCount: Int {
        (try? ModelContext(container).fetchCount(FetchDescriptor<Trip>())) ?? 0
    }

    private func paths() async -> [String] {
        await server.requests.compactMap { $0.url?.path() }
    }

    private func tripUploads() async -> [[String: Any]] {
        await server.requests
            .filter { $0.url?.path() == "/api/v1/trips" }
            .flatMap { (SyncFixtures.body(of: $0) as? [[String: Any]]) ?? [] }
    }

    private func waitUntil(_ description: String, _ condition: () async -> Bool) async {
        for _ in 0..<300 {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for \(description)")
    }

    // MARK: - Push

    @Test func signingInThenSyncingPushesPendingTrips() async throws {
        let signedOut = try SyncLifecycleTests(session: nil)
        let id = try signedOut.insertTrip()
        await signedOut.server.enqueue(200, SyncFixtures.tokenResponse(access: "access-new", refresh: "refresh-new"))
        await signedOut.server.enqueueOK()

        try await signedOut.service.connectWithApple(identityToken: "apple-jwt", nonce: "nonce")
        // Connecting kicks off a sync of its own.
        await signedOut.waitUntil("the trip upload") { await signedOut.paths().contains("/api/v1/trips") }
        await signedOut.waitUntil("sync to settle") { !signedOut.service.isSyncing && signedOut.service.pendingCount == 0 }

        #expect(await signedOut.paths().prefix(2) == ["/api/v1/auth/apple", "/api/v1/trips"])
        let upload = try #require(await signedOut.server.requests.last)
        #expect(upload.value(forHTTPHeaderField: "Authorization") == "Bearer access-new")
        #expect(await signedOut.tripUploads().compactMap { $0["id"] as? String } == [id.uuidString])
        #expect(signedOut.service.signedInEmail == "driver@example.com")
        #expect(signedOut.tokens.load()?.refreshToken == "refresh-new")
    }

    @Test func turningSyncOffWhileSignInIsPendingKeepsItOff() async throws {
        let signedOut = try SyncLifecycleTests(session: nil)
        _ = try signedOut.insertTrip()
        let gate = Gate()
        await signedOut.server.setOnRequest { request in
            if request.url?.path() == "/api/v1/auth/apple" { await gate.wait() }
        }
        await signedOut.server.enqueue(200, SyncFixtures.tokenResponse(access: "access-new", refresh: "refresh-new"))
        // If the response reaches the client before its queued sign-out, the new token
        // is immediately revoked. Both orderings must leave sync off.
        await signedOut.server.enqueue(204, "")
        let service = signedOut.service

        let connect = Task { @MainActor in
            try? await service.connectWithApple(identityToken: "apple-jwt", nonce: "nonce")
        }
        await signedOut.waitUntil("the sign-in request") { await signedOut.paths().contains("/api/v1/auth/apple") }

        // The person turns Website Sync off while Apple's token is still being exchanged.
        service.signOut()
        await gate.open()
        _ = await connect.value
        try? await Task.sleep(for: .milliseconds(100))

        #expect(service.signedInEmail == nil)
        #expect(signedOut.tokens.load() == nil)
        #expect(service.lastError == nil)
        #expect(await signedOut.paths().contains("/api/v1/trips") == false)
    }

    // MARK: - Refresh

    @Test func expiringSessionIsRefreshedBeforePushing() async throws {
        let expiring = try SyncLifecycleTests(session: SyncFixtures.session(expiresIn: 10))
        try expiring.insertTrip()
        await expiring.server.enqueue(200, SyncFixtures.tokenResponse(access: "access-2", refresh: "refresh-2"))
        await expiring.server.enqueueOK()

        await expiring.service.sync()

        #expect(await expiring.paths() == ["/api/v1/auth/refresh", "/api/v1/trips"])
        let upload = try #require(await expiring.server.requests.last)
        #expect(upload.value(forHTTPHeaderField: "Authorization") == "Bearer access-2")
        #expect(expiring.tokens.load()?.refreshToken == "refresh-2")
        #expect(expiring.service.pendingCount == 0)
        #expect(expiring.service.lastError == nil)
    }

    @Test func revokedRefreshTokenDisconnectsAndKeepsTripsPending() async throws {
        let expiring = try SyncLifecycleTests(session: SyncFixtures.session(expiresIn: 10))
        try expiring.insertTrip()
        await expiring.server.enqueue(401, #"{"message":"Session expired."}"#)

        await expiring.service.sync()

        #expect(expiring.service.signedInEmail == nil)
        #expect(expiring.tokens.load() == nil)
        #expect(expiring.service.pendingCount == 1)
        #expect(expiring.tripCount == 1)
    }

    // MARK: - Delete a trip

    @Test func deletingAnUploadedTripPushesTheDeletion() async throws {
        await server.enqueueOK(2)
        let id = try insertTrip()
        await service.sync()
        #expect(await tripUploads().count == 1)
        #expect(await tripUploads().first?["deleted_at"] is NSNull)

        try deleteTrip(id)
        await service.sync()

        let uploads = await tripUploads()
        #expect(uploads.count == 2)
        #expect(uploads.last?["id"] as? String == id.uuidString)
        #expect(uploads.last?["deleted_at"] is String)
        #expect(service.pendingCount == 0)
        // Deleted trips are kept, not removed, on the device.
        #expect(tripCount == 1)
    }

    // MARK: - Delete the account

    @Test func deletingTheAccountSignsOutAndStopsUploadsButKeepsTrips() async throws {
        await server.enqueueOK()
        await server.enqueue(204, "")
        try insertTrip()
        await service.sync()

        try await service.deleteAccount()

        let request = try #require(await server.requests.last)
        #expect(request.url?.path() == "/api/v1/account")
        #expect(request.httpMethod == "DELETE")
        #expect(service.signedInEmail == nil)
        #expect(tokens.load() == nil)

        let requestsBefore = await server.requests.count
        try insertTrip()
        await service.sync()
        #expect(await server.requests.count == requestsBefore)
        #expect(tripCount == 2)
    }

    @Test func accountDeletionRefreshesOnceAfterUnauthorized() async throws {
        await server.enqueue(401, #"{"message":"Token expired."}"#)
        await server.enqueue(200, SyncFixtures.tokenResponse(access: "access-2", refresh: "refresh-2"))
        await server.enqueue(204, "")

        try await service.deleteAccount()

        #expect(await paths() == ["/api/v1/account", "/api/v1/auth/refresh", "/api/v1/account"])
        let retried = try #require(await server.requests.last)
        #expect(retried.value(forHTTPHeaderField: "Authorization") == "Bearer access-2")
        #expect(tokens.load() == nil)
        #expect(service.signedInEmail == nil)
    }

    @Test func failedAccountDeletionStaysSignedIn() async throws {
        // The app restores the saved session on its first sync, at launch.
        await service.sync()
        #expect(service.signedInEmail != nil)
        await server.enqueue(500, #"{"message":"Try again later."}"#)

        await #expect(throws: SyncError.server(status: 500, message: "Try again later.")) {
            try await service.deleteAccount()
        }

        #expect(tokens.load() != nil)
        #expect(service.signedInEmail != nil)
    }

    // MARK: - Sign out

    @Test func signingOutRevokesTheTokenAndStopsUploads() async throws {
        await server.enqueueOK(2) // the trip upload, then the sign-out call
        await service.sync()
        try insertTrip()
        await service.sync()
        #expect(await tripUploads().count == 1)

        service.signOut()
        await waitUntil("the sign-out request") { await paths().contains("/api/v1/auth/sign-out") }

        let request = try #require(await server.requests.last)
        #expect(request.url?.path() == "/api/v1/auth/sign-out")
        #expect((SyncFixtures.body(of: request) as? [String: String])?["refresh_token"] == "refresh-1")
        #expect(tokens.load() == nil)

        try insertTrip()
        let requestsBefore = await server.requests.count
        await service.sync()
        #expect(await server.requests.count == requestsBefore)
    }

    @Test func signingInAsAnotherAccountPushesEveryTripAgain() async throws {
        await server.enqueueOK(2) // the first upload, then the sign-out call
        let id = try insertTrip()
        await service.sync()
        #expect(await tripUploads().count == 1)

        service.signOut()
        await waitUntil("the sign-out request") { await paths().contains("/api/v1/auth/sign-out") }
        await server.enqueue(200, SyncFixtures.tokenResponse(access: "access-b", refresh: "refresh-b", userID: "user-2"))
        await server.enqueueOK()
        try await service.connectWithApple(identityToken: "apple-jwt", nonce: "nonce")
        await waitUntil("the second upload") { await tripUploads().count == 2 }

        let ids = await tripUploads().compactMap { $0["id"] as? String }
        #expect(ids == [id.uuidString, id.uuidString])
    }
}

/// Holds a request until the test opens it.
private actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}
