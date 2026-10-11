import CoreLocation
import MapKit
import SwiftData
import SwiftUI

struct TripDetailView: View {
    @Bindable var trip: Trip
    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var confirmingDelete = false
    @State private var confirmingFinish = false
    @Environment(AppSession.self) private var appSession
    @FocusState private var notesFocused: Bool
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Map(position: $cameraPosition) {
                    if trip.routeCoordinates.count > 1 {
                        MapPolyline(coordinates: trip.routeCoordinates)
                            .stroke(.blue, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                    }
                    Marker("Start", systemImage: "circle.fill", coordinate: trip.startCoordinate)
                        .tint(.green)
                    Marker("End", systemImage: "mappin", coordinate: trip.endCoordinate)
                        .tint(.red)
                }
                .frame(height: 280)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal)

                VStack(alignment: .leading, spacing: 8) {
                    LabeledRow(
                        label: "Distance",
                        value: Formatters.miles(trip.displayedDistanceMiles) + (trip.isInProgress ? " so far" : "")
                    )
                    LabeledRow(label: "Date", value: Formatters.mediumDate.string(from: trip.startDate))
                    LabeledRow(
                        label: "Time",
                        value: trip.isInProgress
                            ? "Started \(Formatters.timeOnly.string(from: trip.startDate)), recording"
                            : "\(Formatters.timeOnly.string(from: trip.startDate)) \u{2013} \(Formatters.timeOnly.string(from: trip.endDate))"
                    )
                    LabeledRow(label: "From", value: trip.startAddressText)
                    LabeledRow(label: "To", value: trip.endAddressText)
                }
                .padding(.horizontal)

                if trip.isInProgress {
                    Button {
                        confirmingFinish = true
                    } label: {
                        Label("Finish Trip", systemImage: "flag.checkered")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(.horizontal)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Classification")
                        .font(.headline)
                    ClassificationPicker(trip: trip)
                }
                .padding(.horizontal)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Notes")
                        .font(.headline)
                    TextField(
                        "Add a note",
                        text: Binding(get: { trip.notes ?? "" }, set: { trip.setNotes($0) }),
                        axis: .vertical
                    )
                    .lineLimit(1...6)
                    .focused($notesFocused)
                    .textFieldStyle(.roundedBorder)
                    // Save when editing ends so the note uploads promptly.
                    .onChange(of: notesFocused) { if !notesFocused { try? modelContext.save() } }
                }
                .padding(.horizontal)
            }
            .padding(.vertical)
        }
        .navigationTitle("Trip Details")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .destructiveAction) {
                Button(role: .destructive) {
                    confirmingDelete = true
                } label: {
                    Label("Delete Trip", systemImage: "trash")
                }
                .disabled(trip.isInProgress)
            }
        }
        .confirmationDialog("Finish this trip here?", isPresented: $confirmingFinish, titleVisibility: .visible) {
            Button("Finish Trip") { appSession.finishCurrentTrip() }
        } message: {
            Text("The trip ends at your current location. Driving on starts a new trip.")
        }
        .confirmationDialog("Delete this trip?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete Trip", role: .destructive) {
                trip.markDeleted()
                try? modelContext.save()
                dismiss()
            }
        } message: {
            Text("It will be removed from your trip list and exports.")
        }
        .onAppear { fitCamera() }
        .onDisappear { try? modelContext.save() }
    }

    private func fitCamera() {
        let coordinates = trip.routeCoordinates.isEmpty ? [trip.startCoordinate, trip.endCoordinate] : trip.routeCoordinates
        guard let minLat = coordinates.map(\.latitude).min(),
              let maxLat = coordinates.map(\.latitude).max(),
              let minLon = coordinates.map(\.longitude).min(),
              let maxLon = coordinates.map(\.longitude).max() else { return }

        let center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2)
        let span = MKCoordinateSpan(
            latitudeDelta: max((maxLat - minLat) * 1.4, 0.01),
            longitudeDelta: max((maxLon - minLon) * 1.4, 0.01)
        )
        cameraPosition = .region(MKCoordinateRegion(center: center, span: span))
    }
}

private struct LabeledRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .top) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .leading)
            Text(value)
            Spacer()
        }
        .font(.subheadline)
    }
}
