import SwiftData
import SwiftUI

struct ClassificationPicker: View {
    @Bindable var trip: Trip
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        Picker("Classification", selection: $trip.classification) {
            ForEach(TripClassification.allCases) { classification in
                Text(classification.displayName).tag(classification)
            }
        }
        .pickerStyle(.segmented)
        // Save right away rather than waiting for autosave, so the change uploads promptly.
        .onChange(of: trip.classificationRaw) { try? modelContext.save() }
    }
}
