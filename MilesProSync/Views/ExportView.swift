import SwiftUI

struct ExportView: View {
    let trips: [Trip]

    @Environment(\.dismiss) private var dismiss
    private enum PeriodKind: String, CaseIterable, Identifiable {
        case month = "Month", year = "Year", custom = "Custom"
        var id: String { rawValue }
    }

    @State private var periodKind: PeriodKind = .month
    @State private var selectedMonth = Date()
    @State private var selectedYear = Calendar.current.component(.year, from: .now)
    @State private var rangeStart = Calendar.current.date(byAdding: .month, value: -1, to: .now) ?? .now
    @State private var rangeEnd = Date()
    @State private var classification: TripClassification? = .business
    @State private var format: ExportFormat = .csv
    @State private var exportURL: URL?
    @State private var errorMessage: String?
    @AppStorage(AppSettings.Key.mileageRate) private var mileageRate = AppSettings.defaultMileageRate
    @AppStorage(AppSettings.Key.countryCode) private var countryCode = AppSettings.defaultCountryCode
    @AppStorage(AppSettings.Key.rateMode) private var rateMode = AppSettings.RateMode.irs.rawValue
    @AppStorage(AppSettings.Key.favrFixedMonthly) private var favrFixedMonthly = 0.0
    @AppStorage(AppSettings.Key.favrPerMile) private var favrPerMile = 0.0
    @AppStorage(AppSettings.Key.favrMinMonthlyMiles) private var favrMinMonthlyMiles = 0.0

    var body: some View {
        NavigationStack {
            Form {
                Section("Period") {
                    Picker("Period", selection: $periodKind) {
                        ForEach(PeriodKind.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    switch periodKind {
                    case .month:
                        DatePicker("Month", selection: $selectedMonth, displayedComponents: .date)
                            .datePickerStyle(.compact)
                    case .year:
                        Picker("Year", selection: $selectedYear) {
                            ForEach(availableYears, id: \.self) { Text(String($0)).tag($0) }
                        }
                    case .custom:
                        DatePicker("From", selection: $rangeStart, displayedComponents: .date)
                        DatePicker("To", selection: $rangeEnd, displayedComponents: .date)
                    }
                }
                Section("Trip type") {
                    Picker("Trip type", selection: $classification) {
                        Text("All").tag(TripClassification?.none)
                        ForEach(TripClassification.allCases) { value in
                            Text(value.displayName).tag(TripClassification?.some(value))
                        }
                    }
                    .pickerStyle(.segmented)
                }
                Section("Format") {
                    Picker("Format", selection: $format) {
                        ForEach(ExportFormat.allCases) { value in
                            Text(value.displayName).tag(value)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                Section {
                    Text("\(matchingTrips.count) trip(s), \(Formatters.miles(totalMiles)) total")
                        .foregroundStyle(.secondary)
                    Text("Reimbursement: \(rate.format(totalReimbursement + fixedAmount)) at \(rate.label)")
                        .foregroundStyle(.secondary)
                    if fixedAmount > 0 {
                        Text("Includes \(rate.format(fixedAmount)) fixed monthly amount")
                            .foregroundStyle(.secondary)
                    }
                }
                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(.red)
                    }
                }
            }
            .brandedBackground()
            .navigationTitle("Export Trips")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if let exportURL {
                        ShareLink(item: exportURL) {
                            Label("Share", systemImage: "square.and.arrow.up")
                        }
                    } else {
                        Button("Generate") { generate() }
                    }
                }
            }
            .onChange(of: periodKind) { exportURL = nil }
            .onChange(of: selectedMonth) { exportURL = nil }
            .onChange(of: selectedYear) { exportURL = nil }
            .onChange(of: rangeStart) { exportURL = nil }
            .onChange(of: rangeEnd) { exportURL = nil }
            .onChange(of: classification) { exportURL = nil }
            .onChange(of: format) { exportURL = nil }
        }
    }

    private var filter: ExportFilter {
        switch periodKind {
        case .month:
            ExportFilter(monthContaining: selectedMonth, classification: classification)
        case .year:
            ExportFilter(year: selectedYear, classification: classification)
        case .custom:
            ExportFilter(period: .range(start: rangeStart, end: rangeEnd), classification: classification)
        }
    }

    /// Years that have trips, plus this one.
    private var availableYears: [Int] {
        let calendar = Calendar.current
        let years = Set(trips.map { calendar.component(.year, from: $0.startDate) })
            .union([calendar.component(.year, from: .now), selectedYear])
        return years.sorted(by: >)
    }

    private var matchingTrips: [Trip] {
        ExportFetcher.fetchTrips(from: trips, filter: filter)
    }

    private var totalMiles: Double {
        ExportFetcher.totalMiles(matchingTrips)
    }

    private var rate: ReimbursementRate {
        AppSettings.reimbursementRate(
            mode: AppSettings.RateMode(rawValue: rateMode) ?? .irs,
            customPerMile: mileageRate,
            favrFixedMonthly: favrFixedMonthly, favrPerMile: favrPerMile, favrMinMonthlyMiles: favrMinMonthlyMiles,
            countryCode: countryCode, at: filter.referenceDate()
        )
    }

    private var totalReimbursement: Double {
        Reimbursement.total(matchingTrips, rate: rate)
    }

    private var fixedAmount: Double {
        Reimbursement.fixedAmount(trips: matchingTrips, filter: filter, rate: rate)
    }

    private func generate() {
        errorMessage = nil
        do {
            switch format {
            case .csv:
                exportURL = try CSVExporter.export(trips: matchingTrips, filter: filter, rate: rate)
            case .pdf:
                exportURL = try PDFExporter.export(trips: matchingTrips, filter: filter, rate: rate)
            case .xlsx:
                exportURL = try XLSXExporter.export(trips: matchingTrips, filter: filter, rate: rate)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
