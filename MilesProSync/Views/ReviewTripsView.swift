import SwiftData
import SwiftUI

/// The trips still waiting for a Business or Personal choice, with swipe and bulk actions.
struct ReviewTripsView: View {
    let trips: [Trip]

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var selection = Set<UUID>()
    @State private var editMode: EditMode = .inactive

    /// Trips classified in this session drop out of the queue as they are handled.
    private var pending: [Trip] {
        trips.filter { $0.classification == .unclassified && !$0.isDeleted }
    }

    var body: some View {
        NavigationStack {
            List(selection: $selection) {
                ForEach(pending) { trip in
                    TripReviewRow(trip: trip)
                        .tag(trip.id)
                        .swipeActions(edge: .leading) {
                            Button { apply(.business, to: [trip]) } label: {
                                Label("Business", systemImage: "briefcase")
                            }
                            .tint(TripClassification.business.accentColor)
                        }
                        .swipeActions(edge: .trailing) {
                            Button { apply(.personal, to: [trip]) } label: {
                                Label("Personal", systemImage: "person")
                            }
                            .tint(TripClassification.personal.accentColor)
                        }
                }
            }
            .environment(\.editMode, $editMode)
            .listStyle(.insetGrouped)
            .brandedBackground()
            .navigationTitle("Needs Review")
            .navigationBarTitleDisplayMode(.inline)
            .overlay {
                if pending.isEmpty {
                    ContentUnavailableView(
                        "All caught up", systemImage: "checkmark.circle",
                        description: Text("Every trip is classified as Business or Personal.")
                    )
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    if !pending.isEmpty {
                        Button(editMode.isEditing ? "Cancel" : "Select") {
                            editMode = editMode.isEditing ? .inactive : .active
                            selection.removeAll()
                        }
                    }
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    if editMode.isEditing {
                        Button("Select All") { selection = Set(pending.map(\.id)) }
                        Spacer()
                        Button("Personal") { applyToSelection(.personal) }
                            .disabled(selection.isEmpty)
                        Button("Business") { applyToSelection(.business) }
                            .disabled(selection.isEmpty)
                    }
                }
            }
        }
    }

    private func applyToSelection(_ classification: TripClassification) {
        apply(classification, to: pending.filter { selection.contains($0.id) })
        selection.removeAll()
    }

    private func apply(_ classification: TripClassification, to trips: [Trip]) {
        for trip in trips { trip.classification = classification }
        // Save now so the change uploads promptly instead of waiting for autosave.
        try? modelContext.save()
    }
}

private struct TripReviewRow: View {
    let trip: Trip

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(trip.startAddressText) \u{2192} \(trip.endAddressText)")
                .font(.subheadline)
                .lineLimit(2)
            Text("\(Formatters.mediumDate.string(from: trip.startDate)) \u{00B7} \(Formatters.miles(trip.distanceMiles))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
