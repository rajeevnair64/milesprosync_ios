import Foundation

enum ExportFormat: String, CaseIterable, Identifiable {
    case csv
    case pdf
    case xlsx

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .csv: "CSV"
        case .pdf: "PDF"
        case .xlsx: "Excel"
        }
    }

    var fileExtension: String { rawValue }
}

enum ExportError: LocalizedError {
    case archiveCreationFailed

    var errorDescription: String? {
        switch self {
        case .archiveCreationFailed: "Couldn't create the Excel export file."
        }
    }
}

struct ExportFilter {
    enum Period: Equatable {
        case month(year: Int, month: Int) // month 1...12
        case year(Int)
        /// Whole days from the start day through the end day, inclusive.
        case range(start: Date, end: Date)
    }

    var period: Period
    var classification: TripClassification? // nil = All

    init(period: Period, classification: TripClassification? = nil) {
        self.period = period
        self.classification = classification
    }

    init(year: Int, month: Int, classification: TripClassification? = nil) {
        self.init(period: .month(year: year, month: month), classification: classification)
    }

    init(year: Int, classification: TripClassification? = nil) {
        self.init(period: .year(year), classification: classification)
    }

    init(monthContaining date: Date, classification: TripClassification? = nil, calendar: Calendar = .current) {
        let comps = calendar.dateComponents([.year, .month], from: date)
        self.init(
            period: .month(year: comps.year ?? 1970, month: comps.month ?? 1),
            classification: classification
        )
    }

    func matches(_ trip: Trip, calendar: Calendar = .current) -> Bool {
        // Deleted trips are hidden; a trip still being recorded has no final distance yet.
        guard !trip.isDeleted, !trip.isInProgress else { return false }
        switch period {
        case let .month(year, month):
            let comps = calendar.dateComponents([.year, .month], from: trip.startDate)
            guard comps.year == year, comps.month == month else { return false }
        case let .year(year):
            guard calendar.component(.year, from: trip.startDate) == year else { return false }
        case let .range(start, end):
            let first = calendar.startOfDay(for: min(start, end))
            let lastDay = calendar.startOfDay(for: max(start, end))
            guard let last = calendar.date(byAdding: .day, value: 1, to: lastDay),
                  trip.startDate >= first, trip.startDate < last else { return false }
        }
        if let classification, trip.classification != classification { return false }
        return true
    }

    /// "March 2026", "2026", or "Mar 1, 2026 – Mar 31, 2026".
    var periodTitle: String {
        switch period {
        case let .month(year, month):
            let date = Calendar.current.date(from: DateComponents(year: year, month: month, day: 1)) ?? Date()
            return Formatters.monthTitle.string(from: date)
        case let .year(year):
            return String(year)
        case let .range(start, end):
            let first = min(start, end)
            let last = max(start, end)
            return "\(Formatters.mediumDate.string(from: first)) \u{2013} \(Formatters.mediumDate.string(from: last))"
        }
    }

    /// The calendar months the period covers, as "yyyy-MM" keys with a sortable index.
    func months(calendar: Calendar = .current) -> [(key: String, index: Int)] {
        func entry(_ year: Int, _ month: Int) -> (key: String, index: Int) {
            (String(format: "%04d-%02d", year, month), year * 12 + month)
        }
        switch period {
        case let .month(year, month):
            return [entry(year, month)]
        case let .year(year):
            return (1...12).map { entry(year, $0) }
        case let .range(start, end):
            let first = calendar.dateComponents([.year, .month], from: min(start, end))
            let last = calendar.dateComponents([.year, .month], from: max(start, end))
            guard let fy = first.year, let fm = first.month, let ly = last.year, let lm = last.month else { return [] }
            return ((fy * 12 + fm)...(ly * 12 + lm)).map { index in
                entry((index - 1) / 12, (index - 1) % 12 + 1)
            }
        }
    }

    /// A date inside the period (its last month's start), for picking that year's IRS rate.
    func referenceDate(calendar: Calendar = .current) -> Date {
        switch period {
        case let .month(year, month):
            return calendar.date(from: DateComponents(year: year, month: month, day: 1)) ?? Date()
        case let .year(year):
            return calendar.date(from: DateComponents(year: year, month: 12, day: 1)) ?? Date()
        case let .range(start, end):
            return max(start, end)
        }
    }

    var classificationLabel: String {
        classification?.displayName ?? "All"
    }
}

enum ExportFetcher {
    static func fetchTrips(from allTrips: [Trip], filter: ExportFilter) -> [Trip] {
        allTrips.filter { filter.matches($0) }.sorted { $0.startDate < $1.startDate }
    }

    /// Sum of the miles as printed (one decimal), so the total matches the column above it.
    static func totalMiles(_ trips: [Trip]) -> Double {
        trips.reduce(0) { $0 + Reimbursement.displayedMiles($1.distanceMiles) }
    }
}

