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

struct ExportPeriodTests {
    private func trip(_ y: Int, _ m: Int, _ d: Int, hour: Int = 12) -> Trip {
        let date = Calendar.current.date(from: DateComponents(year: y, month: m, day: d, hour: hour))!
        return Trip(
            startDate: date, endDate: date.addingTimeInterval(600), distanceMiles: 5,
            startLatitude: 0, startLongitude: 0, endLatitude: 0, endLongitude: 0
        )
    }

    @Test func yearMatchesWholeYear() {
        let filter = ExportFilter(year: 2026)
        #expect(filter.matches(trip(2026, 1, 1)))
        #expect(filter.matches(trip(2026, 12, 31)))
        #expect(!filter.matches(trip(2025, 12, 31)))
        #expect(!filter.matches(trip(2027, 1, 1)))
    }

    @Test func rangeIncludesBothEndDaysWholly() {
        let start = trip(2026, 3, 10, hour: 15).startDate
        let end = trip(2026, 3, 20, hour: 9).startDate
        let filter = ExportFilter(period: .range(start: start, end: end))
        #expect(filter.matches(trip(2026, 3, 10, hour: 1)))
        #expect(filter.matches(trip(2026, 3, 20, hour: 23)))
        #expect(!filter.matches(trip(2026, 3, 9)))
        #expect(!filter.matches(trip(2026, 3, 21)))
    }

    @Test func rangeToleratesSwappedDates() {
        let a = trip(2026, 3, 10).startDate
        let b = trip(2026, 3, 20).startDate
        #expect(ExportFilter(period: .range(start: b, end: a)).matches(trip(2026, 3, 15)))
    }

    @Test func fileNamesDescribeThePeriod() {
        #expect(ExportNaming.fileBaseName(filter: ExportFilter(year: 2026)) == "MilesProSync-2026-all")
        #expect(ExportNaming.fileBaseName(filter: ExportFilter(year: 2026, month: 3, classification: .business))
            == "MilesProSync-2026-03-business")
    }
}
