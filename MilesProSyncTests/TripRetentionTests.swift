import Foundation
import SwiftData
import Testing
@testable import MilesProSync

@MainActor
struct TripRetentionTests {
    private let now = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 23))!

    private func trip(endedYearsAgo years: Double, deleted: Bool) -> Trip {
        let end = now.addingTimeInterval(-years * 365.25 * 24 * 3600)
        let trip = Trip(
            startDate: end, endDate: end, distanceMiles: 1,
            startLatitude: 0, startLongitude: 0, endLatitude: 0, endLongitude: 0
        )
        if deleted { trip.markDeleted(at: now) }
        return trip
    }

    @Test func cutoffIsFourYearsBack() {
        let expected = Calendar.current.date(from: DateComponents(year: 2022, month: 9, day: 23))!
        #expect(TripRetention.cutoff(now: now) == expected)
    }

    @Test func purgesOnlyDeletedTripsOlderThanFourYears() throws {
        let container = try ModelContainer(
            for: Trip.self, RoutePoint.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        let expiredDeleted = trip(endedYearsAgo: 4.1, deleted: true)
        let recentDeleted = trip(endedYearsAgo: 3.9, deleted: true)
        let oldVisible = trip(endedYearsAgo: 6, deleted: false)
        for trip in [expiredDeleted, recentDeleted, oldVisible] {
            context.insert(trip)
        }
        expiredDeleted.route = [RoutePoint(latitude: 0, longitude: 0, timestamp: now)]
        recentDeleted.route = [RoutePoint(latitude: 1, longitude: 1, timestamp: now)]
        try context.save()

        let purged = try TripRetention.purgeExpiredDeletedTrips(in: container, now: now)

        #expect(purged == 1)
        let remaining = try ModelContext(container).fetch(FetchDescriptor<Trip>()).map(\.id)
        #expect(Set(remaining) == [recentDeleted.id, oldVisible.id])
        // The expired trip's route goes with it; the retained trip's route stays.
        let points = try ModelContext(container).fetch(FetchDescriptor<RoutePoint>())
        #expect(points.map(\.latitude) == [1])
    }
}
