import CoreLocation
import SwiftData
import SwiftUI

/// Saved places and work hours that classify new trips automatically.
struct AutoClassificationView: View {
    @State private var rules = ClassificationRules.load()
    @State private var showingAddPlace = false
    @State private var appliedCount: Int?
    @Environment(\.modelContext) private var modelContext

    private static let weekdays: [(number: Int, label: String)] = [
        (2, "Mon"), (3, "Tue"), (4, "Wed"), (5, "Thu"), (6, "Fri"), (7, "Sat"), (1, "Sun"),
    ]

    var body: some View {
        Form {
            Section {
                Toggle("Use work hours", isOn: $rules.workHoursEnabled)
                if rules.workHoursEnabled {
                    DatePicker("From", selection: minutesBinding(\.workStartMinutes), displayedComponents: .hourAndMinute)
                    DatePicker("To", selection: minutesBinding(\.workEndMinutes), displayedComponents: .hourAndMinute)
                    HStack {
                        ForEach(Self.weekdays, id: \.number) { day in
                            Toggle(day.label, isOn: dayBinding(day.number))
                                .toggleStyle(.button)
                                .font(.caption)
                        }
                    }
                }
            } header: {
                Text("Work Hours")
            } footer: {
                Text("A drive that starts during work hours is Business; any other drive is Personal. Saved places take priority.")
            }

            Section {
                ForEach(rules.places) { place in
                    LabeledContent(place.name, value: place.classification.displayName)
                }
                .onDelete { rules.places.remove(atOffsets: $0) }
                Button("Add Place\u{2026}") { showingAddPlace = true }
            } header: {
                Text("Saved Places")
            } footer: {
                Text("Trips ending at a saved place get its classification; otherwise trips starting there do.")
            }

            Section {
                Button("Apply to Unclassified Trips") { applyToExisting() }
                    .disabled(rules.isEmpty)
                if let appliedCount {
                    Text("\(appliedCount) trip(s) classified.")
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("Trips you classified yourself are never changed.")
            }
        }
        .brandedBackground()
        .navigationTitle("Auto-Classification")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: rules) { rules.save() }
        .sheet(isPresented: $showingAddPlace) {
            AddPlaceView { rules.places.append($0) }
        }
    }

    private func applyToExisting() {
        let trips = (try? modelContext.fetch(FetchDescriptor<Trip>(
            predicate: #Predicate { $0.deletedAt == nil && !$0.isInProgress && !$0.isManuallyClassified }
        ))) ?? []
        let changed = trips.filter { rules.apply(to: $0) }.count
        try? modelContext.save()
        appliedCount = changed
    }

    private func dayBinding(_ weekday: Int) -> Binding<Bool> {
        Binding(
            get: { rules.workDays.contains(weekday) },
            set: { isOn in
                if isOn { rules.workDays.insert(weekday) } else { rules.workDays.remove(weekday) }
            }
        )
    }

    /// A time-of-day stored as minutes since midnight, shown through a `DatePicker`.
    private func minutesBinding(_ keyPath: WritableKeyPath<ClassificationRules, Int>) -> Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(
                    bySettingHour: rules[keyPath: keyPath] / 60, minute: rules[keyPath: keyPath] % 60, second: 0, of: .now
                ) ?? .now
            },
            set: { date in
                let comps = Calendar.current.dateComponents([.hour, .minute], from: date)
                rules[keyPath: keyPath] = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
            }
        )
    }
}

private struct AddPlaceView: View {
    let onAdd: (SavedPlace) -> Void
    @State private var name = ""
    @State private var address = ""
    @State private var classification: TripClassification = .business
    @State private var isSaving = false
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Place") {
                    TextField("Name (e.g. Office)", text: $name)
                    TextField("Address", text: $address)
                        .textContentType(.fullStreetAddress)
                }
                Section("Trips to or from here are") {
                    Picker("Classification", selection: $classification) {
                        Text("Business").tag(TripClassification.business)
                        Text("Personal").tag(TripClassification.personal)
                    }
                    .pickerStyle(.segmented)
                }
                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red) }
                }
            }
            .brandedBackground()
            .navigationTitle("Add Place")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("Save") { Task { await save() } }
                            .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty
                                || address.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            .disabled(isSaving)
        }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        guard let coordinate = await GeocodingService.coordinate(for: address) else {
            errorMessage = "Couldn't find that address. Check it and try again."
            return
        }
        onAdd(SavedPlace(
            name: name.trimmingCharacters(in: .whitespaces),
            latitude: coordinate.latitude, longitude: coordinate.longitude,
            classification: classification
        ))
        dismiss()
    }
}
