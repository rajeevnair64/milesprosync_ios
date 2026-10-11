import SwiftData
import SwiftUI

struct TripRowView: View {
    @Bindable var trip: Trip
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(routeSummary)
                    .font(.subheadline)
                    .lineLimit(2)
                Text(timeRange)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 4) {
                if trip.isInProgress {
                    Label("Recording", systemImage: "record.circle")
                        .font(.caption.bold())
                        .foregroundStyle(.red)
                }
                Text(Formatters.miles(trip.displayedDistanceMiles))
                    .font(.subheadline.monospacedDigit())
                Picker("Classification", selection: $trip.classification) {
                    ForEach(TripClassification.allCases) { classification in
                        Text(classification.displayName).tag(classification)
                    }
                }
                .pickerStyle(.menu)
                .font(.caption)
                .labelsHidden()
                // Save right away rather than waiting for autosave, so the change uploads promptly.
                .onChange(of: trip.classificationRaw) { try? modelContext.save() }
            }
        }
        .padding(.vertical, 4)
    }

    private var routeSummary: String {
        "\(trip.startAddressText) \u{2192} \(trip.endAddressText)"
    }

    private var timeRange: String {
        let start = Formatters.timeOnly.string(from: trip.startDate)
        return trip.isInProgress
            ? "Started \(start)"
            : "\(start) \u{2013} \(Formatters.timeOnly.string(from: trip.endDate))"
    }
}
