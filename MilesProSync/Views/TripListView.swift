import SwiftData
import SwiftUI

struct TripListView: View {
    @Query(filter: #Predicate<Trip> { $0.deletedAt == nil }, sort: \Trip.startDate, order: .reverse)
    private var trips: [Trip]
    @Environment(\.modelContext) private var modelContext
    @State private var showingExport = false
    @State private var showingSettings = false
    @State private var confirmingFinish = false
    @Environment(AppSession.self) private var appSession

    var body: some View {
        NavigationStack {
            List {
                ForEach(monthSections, id: \.key) { section in
                    Section(section.title) {
                        ForEach(section.trips) { trip in
                            NavigationLink(value: trip) {
                                TripRowView(trip: trip)
                            }
                            // A trip still being recorded can't be deleted until it finishes.
                            .deleteDisabled(trip.isInProgress)
                            .swipeActions(edge: .leading) {
                                if trip.isInProgress {
                                    Button {
                                        confirmingFinish = true
                                    } label: {
                                        Label("Finish", systemImage: "flag.checkered")
                                    }
                                    .tint(.green)
                                }
                            }
                        }
                        .onDelete { offsets in
                            delete(offsets.map { section.trips[$0] })
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Trips")
            .navigationDestination(for: Trip.self) { trip in
                TripDetailView(trip: trip)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showingSettings = true
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingExport = true
                    } label: {
                        Label("Export", systemImage: "square.and.arrow.up")
                    }
                    .disabled(trips.isEmpty)
                }
            }
            .confirmationDialog("Finish this trip here?", isPresented: $confirmingFinish, titleVisibility: .visible) {
                Button("Finish Trip") { appSession.finishCurrentTrip() }
            } message: {
                Text("The trip ends at your current location. Driving on starts a new trip.")
            }
            .sheet(isPresented: $showingExport) {
                ExportView(trips: trips)
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView()
            }
            .overlay {
                if trips.isEmpty {
                    ContentUnavailableView(
                        "No Trips Yet",
                        systemImage: "car",
                        description: Text("Drives you take will show up here automatically.")
                    )
                }
            }
        }
    }

    private func delete(_ trips: [Trip]) {
        for trip in trips where !trip.isInProgress {
            trip.markDeleted()
        }
        // Save now so the deletion syncs promptly instead of waiting for autosave.
        try? modelContext.save()
    }

    private struct MonthSection {
        let key: DateComponents
        let title: String
        let trips: [Trip]
    }

    private var monthSections: [MonthSection] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: trips) { Formatters.monthKey(for: $0.startDate, calendar: calendar) }
        return grouped
            .map { key, trips -> MonthSection in
                let date = calendar.date(from: key) ?? Date()
                return MonthSection(
                    key: key,
                    title: Formatters.monthTitle.string(from: date),
                    trips: trips.sorted { $0.startDate > $1.startDate }
                )
            }
            .sorted { lhs, rhs in
                let lhsDate = calendar.date(from: lhs.key) ?? .distantPast
                let rhsDate = calendar.date(from: rhs.key) ?? .distantPast
                return lhsDate > rhsDate
            }
    }
}

#Preview {
    let container = try! ModelContainer(
        for: Trip.self, RoutePoint.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
    PreviewData.insertTrips(into: container.mainContext)
    return TripListView()
        .modelContainer(container)
        .environment(TripSyncService(container: container, client: nil))
        .environment(AppSession.preview())
}
