import Foundation
import Testing
@testable import MilesProSync

struct ExportFilterTests {
    private var march2026: Date {
        var components = DateComponents()
        components.year = 2026
        components.month = 3
        components.day = 15
        return Calendar.current.date(from: components)!
    }

    @Test func matchesTripsInSameMonthAndClassification() {
        let trip = Trip(
            startDate: march2026, endDate: march2026, distanceMiles: 1,
            startLatitude: 0, startLongitude: 0, endLatitude: 0, endLongitude: 0,
            classification: .business
        )

        #expect(ExportFilter(year: 2026, month: 3, classification: .business).matches(trip))
        #expect(!ExportFilter(year: 2026, month: 4, classification: .business).matches(trip))
        #expect(!ExportFilter(year: 2026, month: 3, classification: .personal).matches(trip))
        #expect(ExportFilter(year: 2026, month: 3, classification: nil).matches(trip))
    }

    @Test func deletedTripsAreNeverExported() {
        let trip = Trip(
            startDate: march2026, endDate: march2026, distanceMiles: 1,
            startLatitude: 0, startLongitude: 0, endLatitude: 0, endLongitude: 0,
            classification: .business
        )
        trip.markDeleted()
        #expect(!ExportFilter(year: 2026, month: 3).matches(trip))
        #expect(ExportFetcher.fetchTrips(from: [trip], filter: ExportFilter(year: 2026, month: 3)).isEmpty)
    }

    @Test func fetcherFiltersAndSortsByDate() {
        let earlier = Trip(
            startDate: march2026, endDate: march2026, distanceMiles: 3,
            startLatitude: 0, startLongitude: 0, endLatitude: 0, endLongitude: 0,
            classification: .personal
        )
        let later = Trip(
            startDate: march2026.addingTimeInterval(3600), endDate: march2026, distanceMiles: 5,
            startLatitude: 0, startLongitude: 0, endLatitude: 0, endLongitude: 0,
            classification: .personal
        )
        let otherMonth = Trip(
            startDate: march2026.addingTimeInterval(30 * 24 * 3600), endDate: march2026, distanceMiles: 7,
            startLatitude: 0, startLongitude: 0, endLatitude: 0, endLongitude: 0,
            classification: .personal
        )

        let filter = ExportFilter(monthContaining: march2026, classification: .personal)
        let result = ExportFetcher.fetchTrips(from: [later, earlier, otherMonth], filter: filter)

        #expect(result.map(\.distanceMiles) == [3, 5])
        #expect(ExportFetcher.totalMiles(result) == 8)
    }
}
