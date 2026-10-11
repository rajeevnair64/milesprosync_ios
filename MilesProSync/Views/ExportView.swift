import SwiftUI

struct ExportView: View {
    let trips: [Trip]

    @Environment(\.dismiss) private var dismiss
    @State private var selectedMonth = Date()
    @State private var classification: TripClassification?
    @State private var format: ExportFormat = .csv
    @State private var exportURL: URL?
    @State private var errorMessage: String?
    @AppStorage(AppSettings.Key.mileageRate) private var mileageRate = AppSettings.defaultMileageRate
    @AppStorage(AppSettings.Key.countryCode) private var countryCode = AppSettings.defaultCountryCode

    var body: some View {
        NavigationStack {
            Form {
                Section("Month") {
                    DatePicker("Month", selection: $selectedMonth, displayedComponents: .date)
                        .datePickerStyle(.compact)
                        .labelsHidden()
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
                    Text("Reimbursement: \(rate.format(totalReimbursement)) at \(rate.label)")
                        .foregroundStyle(.secondary)
                }
                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(.red)
                    }
                }
            }
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
            .onChange(of: selectedMonth) { exportURL = nil }
            .onChange(of: classification) { exportURL = nil }
            .onChange(of: format) { exportURL = nil }
        }
    }

    private var filter: ExportFilter {
        ExportFilter(monthContaining: selectedMonth, classification: classification)
    }

    private var matchingTrips: [Trip] {
        ExportFetcher.fetchTrips(from: trips, filter: filter)
    }

    private var totalMiles: Double {
        ExportFetcher.totalMiles(matchingTrips)
    }

    private var rate: ReimbursementRate {
        AppSettings.reimbursementRate(perMile: mileageRate, countryCode: countryCode)
    }

    private var totalReimbursement: Double {
        Reimbursement.total(matchingTrips, rate: rate.perMile)
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
