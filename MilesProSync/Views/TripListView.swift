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
    @State private var showingLocationHelp = false
    @State private var showingReview = false
    @State private var showingPlans = false
    @AppStorage(AppSettings.Key.mileageRate) private var mileageRate = AppSettings.defaultMileageRate
    @AppStorage(AppSettings.Key.countryCode) private var countryCode = AppSettings.defaultCountryCode
    @AppStorage(AppSettings.Key.rateMode) private var rateMode = AppSettings.RateMode.irs.rawValue
    @AppStorage(AppSettings.Key.favrFixedMonthly) private var favrFixedMonthly = 0.0
    @AppStorage(AppSettings.Key.favrPerMile) private var favrPerMile = 0.0
    @AppStorage(AppSettings.Key.favrMinMonthlyMiles) private var favrMinMonthlyMiles = 0.0
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
                                if !trip.isInProgress {
                                    Button { classify(trip, as: .business) } label: {
                                        Label("Business", systemImage: "briefcase")
                                    }
                                    .tint(TripClassification.business.accentColor)
                                    Button { classify(trip, as: .personal) } label: {
                                        Label("Personal", systemImage: "person")
                                    }
                                    .tint(TripClassification.personal.accentColor)
                                }
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
            .sheet(isPresented: $showingLocationHelp) {
                LocationAccessView()
            }
            .sheet(isPresented: $showingPlans) {
                NavigationStack { SubscriptionView() }
            }
            .sheet(isPresented: $showingReview) {
                ReviewTripsView(trips: needingReview)
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

    private var status: RecordingStatus {
        RecordingStatus.resolve(
            authorization: appSession.current?.driveDetection.authorizationStatus ?? .notDetermined,
            planAllowsRecording: subscriptions?.state.allowsRecording ?? true,
            isRecording: trips.contains(where: \.isInProgress)
        )
    }

    /// Finished trips that still need a Business or Personal choice.
    private var needingReview: [Trip] {
        trips.filter { !$0.isInProgress && $0.classification == .unclassified }
    }

    private var rate: ReimbursementRate {
        AppSettings.reimbursementRate(
            mode: AppSettings.RateMode(rawValue: rateMode) ?? .irs,
            customPerMile: mileageRate,
            favrFixedMonthly: favrFixedMonthly, favrPerMile: favrPerMile, favrMinMonthlyMiles: favrMinMonthlyMiles,
            countryCode: countryCode
        )
    }

    private func statusAction() {
        guard case .actionNeeded(let reason) = status else { return }
        switch reason {
        case .planExpired: showingPlans = true
        default: showingLocationHelp = true
        }
    }

    private var monthlySummary: some View {
        let calendar = Calendar.current
        let business = trips.filter {
            !$0.isInProgress && $0.classification == .business
                && calendar.isDate($0.startDate, equalTo: .now, toGranularity: .month)
        }
        let miles = ExportFetcher.totalMiles(business)
        let estimate = Reimbursement.total(business, rate: rate)
        let reviewCount = needingReview.count
        return VStack(alignment: .leading, spacing: 16) {
            statusHeader
            VStack(alignment: .leading, spacing: 4) {
                Text("BUSINESS THIS MONTH")
                    .font(.caption.weight(.semibold))
                Text(Formatters.miles(miles))
                    .font(.largeTitle.bold().monospacedDigit())
                Text("Estimated reimbursement \(rate.format(estimate))")
                    .font(.subheadline.monospacedDigit())
                Text("An estimate at \(rate.label); the amount in your exports is final.")
                    .font(.caption2)
                    .opacity(0.8)
            }
            if reviewCount > 0 {
                Button { showingReview = true } label: {
                    HStack {
                        Label("\(reviewCount) \(reviewCount == 1 ? "trip needs" : "trips need") review",
                              systemImage: "tray.full")
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                    }
                    .font(.subheadline.weight(.semibold))
                    .padding(10)
                    .background(.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(AppTheme.summaryGradient, in: RoundedRectangle(cornerRadius: 20))
    }

    private var statusHeader: some View {
        let status = status
        let content = HStack(alignment: .top, spacing: 10) {
            Image(systemName: status.systemImage)
                .font(.title3)
                .foregroundStyle(statusTint(status))
            VStack(alignment: .leading, spacing: 2) {
                Text(status.title).font(.headline)
                Text(status.explanation).font(.caption)
            }
            Spacer(minLength: 0)
            if case .actionNeeded = status {
                Image(systemName: "chevron.right").font(.caption.weight(.semibold))
            }
        }
        .padding(10)
        .background(.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
        return Group {
            if case .actionNeeded = status {
                Button(action: statusAction) { content }.buttonStyle(.plain)
            } else {
                content
            }
        }
    }

    private func statusTint(_ status: RecordingStatus) -> Color {
        switch status {
        case .ready: .white
        case .recording: AppTheme.gold
        case .actionNeeded: .orange
        }
    }

    private func classify(_ trip: Trip, as classification: TripClassification) {
        trip.classification = classification
        try? modelContext.save()
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
