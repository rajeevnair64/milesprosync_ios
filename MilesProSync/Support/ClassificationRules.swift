import CoreLocation
import Foundation

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
        guard !trip.isManuallyClassified, let result = classification(for: trip, calendar: calendar),
              result != trip.classification else { return false }
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
