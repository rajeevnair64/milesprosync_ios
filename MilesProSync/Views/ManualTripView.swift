import CoreLocation
import SwiftData
import SwiftUI

/// Form for logging a drive the app didn't record (phone off, no signal, a trip in someone else's car).
struct ManualTripView: View {
    /// The trip being edited; nil adds a new one.
    let editing: Trip?
    @State private var draft: ManualTripDraft
    @AppStorage(TripPurposes.key) private var storedPurposes = TripPurposes.encode(TripPurposes.defaults)
    @State private var isSaving = false
    @State private var errorMessage: String?
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    init(editing trip: Trip? = nil) {
        editing = trip
        _draft = State(initialValue: trip.map(ManualTripDraft.init(trip:)) ?? ManualTripDraft())
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("When") {
                    DatePicker("Start", selection: $draft.startDate, in: ...Date.now)
                    DatePicker("End", selection: $draft.endDate, in: ...Date.now)
                }

                Section("Where") {
                    TextField("From (address)", text: $draft.fromAddress)
                        .textContentType(.fullStreetAddress)
                    TextField("To (address)", text: $draft.toAddress)
                        .textContentType(.fullStreetAddress)
                }

                Section("Distance") {
                    HStack {
                        TextField("0.0", text: $draft.distanceText)
                            .keyboardType(.decimalPad)
                        Text("miles")
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Classification") {
                    Picker("Classification", selection: $draft.classification) {
                        ForEach(TripClassification.allCases) { classification in
                            Text(classification.displayName).tag(classification)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section("Purpose") {
                    Picker("Purpose", selection: $draft.purpose) {
                        Text("None").tag(String?.none)
                        ForEach(purposeChoices, id: \.self) { purpose in
                            Text(purpose).tag(String?.some(purpose))
                        }
                    }
                }

                Section("Notes") {
                    TextField("Add a note", text: $draft.notes, axis: .vertical)
                        .lineLimit(1...6)
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }
            }
            .brandedBackground()
            .navigationTitle(editing == nil ? "Add Trip" : "Edit Trip")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("Save") { Task { await save() } }
                    }
                }
            }
            .disabled(isSaving)
        }
    }

    private func save() async {
        if let problem = draft.problems().first {
            errorMessage = problem.message
            return
        }
        isSaving = true
        defer { isSaving = false }

        if let trip = editing {
            await saveEdits(to: trip)
            return
        }

        guard let start = await Self.coordinate(for: draft.fromAddress) else {
            errorMessage = "Couldn't find the start address. Check it and try again."
            return
        }
        guard let end = await Self.coordinate(for: draft.toAddress) else {
            errorMessage = "Couldn't find the end address. Check it and try again."
            return
        }
        guard let trip = draft.makeTrip(start: start, end: end) else { return }

        modelContext.insert(trip)
        // Save now so the trip uploads promptly instead of waiting for autosave.
        do {
            try modelContext.save()
            dismiss()
        } catch {
            modelContext.delete(trip)
            errorMessage = "Couldn't save the trip: \(error.localizedDescription)"
        }
    }

    /// Only an address that changed is looked up again; the other keeps its coordinate.
    private func saveEdits(to trip: Trip) async {
        let from = draft.fromAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        let to = draft.toAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        var start: CLLocationCoordinate2D?
        var end: CLLocationCoordinate2D?
        if from != trip.startAddress {
            guard let found = await Self.coordinate(for: from) else {
                errorMessage = "Couldn't find the start address. Check it and try again."
                return
            }
            start = found
        }
        if to != trip.endAddress {
            guard let found = await Self.coordinate(for: to) else {
                errorMessage = "Couldn't find the end address. Check it and try again."
                return
            }
            end = found
        }
        draft.apply(to: trip, start: start, end: end)
        do {
            try modelContext.save()
            dismiss()
        } catch {
            errorMessage = "Couldn't save the trip: \(error.localizedDescription)"
        }
    }

    /// The saved purposes, plus the trip's own if it was removed from the list since.
    private var purposeChoices: [String] {
        let saved = TripPurposes.parse(storedPurposes)
        guard let current = draft.purpose, !saved.contains(current) else { return saved }
        return saved + [current]
    }

    private static func coordinate(for address: String) async -> CLLocationCoordinate2D? {
        await GeocodingService.coordinate(for: address)
    }
}

#Preview {
    ManualTripView()
        .modelContainer(for: [Trip.self, RoutePoint.self], inMemory: true)
}