/// A per-mile reimbursement rate and the symbol of the currency it's paid in.
struct ReimbursementRate: Equatable {
    /// The per-mile (variable) rate. With `irsTable` it is the IRS rate for the period shown.
    var perMile: Double
    var currencySymbol = "$"
    /// When set, each trip is paid at the IRS rate for the year it was made.
    var irsTable: [Int: Double]?
    /// FAVR: a fixed amount per month, paid for each month with at least `minMonthlyMiles`
    /// business miles (0 = every month), on top of the per-mile rate.
    var fixedMonthly: Double = 0
    var minMonthlyMiles: Double = 0

    var isFAVR: Bool { fixedMonthly > 0 }

    /// The per-mile rate for a trip made on `date`.
    func perMile(on date: Date, calendar: Calendar = .current) -> Double {
        guard let irsTable else { return perMile }
        return IRSRates.rate(on: date, in: irsTable, calendar: calendar)
    }

    /// e.g. "$0.725/mi" — at least two decimals, up to three; FAVR adds "+ $250.00/mo".
    var label: String {
        let base = "\(currencySymbol)\(AppSettings.formatRate(perMile))/mi"
        return isFAVR ? base + " + " + format(fixedMonthly) + "/mo" : base
    }

    /// e.g. "$5.22"
    func format(_ amount: Double) -> String {
        currencySymbol + String(format: "%.2f", amount)
    }
}

enum Reimbursement {
    /// Miles rounded to one decimal, as every export prints them. Amounts and totals are
    /// computed from this so each row is exactly miles × rate for the numbers the reader sees.
    static func displayedMiles(_ miles: Double) -> Double {
        (miles * 10).rounded() / 10
    }

    /// Displayed miles × rate, rounded to the cent.
    static func amount(miles: Double, rate: Double) -> Double {
        (displayedMiles(miles) * rate * 100).rounded() / 100
    }

    /// Sum of the per-trip amounts, so the total matches the column it sits under.
    static func total(_ trips: [Trip], rate: Double) -> Double {
        trips.reduce(0) { $0 + amount(miles: $1.distanceMiles, rate: rate) }
    }

    /// One trip's per-mile amount, at the rate for the year it was made when the rate follows the
    /// IRS table.
    static func amount(for trip: Trip, rate: ReimbursementRate) -> Double {
        amount(miles: trip.distanceMiles, rate: rate.perMile(on: trip.startDate))
    }

    /// Sum of the per-trip amounts (the per-mile part only; see `fixedAmount`).
    static func total(_ trips: [Trip], rate: ReimbursementRate) -> Double {
        trips.reduce(0) { $0 + amount(for: $1, rate: rate) }
    }

    /// FAVR's fixed part for the filter's period: the fixed monthly amount for each month up to
    /// `now` in which the business miles reach the minimum. Zero when the rate has no fixed part
    /// or the export is only personal/unclassified trips.
    static func fixedAmount(
        trips: [Trip], filter: ExportFilter, rate: ReimbursementRate, now: Date = .now,
        calendar: Calendar = .current
    ) -> Double {
        guard rate.isFAVR, filter.classification == nil || filter.classification == .business else { return 0 }
        var businessMiles: [String: Double] = [:]
        for trip in trips where trip.classification == .business {
            let key = monthKey(trip.startDate, calendar: calendar)
            businessMiles[key, default: 0] += displayedMiles(trip.distanceMiles)
        }
        let current = calendar.dateComponents([.year, .month], from: now)
        let currentIndex = (current.year ?? 0) * 12 + (current.month ?? 1)
        let qualifying = filter.months(calendar: calendar).filter { $0.index <= currentIndex }.filter { month in
            rate.minMonthlyMiles <= 0 || (businessMiles[month.key] ?? 0) >= rate.minMonthlyMiles
        }
        return (Double(qualifying.count) * rate.fixedMonthly * 100).rounded() / 100
    }

    /// Number of months the fixed amount is paid for (for the "× N months" note).
    static func fixedMonthCount(fixedAmount: Double, rate: ReimbursementRate) -> Int {
        rate.fixedMonthly > 0 ? Int((fixedAmount / rate.fixedMonthly).rounded()) : 0
    }

    private static func monthKey(_ date: Date, calendar: Calendar) -> String {
        let comps = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", comps.year ?? 0, comps.month ?? 0)
    }

    static func columnTitle(rate: ReimbursementRate) -> String {
        "Reimbursement (\(rate.label))"
    }
}

enum ExportColumns {
    /// Column titles shared by the CSV, Excel and PDF exports.
    static func titles(rate: ReimbursementRate) -> [String] {
        ["Date", "Start", "End", "Miles", "Classification", "Purpose", Reimbursement.columnTitle(rate: rate)]
    }
}

enum ExportNaming {
    static func fileBaseName(filter: ExportFilter) -> String {
        let periodSlug: String
        switch filter.period {
        case let .month(year, month):
            periodSlug = String(format: "%04d-%02d", year, month)
        case let .year(year):
            periodSlug = String(format: "%04d", year)
        case let .range(start, end):
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd"
            periodSlug = "\(formatter.string(from: min(start, end)))_\(formatter.string(from: max(start, end)))"
        }
        let classSlug = filter.classification?.rawValue ?? "all"
        return "MilesProSync-\(periodSlug)-\(classSlug)"
    }
}
