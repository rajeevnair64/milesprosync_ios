import Foundation
import PDFKit
import Testing
@testable import MilesProSync

/// Reports are priced by the method chosen in Settings → Reimbursement: the taxation rate, My
/// rate (custom) or FAVR. Each test makes the choice the way the Settings screen does (writing the
/// account's defaults), builds the rate the way the Export screen does, and checks the CSV, Excel
/// and PDF reports.
struct ReportGenerationTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        calendar.date(from: DateComponents(timeZone: TimeZone(identifier: "UTC"), year: y, month: m, day: d, hour: 12))!
    }

    /// September 2026: 10.0 and 4.04 (shown as 4.0) business miles, and 5.0 personal.
    private func septemberTrips() -> [Trip] {
        func make(_ day: Int, _ miles: Double, _ kind: TripClassification) -> Trip {
            Trip(
                startDate: date(2026, 9, day), endDate: date(2026, 9, day).addingTimeInterval(600),
                distanceMiles: miles, startLatitude: 0, startLongitude: 0, endLatitude: 0, endLongitude: 0,
                startAddress: "A", endAddress: "B", classification: kind
            )
        }
        return [make(3, 10.0, .business), make(10, 4.04, .business), make(17, 5.0, .personal)]
    }

    private func defaults(
        mode: AppSettings.RateMode?, custom: Double? = nil,
        favrFixed: Double = 0, favrPerMile: Double = 0, favrMinimum: Double = 0
    ) -> UserDefaults {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        if let mode { defaults.set(mode.rawValue, forKey: AppSettings.Key.rateMode) }
        if let custom { defaults.set(custom, forKey: AppSettings.Key.mileageRate) }
        defaults.set(favrFixed, forKey: AppSettings.Key.favrFixedMonthly)
        defaults.set(favrPerMile, forKey: AppSettings.Key.favrPerMile)
        defaults.set(favrMinimum, forKey: AppSettings.Key.favrMinMonthlyMiles)
        return defaults
    }

    /// The rate the Export screen builds from the saved settings.
    private func selectedRate(_ defaults: UserDefaults, filter: ExportFilter) -> ReimbursementRate {
        AppSettings.reimbursementRate(
            mode: AppSettings.resolveRateMode(defaults: defaults),
            customPerMile: defaults.object(forKey: AppSettings.Key.mileageRate) == nil
                ? AppSettings.defaultMileageRate : defaults.double(forKey: AppSettings.Key.mileageRate),
            favrFixedMonthly: defaults.double(forKey: AppSettings.Key.favrFixedMonthly),
            favrPerMile: defaults.double(forKey: AppSettings.Key.favrPerMile),
            favrMinMonthlyMiles: defaults.double(forKey: AppSettings.Key.favrMinMonthlyMiles),
            countryCode: "US", at: filter.referenceDate(calendar: calendar), table: [2026: 0.725]
        )
    }

    private struct Report {
        let rate: ReimbursementRate
        let fixed: Double
        let csv: [String]
        let xlsx: String
    }

    private func report(_ defaults: UserDefaults, classification: TripClassification? = .business) -> Report {
        let filter = ExportFilter(year: 2026, month: 9, classification: classification)
        let rate = selectedRate(defaults, filter: filter)
        let trips = ExportFetcher.fetchTrips(from: septemberTrips(), filter: filter)
        let fixed = Reimbursement.fixedAmount(
            trips: trips, filter: filter, rate: rate, now: date(2026, 10, 11), calendar: calendar
        )
        return Report(
            rate: rate, fixed: fixed,
            csv: CSVExporter.makeCSV(trips: trips, rate: rate, fixedAmount: fixed).components(separatedBy: "\r\n"),
            xlsx: XLSXExporter.worksheetXML(trips: trips, rate: rate, fixedAmount: fixed)
        )
    }

    // MARK: Taxation rate

    @Test func taxationRatePricesTheReportAtTheYearsStandardRate() {
        let report = report(defaults(mode: .irs, custom: 0.5)) // a stale custom value must not be used

        #expect(report.csv[0] == "Date,Start,End,Miles,Classification,Purpose,Reimbursement ($0.725/mi)")
        #expect(report.csv.contains { $0.hasSuffix(",10.0,Business,,7.25") }) // 10.0 x 0.725
        #expect(report.csv.contains { $0.hasSuffix(",4.0,Business,,2.90") }) // 4.0 x 0.725
        #expect(report.csv.last == "Total,,,14.0,,,10.15")
        #expect(report.fixed == 0)
        #expect(report.xlsx.contains("<v>10.15</v>"))
    }

    @Test func nothingChosenMeansTheTaxationRate() {
        let report = report(defaults(mode: nil))
        #expect(report.csv.last == "Total,,,14.0,,,10.15")
    }

    // MARK: My rate

    @Test func myRatePricesTheReportAtTheRateTheUserTyped() {
        let report = report(defaults(mode: .custom, custom: 0.5))

        #expect(report.csv[0] == "Date,Start,End,Miles,Classification,Purpose,Reimbursement ($0.50/mi)")
        #expect(report.csv.contains { $0.hasSuffix(",10.0,Business,,5.00") })
        #expect(report.csv.contains { $0.hasSuffix(",4.0,Business,,2.00") })
        #expect(report.csv.last == "Total,,,14.0,,,7.00")
        #expect(report.fixed == 0)
        #expect(report.xlsx.contains("Reimbursement ($0.50/mi)"))
        #expect(report.xlsx.contains("<v>7</v>") || report.xlsx.contains("<v>7.0</v>") || report.xlsx.contains("<v>7.00</v>"))
    }

    @Test func myRateAppliesToPersonalTripsWhenTheyAreIncluded() {
        let report = report(defaults(mode: .custom, custom: 0.5), classification: nil)
        #expect(report.csv.last == "Total,,,19.0,,,9.50") // 19.0 x 0.5
    }

    // MARK: FAVR

    @Test func favrAddsTheFixedMonthlyAmountToThePerMileAmounts() {
        let report = report(defaults(mode: .favr, favrFixed: 250, favrPerMile: 0.2))

        #expect(report.csv[0] == "Date,Start,End,Miles,Classification,Purpose,Reimbursement ($0.20/mi + $250.00/mo)")
        #expect(report.csv.contains { $0.hasSuffix(",10.0,Business,,2.00") })
        #expect(report.csv.contains { $0.hasSuffix(",4.0,Business,,0.80") })
        #expect(report.csv.contains("Fixed monthly amount (FAVR),,,,,,250.00"))
        #expect(report.csv.last == "Total,,,14.0,,,252.80") // 2.80 + 250
        #expect(report.fixed == 250)
        #expect(report.xlsx.contains("252.8"))
    }

    @Test func favrFixedAmountIsDroppedWhenBusinessMilesAreBelowTheMinimum() {
        let report = report(defaults(mode: .favr, favrFixed: 250, favrPerMile: 0.2, favrMinimum: 20))

        #expect(report.fixed == 0)
        #expect(!report.csv.contains { $0.hasPrefix("Fixed monthly amount") })
        #expect(report.csv.last == "Total,,,14.0,,,2.80")
    }

    @Test func favrFixedAmountIsPaidWhenBusinessMilesMeetTheMinimum() {
        let report = report(defaults(mode: .favr, favrFixed: 250, favrPerMile: 0.2, favrMinimum: 14))
        #expect(report.fixed == 250)
    }

    @Test func aPersonalOnlyReportHasNoFixedAmount() {
        let report = report(defaults(mode: .favr, favrFixed: 250, favrPerMile: 0.2), classification: .personal)
        #expect(report.fixed == 0)
        #expect(report.csv.last == "Total,,,5.0,,,1.00")
    }

    // MARK: The generated files

    @Test func csvAndPdfFilesAreGeneratedForEveryMethod() throws {
        let methods: [(UserDefaults, String)] = [
            (defaults(mode: .irs), "10.15"),
            (defaults(mode: .custom, custom: 0.5), "7.00"),
            (defaults(mode: .favr, favrFixed: 250, favrPerMile: 0.2), "252.80"),
        ]
        for (settings, total) in methods {
            let filter = ExportFilter(year: 2026, month: 9, classification: .business)
            let rate = selectedRate(settings, filter: filter)
            let trips = ExportFetcher.fetchTrips(from: septemberTrips(), filter: filter)

            let csvURL = try CSVExporter.export(trips: trips, filter: filter, rate: rate)
            let csv = try String(contentsOf: csvURL, encoding: .utf8)
            #expect(csv.contains(",\(total)"), "CSV total \(total)")

            let pdfURL = try PDFExporter.export(trips: trips, filter: filter, rate: rate)
            let pdf = try #require(PDFDocument(url: pdfURL))
            let text = (0..<pdf.pageCount).compactMap { pdf.page(at: $0)?.string }.joined()
            #expect(text.contains(total), "PDF total \(total)")

            let xlsxURL = try XLSXExporter.export(trips: trips, filter: filter, rate: rate)
            #expect(((try FileManager.default.attributesOfItem(atPath: xlsxURL.path)[.size] as? Int) ?? 0) > 0)
        }
    }
}
