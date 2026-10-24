import CoreLocation
import Foundation
import SwiftData

/// A named place that decides how trips to or from it are classified.
struct SavedPlace: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var latitude: Double
    var longitude: Double
    var radiusMeters: Double = 150
    var classification: TripClassification

    func contains(_ coordinate: CLLocationCoordinate2D) -> Bool {
        CLLocation(latitude: latitude, longitude: longitude)
            .distance(from: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)) <= radiusMeters
    }
}

/// Rules that classify a finished trip automatically, so most drives need no swipe. Stored on the
/// device only.
struct ClassificationRules: Codable, Equatable {
    var places: [SavedPlace] = []
    var workHoursEnabled = false
    /// `Calendar` weekday numbers (1 = Sunday ... 7 = Saturday).
    var workDays: Set<Int> = [2, 3, 4, 5, 6]
    var workStartMinutes = 9 * 60
    var workEndMinutes = 17 * 60

    static let storageKey = "settings.classificationRules"

    var isEmpty: Bool { places.isEmpty && !workHoursEnabled }

    /// The classification the rules give a trip, or nil to leave it for the user. A saved place at
    /// the destination wins, then one at the start; otherwise work hours decide (a drive that
    /// starts inside them is Business, one outside is Personal).
    func classification(
        start: CLLocationCoordinate2D, end: CLLocationCoordinate2D, startDate: Date, calendar: Calendar = .current
    ) -> TripClassification? {
        if let place = places.first(where: { $0.contains(end) }) { return place.classification }
        if let place = places.first(where: { $0.contains(start) }) { return place.classification }
        guard workHoursEnabled else { return nil }
        let weekday = calendar.component(.weekday, from: startDate)
        let comps = calendar.dateComponents([.hour, .minute], from: startDate)
        let minutes = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
        let inside = workDays.contains(weekday) && minutes >= workStartMinutes && minutes < workEndMinutes
        return inside ? .business : .personal
    }

    func classification(for trip: Trip, calendar: Calendar = .current) -> TripClassification? {
        classification(start: trip.startCoordinate, end: trip.endCoordinate, startDate: trip.startDate, calendar: calendar)
    }

    /// Classifies the trip unless the user already chose. Returns whether it changed.
    @discardableResult
    func apply(to trip: Trip, calendar: Calendar = .current) -> Bool {
        guard !trip.isManuallyClassified, let result = classification(for: trip, calendar: calendar) else { return false }
        return assign(result, to: trip)
    }

    /// Classifies the trip the way the person classified this route before (`RouteMemory`); a route
    /// they never classified falls back to saved places, then work hours; a route they classified
    /// both ways is left for them to decide. Never changes a trip they classified. Returns whether it changed.
    @discardableResult
    func apply(to trip: Trip, learningFrom history: [Trip], calendar: Calendar = .current) -> Bool {
        guard !trip.isManuallyClassified else { return false }
        switch RouteMemory.verdict(for: trip, among: history) {
        case .classification(let learned): return assign(learned, to: trip)
        case .ambiguous: return false
        case .noHistory: return apply(to: trip, calendar: calendar)
        }
    }

    private func assign(_ result: TripClassification, to trip: Trip) -> Bool {
        guard result != trip.classification else { return false }
        // Set the raw value: the `classification` setter would mark it as chosen by the user.
        trip.classificationRaw = result.rawValue
        trip.revision += 1
        return true
    }

    static func load(from defaults: UserDefaults = .standard) -> ClassificationRules {
        guard let data = defaults.data(forKey: storageKey),
              let rules = try? JSONDecoder().decode(ClassificationRules.self, from: data) else { return ClassificationRules() }
        return rules
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(try? JSONEncoder().encode(self), forKey: Self.storageKey)
    }
}

/// What the app has learned from trips the person classified themselves: a trip on a route they
/// have classified before (about the same start and the same end, in either direction) gets the
/// same classification. Nothing is guessed for a route they have never classified, and it stays on
/// the device.
enum RouteMemory {
    /// How close two starts, and two ends, must be to count as the same place. The same radius a
    /// saved place uses: GPS and address lookups vary by a few meters.
    static let matchRadiusMeters = 150.0

    enum Verdict: Equatable {
        /// The person has never classified a trip on this route.
        case noHistory
        /// They classified it both ways before, so the app leaves the choice to them.
        case ambiguous
        case classification(TripClassification)
    }

    /// The classification the person's own earlier trips give `trip`. Only trips they classified
    /// themselves count (a label the app set automatically is never history), and deleted trips
    /// don't.
    static func verdict(for trip: Trip, among history: [Trip]) -> Verdict {
        let labels = Set(history.compactMap { earlier -> TripClassification? in
            guard earlier.id != trip.id, earlier.isManuallyClassified, !earlier.isDeleted, !earlier.isInProgress,
                  earlier.classification != .unclassified, sameRoute(earlier, trip) else { return nil }
            return earlier.classification
        })
        switch labels.count {
        case 0: return .noHistory
        case 1: return .classification(labels.first!)
        default: return .ambiguous
        }
    }

    /// The person's classified trips, newest first, for `verdict`. Bounded so a long history stays quick.
    static func history(in context: ModelContext, limit: Int = 2_000) -> [Trip] {
        var descriptor = FetchDescriptor<Trip>(
            predicate: #Predicate {
                $0.isManuallyClassified && $0.deletedAt == nil && !$0.isInProgress && $0.classificationRaw != "unclassified"
            },
            sortBy: [SortDescriptor(\.endDate, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return (try? context.fetch(descriptor)) ?? []
    }

    static func sameRoute(_ a: Trip, _ b: Trip) -> Bool {
        (near(a.startCoordinate, b.startCoordinate) && near(a.endCoordinate, b.endCoordinate))
            || (near(a.startCoordinate, b.endCoordinate) && near(a.endCoordinate, b.startCoordinate))
    }

    private static func near(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Bool {
        CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude)) <= matchRadiusMeters
    }
}
