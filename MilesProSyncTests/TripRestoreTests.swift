import Foundation
import SwiftData
import Testing
@testable import MilesProSync

/// Signing in on a reinstalled app (or a new device) pulls the account's trips back down from the
/// website, a page at a time, without duplicating what the device already has or uploading it again.
@MainActor
struct TripRestoreTests {
    private let container: ModelContainer
    private let server = FakeServer()
    private let tokens: InMemoryTokenStore
    private let defaults: UserDefaults
    private let service: TripSyncService

    init() throws {
        container = try ModelContainer(
            for: Trip.self, RoutePoint.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        tokens = InMemoryTokenStore(nil)
        defaults = UserDefaults(suiteName: UUID().uuidString)!
        service = TripSyncService(
            container: container,
            client: APIClient(config: SyncFixtures.config, tokenStore: tokens, transport: server.transport),
            defaults: defaults,
            retryScheduler: RecordingRetryScheduler()
        )
    }

    // MARK: - Helpers

    private static func tripJSON(
        _ id: UUID, notes: String? = nil, purpose: String? = nil, startedAt: String = "2026-09-15T16:00:00Z",
        route: Bool = true
    ) -> String {
        let notesJSON = notes.map { "\"\($0)\"" } ?? "null"
        let purposeJSON = purpose.map { "\"\($0)\"" } ?? "null"
        let points = route
            ? #"[{"latitude":1.5,"longitude":2.5,"recorded_at":"2026-09-15T16:00:00Z","speed_mps":12.5},"#
                + #"{"latitude":1.6,"longitude":2.6,"recorded_at":"2026-09-15T16:05:00Z"}]"#
            : "[]"
        return """
        {"id":"\(id.uuidString.lowercased())","started_at":"\(startedAt)","ended_at":"2026-09-15T16:25:00Z",
         "distance_miles":7.2,"start_latitude":1.0,"start_longitude":2.0,"end_latitude":3.0,"end_longitude":4.0,
         "start_address":"1 Main St","end_address":null,"classification":"business",
         "is_manually_classified":true,"notes":\(notesJSON),"purpose":\(purposeJSON),"route":\(points)}
        """
    }

    private static func page(_ trips: [String], next: UUID? = nil) -> String {
        let cursor = next.map { "\"\($0.uuidString.lowercased())\"" } ?? "null"
        return #"{"trips":[\#(trips.joined(separator: ","))],"next":\#(cursor)}"#
    }

    private func signIn() async throws {
        await server.enqueue(200, SyncFixtures.tokenResponse(access: "access-new", refresh: "refresh-new"))
        try await service.connectWithApple(identityToken: "apple-jwt", nonce: "nonce")
    }

    private func settle() async {
        for _ in 0..<500 {
            if !service.isSyncing, !service.isRestoring, await !server.requests.isEmpty { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        // Let a pass that was queued behind the first one finish.
        try? await Task.sleep(for: .milliseconds(50))
        for _ in 0..<500 where service.isSyncing || service.isRestoring {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func allTrips() throws -> [Trip] {
        try ModelContext(container).fetch(FetchDescriptor<Trip>(sortBy: [SortDescriptor(\.startDate)]))
    }

    private func requests(matching path: String) async -> [URLRequest] {
        await server.requests.filter { $0.url?.path() == path }
    }

    // MARK: - Restoring

    @Test func signingInOnAReinstalledAppBringsTheCloudTripsBack() async throws {
        let first = UUID(), second = UUID()
        await server.enqueue(200, SyncFixtures.tokenResponse(access: "access-new", refresh: "refresh-new"))
        await server.enqueue(200, Self.page([Self.tripJSON(first, notes: "Client visit", purpose: "Site inspection"), Self.tripJSON(second, route: false)]))

        try await service.connectWithApple(identityToken: "apple-jwt", nonce: "nonce")
        await settle()

        let trips = try allTrips()
        #expect(Set(trips.map(\.id)) == [first, second])
        let restored = try #require(trips.first { $0.id == first })
        #expect(restored.notes == "Client visit")
        #expect(restored.purpose == "Site inspection")
        #expect(trips.first { $0.id == second }?.purpose == nil)
        #expect(restored.distanceMiles == 7.2)
        #expect(restored.startAddress == "1 Main St")
        #expect(restored.classification == .business)
        #expect(restored.isManuallyClassified)
        #expect(!restored.isInProgress)
        #expect(restored.startDate == Date(timeIntervalSince1970: 1_789_488_000))
        #expect(restored.sortedRoute.map(\.latitude) == [1.5, 1.6])
        #expect(restored.sortedRoute.first?.speed == 12.5)
        #expect(restored.sortedRoute.last?.speed == nil)
        #expect(service.restoredCount == 2)
        #expect(service.pendingCount == 0)
    }

    @Test func restoredTripsAreNotUploadedAgain() async throws {
        await server.enqueue(200, SyncFixtures.tokenResponse(access: "access-new", refresh: "refresh-new"))
        await server.enqueue(200, Self.page([Self.tripJSON(UUID())]))

        try await service.connectWithApple(identityToken: "apple-jwt", nonce: "nonce")
        await settle()

        #expect(try allTrips().count == 1)
        #expect(await requests(matching: "/api/v1/trips").isEmpty)
        let restored = try #require(try allTrips().first)
        #expect(restored.uploadedRevision == restored.revision)
    }

    @Test func everyPageIsFetchedUsingTheCursor() async throws {
        let ids = (0..<3).map { _ in UUID() }
        await server.enqueue(200, SyncFixtures.tokenResponse(access: "access-new", refresh: "refresh-new"))
        await server.enqueue(200, Self.page([Self.tripJSON(ids[0]), Self.tripJSON(ids[1])], next: ids[1]))
        await server.enqueue(200, Self.page([Self.tripJSON(ids[2])]))

        try await service.connectWithApple(identityToken: "apple-jwt", nonce: "nonce")
        await settle()

        #expect(Set(try allTrips().map(\.id)) == Set(ids))
        let calls = await requests(matching: "/api/v1/trips/restore")
        #expect(calls.count == 2)
        #expect(calls.allSatisfy { $0.httpMethod == "GET" })
        #expect(calls.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer access-new" })
        let queries = calls.map { URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)?.queryItems ?? [] }
        #expect(queries[0].first { $0.name == "after" } == nil)
        #expect(queries[1].first { $0.name == "after" }?.value == ids[1].uuidString.lowercased())
        #expect(queries.allSatisfy { $0.contains(URLQueryItem(name: "limit", value: "20")) })
    }

    @Test func tripsAlreadyOnTheDeviceAreKeptAsTheyAre() async throws {
        let shared = UUID(), cloudOnly = UUID()
        let context = ModelContext(container)
        let local = Trip(
            id: shared, startDate: .now, endDate: .now, distanceMiles: 1,
            startLatitude: 0, startLongitude: 0, endLatitude: 0, endLongitude: 0, notes: "edited on this device"
        )
        context.insert(local)
        try context.save()
        await server.enqueue(200, SyncFixtures.tokenResponse(access: "access-new", refresh: "refresh-new"))
        await server.enqueue(200, Self.page([Self.tripJSON(shared, notes: "older cloud copy"), Self.tripJSON(cloudOnly)]))
        await server.enqueueOK() // the local trip's upload

        try await service.connectWithApple(identityToken: "apple-jwt", nonce: "nonce")
        await settle()

        let trips = try allTrips()
        #expect(trips.count == 2)
        #expect(trips.first { $0.id == shared }?.notes == "edited on this device")
        #expect(service.restoredCount == 1)
    }

    // MARK: - Failure and sign-out

    @Test func aFailedRestoreIsRetriedOnTheNextSync() async throws {
        let id = UUID()
        await server.enqueue(200, SyncFixtures.tokenResponse(access: "access-new", refresh: "refresh-new"))
        await server.enqueue(503, #"{"message":"Try again later."}"#)

        try await service.connectWithApple(identityToken: "apple-jwt", nonce: "nonce")
        await settle()
        #expect(try allTrips().isEmpty)
        #expect(service.lastError == "Try again later.")

        await server.enqueue(200, Self.page([Self.tripJSON(id)]))
        await service.sync()

        #expect(try allTrips().map(\.id) == [id])
        #expect(service.lastError == nil)
        #expect(await requests(matching: "/api/v1/trips/restore").count == 2)
    }

    @Test func aCompletedRestoreIsNotRepeatedOnLaterSyncs() async throws {
        await server.enqueue(200, SyncFixtures.tokenResponse(access: "access-new", refresh: "refresh-new"))
        await server.enqueue(200, Self.page([Self.tripJSON(UUID())]))
        try await service.connectWithApple(identityToken: "apple-jwt", nonce: "nonce")
        await settle()

        await service.sync()
        await service.sync()

        #expect(await requests(matching: "/api/v1/trips/restore").count == 1)
    }

    @Test func aRestoreCutShortByRelaunchResumesForTheSameAccount() async throws {
        let id = UUID()
        await server.enqueue(200, SyncFixtures.tokenResponse(access: "access-new", refresh: "refresh-new"))
        await server.enqueue(500, #"{"message":"down"}"#)
        try await service.connectWithApple(identityToken: "apple-jwt", nonce: "nonce")
        await settle()

        // A new launch: a fresh service over the same saved session and defaults.
        let relaunched = TripSyncService(
            container: container,
            client: APIClient(config: SyncFixtures.config, tokenStore: tokens, transport: server.transport),
            defaults: defaults,
            retryScheduler: RecordingRetryScheduler()
        )
        await server.enqueue(200, Self.page([Self.tripJSON(id)]))
        await relaunched.sync()

        #expect(try allTrips().map(\.id) == [id])
    }

    @Test func turningSyncOffCancelsAPendingRestore() async throws {
        await server.enqueue(200, SyncFixtures.tokenResponse(access: "access-new", refresh: "refresh-new"))
        await server.enqueue(500, #"{"message":"down"}"#)
        try await service.connectWithApple(identityToken: "apple-jwt", nonce: "nonce")
        await settle()
        await server.enqueueOK() // the sign-out call
        service.signOut()
        try? await Task.sleep(for: .milliseconds(50))

        let before = await requests(matching: "/api/v1/trips/restore").count
        await service.sync()

        #expect(await requests(matching: "/api/v1/trips/restore").count == before)
        #expect(try allTrips().isEmpty)
    }

    // MARK: - Decoding

    @Test func pagesDecodeFractionalSecondsAndMissingOptionals() throws {
        let id = UUID()
        let json = """
        {"trips":[{"id":"\(id.uuidString.lowercased())","started_at":"2026-09-15T16:00:00.250Z",
          "ended_at":"2026-09-15T16:25:00Z","distance_miles":3,"start_latitude":0,"start_longitude":0,
          "end_latitude":0,"end_longitude":0,"start_address":null,"end_address":null,"classification":"unclassified",
          "is_manually_classified":false,"notes":null,"route":[]}],"next":null}
        """
        let page = try RestoredTripPage.decode(Data(json.utf8))
        let trip = try #require(page.trips.first)
        #expect(trip.id == id)
        #expect(abs(trip.startedAt.timeIntervalSince1970 - 1_789_488_000.25) < 0.001)
        #expect(trip.startAddress == nil)
        #expect(page.next == nil)
    }

    @Test func anUnknownClassificationBecomesUnclassified() throws {
        let json = Self.page([Self.tripJSON(UUID()).replacingOccurrences(of: "business", with: "mystery")])
        let trip = try #require(try RestoredTripPage.decode(Data(json.utf8)).trips.first)
        #expect(trip.makeTrip().classification == .unclassified)
    }

    // MARK: - Deleted on the website

    @Test func tripsDeletedOnTheWebsiteAreDeletedOnTheDevice() async throws {
        let context = ModelContext(container)
        let gone = Trip(
            startDate: .now, endDate: .now, distanceMiles: 1,
            startLatitude: 0, startLongitude: 0, endLatitude: 0, endLongitude: 0
        )
        let kept = Trip(
            startDate: .now, endDate: .now, distanceMiles: 2,
            startLatitude: 0, startLongitude: 0, endLatitude: 0, endLongitude: 0
        )
        [gone, kept].forEach { $0.uploadedRevision = $0.revision; context.insert($0) }
        try context.save()
        let goneID = gone.id, keptID = kept.id
        tokens.save(SyncFixtures.session())
        let signedIn = TripSyncService(
            container: container,
            client: APIClient(config: SyncFixtures.config, tokenStore: tokens, transport: server.transport),
            defaults: defaults, retryScheduler: RecordingRetryScheduler()
        )
        signedIn.appliesWebDeletions = true
        await server.enqueue(200, #"{"trip_ids":["\#(goneID.uuidString.lowercased())"]}"#)
        await server.enqueueOK() // the deletion uploads

        await signedIn.sync()

        let trips = try allTrips()
        #expect(trips.first { $0.id == goneID }?.deletedAt != nil)
        #expect(trips.first { $0.id == keptID }?.deletedAt == nil)
        // The device's own copy keeps its record, and the deletion is sent up like any other.
        let uploads = await requests(matching: "/api/v1/trips")
        let sent = (SyncFixtures.body(of: try #require(uploads.first)) as? [[String: Any]]) ?? []
        #expect(sent.count == 1)
        #expect(sent.first?["id"] as? String == goneID.uuidString)
        #expect(sent.first?["deleted_at"] is String)
    }

    @Test func websiteDeletionsAreNotCheckedUnlessTheAppAsksForThem() async throws {
        tokens.save(SyncFixtures.session())
        let signedIn = TripSyncService(
            container: container,
            client: APIClient(config: SyncFixtures.config, tokenStore: tokens, transport: server.transport),
            defaults: defaults, retryScheduler: RecordingRetryScheduler()
        )
        await signedIn.sync()
        #expect(await requests(matching: "/api/v1/trips/deletions").isEmpty)
    }

    @Test func aFailedDeletionCheckDoesNotStopUploads() async throws {
        let context = ModelContext(container)
        context.insert(Trip(
            startDate: .now, endDate: .now, distanceMiles: 1,
            startLatitude: 0, startLongitude: 0, endLatitude: 0, endLongitude: 0
        ))
        try context.save()
        tokens.save(SyncFixtures.session())
        let signedIn = TripSyncService(
            container: container,
            client: APIClient(config: SyncFixtures.config, tokenStore: tokens, transport: server.transport),
            defaults: defaults, retryScheduler: RecordingRetryScheduler()
        )
        signedIn.appliesWebDeletions = true
        await server.enqueue(404, #"{"message":"Not Found"}"#)
        await server.enqueueOK()

        await signedIn.sync()

        #expect(await requests(matching: "/api/v1/trips").count == 1)
        #expect(signedIn.lastError == nil)
        #expect(signedIn.pendingCount == 0)
    }
}
