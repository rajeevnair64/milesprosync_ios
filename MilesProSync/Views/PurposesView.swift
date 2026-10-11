import SwiftUI

/// Edits the list of purposes a trip can be tagged with.
struct PurposesView: View {
    @AppStorage(TripPurposes.key) private var stored = TripPurposes.encode(TripPurposes.defaults)
    @State private var newPurpose = ""

    private var purposes: [String] { TripPurposes.parse(stored) }

    var body: some View {
        List {
            Section {
                ForEach(purposes, id: \.self) { purpose in
                    Text(purpose)
                }
                .onDelete { offsets in
                    var updated = purposes
                    updated.remove(atOffsets: offsets)
                    stored = TripPurposes.encode(updated)
                }
            } footer: {
                Text("Removing a purpose doesn't change trips already tagged with it.")
            }
            Section("Add Purpose") {
                HStack {
                    TextField("e.g. Site inspection", text: $newPurpose)
                        .submitLabel(.done)
                        .onSubmit(add)
                    Button("Add", action: add)
                        .disabled(newPurpose.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .navigationTitle("Trip Purposes")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func add() {
        stored = TripPurposes.encode(TripPurposes.adding(newPurpose, to: purposes))
        newPurpose = ""
    }
}
