import CoreLocation
import Foundation
import SwiftData
import Testing
@testable import MilesProSync

/// A trip interrupted by a crash, force-quit, or termination by iOS, as the recorder finds it on
/// the next launch.
struct TripRecoveryTests {
    private let container: ModelContainer
    private let recorder: TripRecorder
    private let now = Date(timeIntervalSince1970: 2_000_000)

    init() throws {
        container = try ModelContainer(
            for: Trip.self, RoutePoint.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        recorder = TripRecorder(modelContainer: container)
    }

    /// An in-progress trip whose points are 1 km apart heading north, the last one `minutesAgo`
    /// before `now`.
    @discardableResult
    private func interruptedTrip(lastPointMinutesAgo minutesAgo: Double, points: Int = 3) throws -> UUID {
        let context = ModelContext(container)
        let last = now.addingTimeInterval(-minutesAgo * 60)
        let start = last.addingTimeInterval(-Double(points - 1) * 60)
        let trip = Trip(
            startDate: start, endDate: start, distanceMiles: 0,
            startLatitude: 37, startLongitude: -122, endLatitude: 37, endLongitude: -122,
            isInProgress: true
        )
        context.insert(trip)
        trip.route = (0..<points).map { index in
            RoutePoint(
                latitude: 37 + Double(index) * 0.009, longitude: -122,
                timestamp: start.addingTimeInterval(Double(index) * 60)
            )
        }
        try context.save()
        return trip.id
    }

    private func trip(_ id: UUID) throws -> Trip {
        try #require(try ModelContext(container).fetch(FetchDescriptor<Trip>(predicate: #Predicate { $0.id == id })).first)
    }

    @Test func recentlyInterruptedTripIsResumed() async throws {
        let id = try interruptedTrip(lastPointMinutesAgo: 2)

        let recovery = await recorder.recoverInProgressTrips(now: now, resumeWindow: 10 * 60)

        let resume = try #require(recovery.resume)
        #expect(resume.lastActivityAt == now.addingTimeInterval(-120))
        #expect(recovery.finished.isEmpty)
        #expect(try trip(id).isInProgress)
    }

    @Test func longInterruptedTripIsFinishedWhereRecordingStopped() async throws {
        let id = try interruptedTrip(lastPointMinutesAgo: 90)

        let recovery = await recorder.recoverInProgressTrips(now: now, resumeWindow: 10 * 60)

        #expect(recovery.resume == nil)
        #expect(recovery.finished.count == 1)
        let finished = try trip(id)
        #expect(!finished.isInProgress)
        // Ends at the last saved point and its time, not "now" or the phone's current position.
        #expect(finished.endDate == now.addingTimeInterval(-90 * 60))
        #expect(abs(finished.endLatitude - (37 + 2 * 0.009)) < 1e-9)
        #expect(finished.distanceMiles > 1.2 && finished.distanceMiles < 1.3) // 2 × ~1 km = ~1.24 mi
        #expect(finished.revision > finished.uploadedRevision) // queued for upload
    }

    @Test func onlyNewestInterruptedTripCanResume() async throws {
        let older = try interruptedTrip(lastPointMinutesAgo: 5)
        let newer = try interruptedTrip(lastPointMinutesAgo: 1)

        let recovery = await recorder.recoverInProgressTrips(now: now, resumeWindow: 10 * 60)

        #expect(recovery.resume != nil)
        #expect(try trip(newer).isInProgress)
        #expect(try !trip(older).isInProgress)
        #expect(recovery.finished.count == 1)
    }

    @Test func tripInterruptedRightAfterStartKeepsItsStartPoint() async throws {
        let id = try interruptedTrip(lastPointMinutesAgo: 60, points: 1)

        _ = await recorder.recoverInProgressTrips(now: now, resumeWindow: 10 * 60)

        let finished = try trip(id)
        #expect(!finished.isInProgress)
        #expect(finished.distanceMiles == 0)
        #expect(finished.endDate == finished.startDate)
    }

    @Test func aFinishedTripOnAClassifiedRouteGetsThatClassification() async throws {
        // The person classified this route (37.000 to 37.018 north) as Business before.
        let context = ModelContext(container)
        context.insert(Trip(
            startDate: now.addingTimeInterval(-86_400), endDate: now.addingTimeInterval(-85_000), distanceMiles: 1.2,
            startLatitude: 37, startLongitude: -122, endLatitude: 37.018, endLongitude: -122,
            classification: .business, isManuallyClassified: true
        ))
        try context.save()
        let id = try interruptedTrip(lastPointMinutesAgo: 60)

        _ = await recorder.recoverInProgressTrips(now: now, resumeWindow: 10 * 60)

        let finished = try trip(id)
        #expect(finished.classification == .business)
        #expect(!finished.isManuallyClassified)   // the app's label, not the person's
    }

    @Test func aFinishedTripOnANewRouteStaysUnclassified() async throws {
        let id = try interruptedTrip(lastPointMinutesAgo: 60)

        _ = await recorder.recoverInProgressTrips(now: now, resumeWindow: 10 * 60)

        #expect(try trip(id).classification == .unclassified)
    }

    @Test func noInterruptedTripsMeansNothingToDo() async {
        let recovery = await recorder.recoverInProgressTrips(now: now, resumeWindow: 10 * 60)
        #expect(recovery.resume == nil)
        #expect(recovery.finished.isEmpty)
    }

    @Test func finishedTripsWithoutAddressesAreFoundForRetry() async throws {
        let id = try interruptedTrip(lastPointMinutesAgo: 90)
        _ = await recorder.recoverInProgressTrips(now: now, resumeWindow: 10 * 60)

        let missing = await recorder.tripsMissingAddresses(within: 30 * 24 * 3600, now: now, limit: 20)
        #expect(missing.count == 1)

        await recorder.setAddresses(startAddress: "1 Main St", endAddress: "2 Oak Ave", for: try #require(missing.first).tripID)
        #expect(await recorder.tripsMissingAddresses(within: 30 * 24 * 3600, now: now, limit: 20).isEmpty)
        #expect(try trip(id).startAddress == "1 Main St")
    }

    @Test func failedLookupNeverErasesAnAddress() async throws {
        let id = try interruptedTrip(lastPointMinutesAgo: 90)
        let recovery = await recorder.recoverInProgressTrips(now: now, resumeWindow: 10 * 60)
        let tripID = try #require(recovery.finished.first).tripID

        await recorder.setAddresses(startAddress: "1 Main St", endAddress: nil, for: tripID)
        let revision = try trip(id).revision
        await recorder.setAddresses(startAddress: nil, endAddress: nil, for: tripID) // offline retry

        #expect(try trip(id).startAddress == "1 Main St")
        #expect(try trip(id).revision == revision) // nothing changed, nothing to re-upload
    }

    @Test func tripsBeingRecordedAreNotExported() throws {
        let trip = Trip(
            startDate: now, endDate: now, distanceMiles: 0,
            startLatitude: 0, startLongitude: 0, endLatitude: 0, endLongitude: 0,
            isInProgress: true
        )
        let filter = ExportFilter(monthContaining: now)
        #expect(!filter.matches(trip))
    }
}
