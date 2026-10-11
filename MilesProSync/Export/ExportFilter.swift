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
    var year: Int
    var month: Int // 1...12
    var classification: TripClassification? // nil = All

    init(year: Int, month: Int, classification: TripClassification? = nil) {
        self.year = year
        self.month = month
        self.classification = classification
    }

    init(monthContaining date: Date, classification: TripClassification? = nil, calendar: Calendar = .current) {
        let comps = calendar.dateComponents([.year, .month], from: date)
        self.year = comps.year ?? 1970
        self.month = comps.month ?? 1
        self.classification = classification
    }

    func matches(_ trip: Trip, calendar: Calendar = .current) -> Bool {
        // Deleted trips are hidden; a trip still being recorded has no final distance yet.
        guard !trip.isDeleted, !trip.isInProgress else { return false }
        let comps = calendar.dateComponents([.year, .month], from: trip.startDate)
        guard comps.year == year, comps.month == month else { return false }
        if let classification, trip.classification != classification { return false }
        return true
    }

    func firstOfMonth(calendar: Calendar = .current) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: 1)) ?? Date()
    }

    var monthTitle: String {
        Formatters.monthTitle.string(from: firstOfMonth())
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
    var perMile: Double
    var currencySymbol = "$"

    /// e.g. "$0.725/mi" — at least two decimals, up to three.
    var label: String {
        "\(currencySymbol)\(AppSettings.formatRate(perMile))/mi"
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

    static func columnTitle(rate: ReimbursementRate) -> String {
        "Reimbursement (\(rate.label))"
    }
}

enum ExportColumns {
    /// Column titles shared by the CSV, Excel and PDF exports.
    static func titles(rate: ReimbursementRate) -> [String] {
        ["Date", "Start", "End", "Miles", "Classification", Reimbursement.columnTitle(rate: rate)]
    }
}

enum ExportNaming {
    static func fileBaseName(filter: ExportFilter) -> String {
        let monthSlug = String(format: "%04d-%02d", filter.year, filter.month)
        let classSlug = filter.classification?.rawValue ?? "all"
        return "MilesProSync-\(monthSlug)-\(classSlug)"
    }
}
