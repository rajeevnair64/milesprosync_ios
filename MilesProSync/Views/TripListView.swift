import SwiftData
import SwiftUI

struct TripListView: View {
    @Query(filter: #Predicate<Trip> { $0.deletedAt == nil }, sort: \Trip.startDate, order: .reverse)
    private var trips: [Trip]
    @Environment(\.modelContext) private var modelContext
    @State private var showingExport = false
    @State private var showingSettings = false
    @State private var showingAddTrip = false
    @State private var confirmingFinish = false
    @Environment(AppSession.self) private var appSession
    @Environment(SubscriptionManager.self) private var subscriptions: SubscriptionManager?

    var body: some View {
        NavigationStack {
            List {
                if !trips.isEmpty {
                    Section {
                        monthlySummary
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                    }
                }
                if subscriptions?.state == .expired {
                    Section {
                        NavigationLink {
                            SubscriptionView()
                        } label: {
                            Label("Your free period has ended. Subscribe to keep recording drives.", systemImage: "exclamationmark.circle")
                        }
                    }
                }
                ForEach(monthSections, id: \.key) { section in
                    Section(section.title) {
                        ForEach(section.trips) { trip in
                            NavigationLink(value: trip) {
                                TripRowView(trip: trip)
                            }
                            // A trip still being recorded can't be deleted until it finishes.
                            .deleteDisabled(trip.isInProgress)
                            // Soft pale yellow highlights the live recording.
                            .listRowBackground(
                                trip.isInProgress
                                    ? Color(red: 1.0, green: 0.93, blue: 0.55).opacity(0.55)
                                    : nil
                            )
                            .swipeActions(edge: .leading) {
                                if trip.isInProgress {
                                    Button {
                                        confirmingFinish = true
                                    } label: {
                                        Label("Finish", systemImage: "flag.checkered")
                                    }
                                    .tint(AppTheme.teal)
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
            .brandedBackground()
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
                        showingAddTrip = true
                    } label: {
                        Label("Add Trip", systemImage: "plus")
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
            .sheet(isPresented: $showingAddTrip) {
                ManualTripView()
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView()
            }
            .overlay {
                if trips.isEmpty {
                    ContentUnavailableView {
                        Label("Your next drive starts here", systemImage: "car.side.hill.up.fill")
                            .foregroundStyle(AppTheme.blue)
                    } description: {
                        Text("Trips appear automatically as you drive. You can also add one yourself.")
                    } actions: {
                        Button("Add Your First Trip", systemImage: "plus") { showingAddTrip = true }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
        }
    }

    private var monthlySummary: some View {
        let calendar = Calendar.current
        let completed = trips.filter {
            !$0.isInProgress && calendar.isDate($0.startDate, equalTo: .now, toGranularity: .month)
        }
        return VStack(alignment: .leading, spacing: 12) {
            Label("THIS MONTH", systemImage: "road.lanes")
                .font(.caption.weight(.semibold))
            Text(Formatters.miles(completed.reduce(0) { $0 + $1.distanceMiles }))
                .font(.largeTitle.bold().monospacedDigit())
            Text("\(completed.count) completed trips")
                .font(.subheadline)
            if trips.contains(where: \.isInProgress) {
                Label("Recording your drive", systemImage: "record.circle")
                    .font(.subheadline.weight(.semibold))
            }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(AppTheme.summaryGradient, in: RoundedRectangle(cornerRadius: 20))
        .accessibilityElement(children: .combine)
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
