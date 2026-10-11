import CoreLocation
import Foundation

/// The fields of the "Add Trip" form and the rules a manually entered trip must satisfy.
struct ManualTripDraft {
    var startDate: Date
    var endDate: Date
    var fromAddress = ""
    var toAddress = ""
    var distanceText = ""
    var classification: TripClassification = .business
    var notes = ""
    var purpose: String?

    /// A draft that edits an existing trip.
    init(trip: Trip) {
        startDate = trip.startDate
        endDate = trip.endDate
        fromAddress = trip.startAddress ?? ""
        toAddress = trip.endAddress ?? ""
        distanceText = AppSettings.formatRate(trip.distanceMiles)
        classification = trip.classification
        notes = trip.notes ?? ""
        purpose = trip.purpose
    }

    init(now: Date = .now) {
        endDate = now
        startDate = now.addingTimeInterval(-30 * 60)
    }

    enum Problem: Equatable {
        case missingFrom
        case missingTo
        case invalidDistance
        case endBeforeStart
        case inFuture

        var message: String {
            switch self {
            case .missingFrom: "Enter where the trip started."
            case .missingTo: "Enter where the trip ended."
            case .invalidDistance: "Enter a distance greater than zero."
            case .endBeforeStart: "The trip can't end before it starts."
            case .inFuture: "The trip can't be in the future."
            }
        }
    }

    /// Distance in miles, or nil when the text isn't a positive number.
    var distanceMiles: Double? {
        guard let value = AppSettings.parseRate(distanceText), value > 0 else { return nil }
        return value
    }

    func problems(now: Date = .now) -> [Problem] {
        var found: [Problem] = []
        if fromAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { found.append(.missingFrom) }
        if toAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { found.append(.missingTo) }
        if distanceMiles == nil { found.append(.invalidDistance) }
        if endDate < startDate { found.append(.endBeforeStart) }
        if endDate > now { found.append(.inFuture) }
        return found
    }

    var isValid: Bool { problems().isEmpty }

    /// The finished trip, with coordinates the caller looked up for the two addresses. It has no
    /// recorded route, so the distance is the entered one.
    func makeTrip(start: CLLocationCoordinate2D, end: CLLocationCoordinate2D) -> Trip? {
        guard let distanceMiles else { return nil }
        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        return Trip(
            startDate: startDate,
            endDate: endDate,
            distanceMiles: distanceMiles,
            startLatitude: start.latitude,
            startLongitude: start.longitude,
            endLatitude: end.latitude,
            endLongitude: end.longitude,
            startAddress: fromAddress.trimmingCharacters(in: .whitespacesAndNewlines),
            endAddress: toAddress.trimmingCharacters(in: .whitespacesAndNewlines),
            classification: classification,
            isManuallyClassified: classification != .unclassified,
            notes: trimmedNotes.isEmpty ? nil : trimmedNotes
        ).withPurpose(purpose)
    }

    /// Writes the draft into `trip`, marking it for upload. A nil coordinate keeps the trip's
    /// existing one (its address wasn't changed).
    func apply(to trip: Trip, start: CLLocationCoordinate2D?, end: CLLocationCoordinate2D?) {
        guard let distanceMiles else { return }
        trip.startDate = startDate
        trip.endDate = endDate
        trip.distanceMiles = distanceMiles
        trip.startAddress = fromAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        trip.endAddress = toAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        if let start {
            trip.startLatitude = start.latitude
            trip.startLongitude = start.longitude
        }
        if let end {
            trip.endLatitude = end.latitude
            trip.endLongitude = end.longitude
        }
        if trip.classification != classification { trip.classification = classification }
        trip.setNotes(notes)
        trip.purpose = purpose
        trip.revision += 1
    }
}

private extension Trip {
    func withPurpose(_ purpose: String?) -> Trip {
        self.purpose = purpose
        return self
    }
}
