import CoreLocation
import Foundation
import SwiftData

@Model
final class Trip {
    @Attribute(.unique) var id: UUID
    var startDate: Date
    var endDate: Date
    var distanceMiles: Double
    var startLatitude: Double
    var startLongitude: Double
    var endLatitude: Double
    var endLongitude: Double
    var startAddress: String?
    var endAddress: String?
    var classificationRaw: String
    var isManuallyClassified: Bool
    var notes: String?
    /// True while a trip is actively being recorded (created by `TripRecorder.beginTrip`,
    /// cleared by `finalizeTrip`). Lets the app find and resume an unfinished trip after a
    /// background relaunch instead of relying on a date-equality heuristic.
    var isInProgress: Bool
    /// Bumped on every change worth uploading; the trip is pending cloud sync while this differs
    /// from `uploadedRevision`. The defaults make trips from before sync existed pending, so they
    /// upload after the first sign-in.
    var revision: Int = 1
    var uploadedRevision: Int = 0
    /// Set when the user deletes the trip. Deleted trips are hidden from the list and exports but
    /// kept on the device and in the cloud as a record; see `markDeleted()`.
    var deletedAt: Date? = nil

    @Relationship(deleteRule: .cascade, inverse: \RoutePoint.trip)
    var route: [RoutePoint] = []

    init(
        id: UUID = UUID(),
        startDate: Date,
        endDate: Date,
        distanceMiles: Double,
        startLatitude: Double,
        startLongitude: Double,
        endLatitude: Double,
        endLongitude: Double,
        startAddress: String? = nil,
        endAddress: String? = nil,
        classification: TripClassification = .unclassified,
        isManuallyClassified: Bool = false,
        notes: String? = nil,
        isInProgress: Bool = false
    ) {
        self.id = id
        self.startDate = startDate
        self.endDate = endDate
        self.distanceMiles = distanceMiles
        self.startLatitude = startLatitude
        self.startLongitude = startLongitude
        self.endLatitude = endLatitude
        self.endLongitude = endLongitude
        self.startAddress = startAddress
        self.endAddress = endAddress
        self.classificationRaw = classification.rawValue
        self.isManuallyClassified = isManuallyClassified
        self.notes = notes
        self.isInProgress = isInProgress
    }

    var classification: TripClassification {
        get { TripClassification(rawValue: classificationRaw) ?? .unclassified }
        set {
            classificationRaw = newValue.rawValue
            isManuallyClassified = true
            revision += 1
        }
    }

    /// Sets the notes (blank clears them) and marks the trip for upload.
    func setNotes(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let newValue = trimmed.isEmpty ? nil : text
        guard newValue != notes else { return }
        notes = newValue
        revision += 1
    }

    var isDeleted: Bool { deletedAt != nil }

    /// Final distance once finished; while recording, the distance covered so far (the stored
    /// value is only computed when the trip ends).
    var displayedDistanceMiles: Double {
        isInProgress ? MileageCalculator.distanceMiles(for: route) : distanceMiles
    }

    /// Hides the trip from the user. The record is kept (and the deletion synced) rather than
    /// removed, so the full trip history is retained.
    func markDeleted(at date: Date = .now) {
        guard deletedAt == nil else { return }
        deletedAt = date
        revision += 1
    }

    var startCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: startLatitude, longitude: startLongitude)
    }

    var endCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: endLatitude, longitude: endLongitude)
    }

    var sortedRoute: [RoutePoint] {
        route.sorted { $0.timestamp < $1.timestamp }
    }

    var routeCoordinates: [CLLocationCoordinate2D] {
        sortedRoute.map(\.coordinate)
    }
}
