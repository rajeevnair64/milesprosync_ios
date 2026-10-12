import SwiftData
import SwiftUI

struct TripRowView: View {
    @Bindable var trip: Trip
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        ViewThatFits(in: .horizontal) {
            rowLayout(horizontal: true)
            rowLayout(horizontal: false)
        }
        .padding(.vertical, 6)
    }

    private func rowLayout(horizontal: Bool) -> some View {
        let layout = horizontal
            ? AnyLayout(HStackLayout(alignment: .top, spacing: 12))
            : AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
        return layout {
            VStack(alignment: .leading, spacing: 4) {
                Text(routeSummary)
                    .font(.subheadline)
                    .lineLimit(2)
                Text(timeRange)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if horizontal { Spacer(minLength: 8) }
            VStack(alignment: horizontal ? .trailing : .leading, spacing: 6) {
                if trip.isInProgress {
                    RecordingBadge()
                }
                Text(Formatters.miles(trip.displayedDistanceMiles))
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(AppTheme.ink)
                Picker("Classification", selection: $trip.classification) {
                    ForEach(TripClassification.allCases) { classification in
                        Text(classification.displayName).tag(classification)
                    }
                }
                .pickerStyle(.menu)
                .font(.caption)
                .labelsHidden()
                .tint(trip.classification.accentColor)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(trip.classification.accentColor.opacity(0.12), in: Capsule())
                .accessibilityLabel("Trip classification")
                // Save right away rather than waiting for autosave, so the change uploads promptly.
                .onChange(of: trip.classificationRaw) { try? modelContext.save() }
            }
        }

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
