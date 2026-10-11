import Foundation
import Testing
@testable import MilesProSync

struct FAVRAndIRSRateTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func date(_ y: Int, _ m: Int, _ d: Int = 15) -> Date {
        calendar.date(from: DateComponents(timeZone: TimeZone(identifier: "UTC"), year: y, month: m, day: d, hour: 12))!
    }

    private func trip(_ when: Date, miles: Double, _ kind: TripClassification = .business) -> Trip {
        Trip(
            startDate: when, endDate: when.addingTimeInterval(600), distanceMiles: miles,
            startLatitude: 0, startLongitude: 0, endLatitude: 0, endLongitude: 0, classification: kind
        )
    }

    private func isolatedDefaults() -> UserDefaults {
        let name = "favr-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    // MARK: IRS table

    @Test func irsRateIsLookedUpByYearWithFallbacks() {
        let table: [Int: Double] = [2024: 0.67, 2025: 0.70, 2026: 0.725]
        #expect(IRSRates.rate(forYear: 2025, in: table) == 0.70)
        #expect(IRSRates.rate(forYear: 2031, in: table) == 0.725) // until its rate is added
        #expect(IRSRates.rate(forYear: 1999, in: table) == 0.67)
    }

    @Test func websiteTableIsMergedOverTheBuiltInOneAndBadValuesAreIgnored() throws {
        let defaults = isolatedDefaults()
        let data = Data(#"{"rates":{"2027":"0.750","2026":"0.725","2030":"9999","x":"1"}}"#.utf8)
        let decoded = try #require(IRSRates.decode(data))
        #expect(decoded == [2027: 0.75, 2026: 0.725])
        IRSRates.cache(decoded, defaults: defaults)
        let table = IRSRates.table(defaults: defaults)
        #expect(table[2027] == 0.75)
        #expect(table[2024] == 0.67) // built in
    }

    @Test func irsModePaysEachTripAtItsYearsRate() {
        let table: [Int: Double] = [2025: 0.70, 2026: 0.725]
        let rate = ReimbursementRate(perMile: 0.725, irsTable: table)
        #expect(rate.perMile(on: date(2025, 6), calendar: calendar) == 0.70)
        #expect(rate.perMile(on: date(2026, 6), calendar: calendar) == 0.725)
        let trips = [trip(date(2025, 12), miles: 10), trip(date(2026, 1), miles: 10)]
        #expect(Reimbursement.total(trips, rate: rate) == 7.00 + 7.25)
    }

    @Test func aNewIRSYearUpdatesTheDefaultButNotACustomRate() {
        var table: [Int: Double] = [2026: 0.725]
        let irs = ReimbursementRate(perMile: 0.725, irsTable: table)
        let custom = ReimbursementRate(perMile: 0.60)
        table[2027] = 0.75 // the IRS announces next year's rate
        let irsNext = ReimbursementRate(perMile: 0.725, irsTable: table)
        #expect(irs.perMile(on: date(2027, 3), calendar: calendar) == 0.725) // old table: until added
        #expect(irsNext.perMile(on: date(2027, 3), calendar: calendar) == 0.75)
        #expect(custom.perMile(on: date(2027, 3), calendar: calendar) == 0.60)
    }

    // MARK: Modes

    @Test func nothingStoredMeansTheIRSRateAndIsRemembered() {
        let defaults = isolatedDefaults()
        #expect(AppSettings.resolveRateMode(defaults: defaults) == .irs)
        #expect(defaults.string(forKey: AppSettings.Key.rateMode) == "irs")
    }

    @Test func anOldStoredOwnRateBecomesCustomAndKeepsItsValue() {
        let defaults = isolatedDefaults()
        defaults.set(0.67, forKey: AppSettings.Key.mileageRate)
        #expect(AppSettings.resolveRateMode(defaults: defaults) == .custom)
        #expect(defaults.double(forKey: AppSettings.Key.mileageRate) == 0.67)
    }

    @Test func theOldDefaultRateCountsAsTheIRSRate() {
        let defaults = isolatedDefaults()
        defaults.set(0.725, forKey: AppSettings.Key.mileageRate)
        #expect(AppSettings.resolveRateMode(defaults: defaults) == .irs)
    }

    @Test func aChosenModeIsNeverReinterpreted() {
        let defaults = isolatedDefaults()
        defaults.set("custom", forKey: AppSettings.Key.rateMode)
        defaults.set(0.725, forKey: AppSettings.Key.mileageRate) // typed on purpose
        #expect(AppSettings.resolveRateMode(defaults: defaults) == .custom)
    }

    @Test func settingsBuildTheRightRateForEachMode() {
        let table: [Int: Double] = [2026: 0.725]
        let favr = AppSettings.reimbursementRate(
            mode: .favr, customPerMile: 0.5, favrFixedMonthly: 250, favrPerMile: 0.2,
            favrMinMonthlyMiles: 100, countryCode: "US", table: table
        )
        #expect(favr.isFAVR && favr.perMile == 0.2 && favr.fixedMonthly == 250 && favr.irsTable == nil)
        #expect(favr.label == "$0.20/mi + $250.00/mo")
        let irs = AppSettings.reimbursementRate(
            mode: .irs, customPerMile: 0.5, favrFixedMonthly: 250, favrPerMile: 0.2,
            favrMinMonthlyMiles: 100, countryCode: "US", at: date(2026, 5), table: table
        )
        #expect(irs.irsTable == table && irs.perMile == 0.725 && !irs.isFAVR)
    }

    // MARK: FAVR

    @Test func fixedAmountIsPaidForEachMonthInTheYearSoFar() {
        let rate = ReimbursementRate(perMile: 0.2, fixedMonthly: 250)
        let filter = ExportFilter(year: 2026)
        let amount = Reimbursement.fixedAmount(
            trips: [], filter: filter, rate: rate, now: date(2026, 4, 10), calendar: calendar
        )
        #expect(amount == 1000) // January to April
        let past = Reimbursement.fixedAmount(
            trips: [], filter: ExportFilter(year: 2025), rate: rate, now: date(2026, 4, 10), calendar: calendar
        )
        #expect(past == 3000)
    }

    @Test func fixedAmountNeedsTheMinimumBusinessMilesEachMonth() {
        let rate = ReimbursementRate(perMile: 0.2, fixedMonthly: 250, minMonthlyMiles: 100)
        let trips = [
            trip(date(2026, 1), miles: 120),
            trip(date(2026, 2), miles: 60),
            trip(date(2026, 2, 20), miles: 60, .personal), // personal miles don't count
            trip(date(2026, 3), miles: 100),
        ]
        let amount = Reimbursement.fixedAmount(
            trips: trips, filter: ExportFilter(year: 2026), rate: rate, now: date(2026, 3, 31), calendar: calendar
        )
        #expect(amount == 500) // January and March qualify
    }

    @Test func noFixedAmountForPersonalOnlyExportsOrPlainRates() {
        let favr = ReimbursementRate(perMile: 0.2, fixedMonthly: 250)
        let personal = ExportFilter(year: 2026, classification: .personal)
        #expect(Reimbursement.fixedAmount(trips: [], filter: personal, rate: favr, now: date(2026, 6), calendar: calendar) == 0)
        let plain = ReimbursementRate(perMile: 0.725)
        #expect(Reimbursement.fixedAmount(trips: [], filter: ExportFilter(year: 2026), rate: plain, now: date(2026, 6), calendar: calendar) == 0)
    }

    @Test func customRangeCountsTheMonthsItSpans() {
        let filter = ExportFilter(period: .range(start: date(2026, 2, 10), end: date(2026, 4, 2)))
        #expect(filter.months(calendar: calendar).map(\.key) == ["2026-02", "2026-03", "2026-04"])
    }

    @Test func csvShowsTheFixedAmountAndIncludesItInTheTotal() {
        let rate = ReimbursementRate(perMile: 0.2, fixedMonthly: 250)
        let csv = CSVExporter.makeCSV(trips: [trip(date(2026, 3), miles: 10)], rate: rate, fixedAmount: 250)
        #expect(csv.contains("Fixed monthly amount (FAVR)"))
        #expect(csv.contains("Total,,,10.0,,,252.00"))
        #expect(csv.contains("Reimbursement ($0.20/mi + $250.00/mo)"))
    }
}
