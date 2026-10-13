import Foundation
import SwiftData
import Testing
@testable import MilesProSync

@MainActor
final class RecordingRetryScheduler: SyncRetryScheduler {
    private(set) var scheduledCount = 0
    func scheduleRetry() { scheduledCount += 1 }
}

@MainActor
struct TripSyncServiceTests {
    private let container: ModelContainer
    private let server = FakeServer()
    private let retries = RecordingRetryScheduler()
    private let service: TripSyncService

    init() throws {
        container = try ModelContainer(
            for: Trip.self, RoutePoint.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let client = APIClient(
            config: SyncFixtures.config,
            tokenStore: InMemoryTokenStore(SyncFixtures.session()),
            transport: server.transport
        )
        service = TripSyncService(
            container: container,
            client: client,
            defaults: UserDefaults(suiteName: UUID().uuidString)!,
            retryScheduler: retries
        )
    }

    @discardableResult
    private func insertTrip(inProgress: Bool = false) throws -> UUID {
        let context = ModelContext(container)
        let trip = Trip(
            startDate: .now, endDate: .now, distanceMiles: 3,
            startLatitude: 0, startLongitude: 0, endLatitude: 0, endLongitude: 0,
            isInProgress: inProgress
        )
        context.insert(trip)
        try context.save()
        return trip.id
    }

    private func trip(_ id: UUID) throws -> Trip {
        try #require(try ModelContext(container).fetch(FetchDescriptor<Trip>(predicate: #Predicate { $0.id == id })).first)
    }

    private func uploadedIDs() async -> [String] {
        await server.requests
            .filter { $0.url?.path() == "/api/v1/trips" }
            .flatMap { (SyncFixtures.body(of: $0) as? [[String: Any]]) ?? [] }
            .compactMap { $0["id"] as? String }
    }

    @Test func uploadsFinishedTripsAndMarksThemUploaded() async throws {
        await server.enqueueOK()
        let finished = try insertTrip()
        try insertTrip(inProgress: true)

        await service.syncPendingTrips()

        #expect(await uploadedIDs() == [finished.uuidString])
        #expect(try trip(finished).uploadedRevision == trip(finished).revision)
        #expect(service.pendingCount == 0)
        #expect(service.lastError == nil)
        #expect(service.lastSyncedAt != nil)
    }

    @Test func nothingPendingSendsNoRequest() async throws {
        await service.syncPendingTrips()
        #expect(await server.requests.isEmpty)
    }

    @Test func editAfterUploadMakesTripPendingAgain() async throws {
        await server.enqueueOK(2)
        let id = try insertTrip()
        await service.syncPendingTrips()

        let context = ModelContext(container)
        let stored = try #require(try context.fetch(FetchDescriptor<Trip>(predicate: #Predicate { $0.id == id })).first)
        stored.classification = .business
        try context.save()

        await service.syncPendingTrips()
        #expect(await uploadedIDs() == [id.uuidString, id.uuidString])
    }

    @Test func editDuringUploadStaysPending() async throws {
        await server.enqueueOK()
        let id = try insertTrip()
        let container = container
        await server.setOnRequest { _ in
            // The user reclassifies the trip while its upload is in flight.
            await MainActor.run {
                let context = ModelContext(container)
                let trip = try? context.fetch(FetchDescriptor<Trip>(predicate: #Predicate { $0.id == id })).first
                trip?.classification = .personal
                try? context.save()
            }
        }

        await service.syncPendingTrips()

        let stored = try trip(id)
        #expect(stored.uploadedRevision < stored.revision)
        #expect(service.pendingCount == 1)
    }

    @Test func failedUploadKeepsTripsPendingAndReportsError() async throws {
        let id = try insertTrip()
        await server.enqueue(500, #"{"message":"database unavailable"}"#)

        await service.syncPendingTrips()

        #expect(try trip(id).uploadedRevision == 0)
        #expect(service.pendingCount == 1)
        #expect(service.lastError == "database unavailable")
    }

    @Test func largeBacklogUploadsInBatches() async throws {
        await server.enqueueOK(12)
        let context = ModelContext(container)
        for _ in 0..<120 {
            context.insert(Trip(
                startDate: .now, endDate: .now, distanceMiles: 1,
                startLatitude: 0, startLongitude: 0, endLatitude: 0, endLongitude: 0
            ))
        }
        try context.save()

        await service.syncPendingTrips()

        #expect(await server.requests.count == 12) // batches of 10
        #expect(Set(await uploadedIDs()).count == 120)
        #expect(service.pendingCount == 0)
    }

    @Test func deletedTripUploadsWithDeletionTime() async throws {
        await server.enqueueOK(2)
        let id = try insertTrip()
        await service.syncPendingTrips()

        let context = ModelContext(container)
        let stored = try #require(try context.fetch(FetchDescriptor<Trip>(predicate: #Predicate { $0.id == id })).first)
        stored.markDeleted()
        try context.save()
        await service.syncPendingTrips()

        let last = try #require(await server.requests.last)
        let row = try #require((SyncFixtures.body(of: last) as? [[String: Any]])?.first)
        #expect(row["id"] as? String == id.uuidString)
        #expect(row["deleted_at"] is String)
        #expect(service.pendingCount == 0)
    }

    @Test func failedSyncSchedulesBackgroundRetry() async throws {
        try insertTrip()
        await server.enqueue(503, #"{"message":"unavailable"}"#)

        await service.sync()

        #expect(retries.scheduledCount == 1)
        #expect(service.pendingCount == 1)
        #expect(!service.isSyncing)
    }

    @Test func rateLimitedSyncStaysConnectedAndRetriesLater() async throws {
        let id = try insertTrip()
        await server.enqueue(429, #"{"message":"Too many requests right now. Your trips are safe on your iPhone and will upload later."}"#)

        await service.sync()

        #expect(try trip(id).uploadedRevision == 0)
        #expect(service.signedInEmail != nil)
        #expect(retries.scheduledCount == 1)
        #expect(service.lastError?.contains("will upload later") == true)
    }

    @Test func successfulSyncSchedulesNoRetry() async throws {
        await server.enqueueOK()
        try insertTrip()
        await service.sync()
        #expect(retries.scheduledCount == 0)
        #expect(service.pendingCount == 0)
    }

    @Test func backgroundingWithPendingTripsSchedulesRetry() async throws {
        try insertTrip()
        await server.enqueue(503)
        await service.sync() // restores the session; fails, schedules once
        service.appDidEnterBackground()
        #expect(retries.scheduledCount == 2)
    }

    @Test func cancelledSyncStopsBetweenBatches() async throws {
        let context = ModelContext(container)
        for _ in 0..<30 {
            context.insert(Trip(
                startDate: .now, endDate: .now, distanceMiles: 1,
                startLatitude: 0, startLongitude: 0, endLatitude: 0, endLongitude: 0
            ))
        }
        try context.save()

        let task = Task { await service.syncPendingTrips() }
        task.cancel()
        await task.value

        #expect(service.pendingCount > 0)
    }

    @Test func recorderEditsBumpRevision() async throws {
        let trip = Trip(
            startDate: .now, endDate: .now, distanceMiles: 1,
            startLatitude: 0, startLongitude: 0, endLatitude: 0, endLongitude: 0
        )
        let before = trip.revision
        trip.classification = .business
        #expect(trip.revision == before + 1)
        #expect(trip.uploadedRevision == 0)
    }

    @Test func changingThePurposeMakesTheTripPendingAndUploadsIt() async throws {
        let id = try insertTrip()
        await server.enqueueOK(2)
        await service.sync()
        #expect(service.pendingCount == 0)

        let context = ModelContext(container)
        let stored = try #require(try context.fetch(FetchDescriptor<Trip>(predicate: #Predicate { $0.id == id })).first)
        stored.setPurpose("Client visit")
        try context.save()
        service.syncNow()
        await service.sync()

        let uploads = await server.requests
            .filter { $0.url?.path() == "/api/v1/trips" }
            .flatMap { (SyncFixtures.body(of: $0) as? [[String: Any]]) ?? [] }
        #expect(uploads.last?["purpose"] as? String == "Client visit")
        #expect(uploads.first?["purpose"] is NSNull)
    }

    @Test func settingTheSamePurposeAgainChangesNothing() throws {
        let trip = Trip(
            startDate: .now, endDate: .now, distanceMiles: 1,
            startLatitude: 0, startLongitude: 0, endLatitude: 0, endLongitude: 0
        )
        trip.setPurpose("Client visit")
        let revision = trip.revision
        trip.setPurpose("Client visit")
        #expect(trip.revision == revision)
        trip.setPurpose(nil)
        #expect(trip.purpose == nil)
        #expect(trip.revision == revision + 1)
    }
}
