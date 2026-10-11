import CoreLocation
import Foundation
import OSLog
import SwiftData

/// Start and end coordinates of a finished trip, for reverse geocoding.
struct TripEndpoints: Sendable {
    let tripID: PersistentIdentifier
    let start: CLLocationCoordinate2D
    let end: CLLocationCoordinate2D
}

/// What `recoverInProgressTrips` found after a relaunch.
struct TripRecovery: Sendable {
    /// A trip recent enough to keep recording, with the time of its last recorded point.
    var resume: (tripID: PersistentIdentifier, lastActivityAt: Date)?
    /// Trips that were cut off too long ago and have been finished at their last recorded point.
    var finished: [TripEndpoints] = []
}

/// Persists trips-in-progress and completed trips off the main actor, so background location
/// delivery never contends with the UI's main-actor `ModelContext`.
@ModelActor
actor TripRecorder {
    private var lastPersistedPointByTrip: [PersistentIdentifier: (coordinate: CLLocationCoordinate2D, timestamp: Date)] = [:]

    private static let log = Logger(subsystem: "com.aisleweb.MilesProSync", category: "TripRecorder")

    /// A failed save keeps the change in this context, so the next save retries it; the log is the
    /// only trace if it keeps failing.
    private func saveContext() {
        do {
            try modelContext.save()
        } catch {
            Self.log.error("Saving trip data failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private let minPointDistanceMeters = 20.0
    private let minPointInterval: TimeInterval = 5

    func beginTrip(at location: CLLocation) -> PersistentIdentifier {
        let trip = Trip(
            startDate: location.timestamp,
            endDate: location.timestamp,
            distanceMiles: 0,
            startLatitude: location.coordinate.latitude,
            startLongitude: location.coordinate.longitude,
            endLatitude: location.coordinate.latitude,
            endLongitude: location.coordinate.longitude,
            isInProgress: true
        )
        // Insert before attaching the route: SwiftData can crash when a relationship is set on
        // a model that isn't in a context yet.
        modelContext.insert(trip)
        trip.route.append(RoutePoint(location: location))
        saveContext()
        lastPersistedPointByTrip[trip.persistentModelID] = (location.coordinate, location.timestamp)
        return trip.persistentModelID
    }

    func appendPoint(_ location: CLLocation, to tripID: PersistentIdentifier) {
        guard let trip = self[tripID, as: Trip.self] else { return }

        if let last = lastPersistedPointByTrip[tripID] {
            let lastLocation = CLLocation(latitude: last.coordinate.latitude, longitude: last.coordinate.longitude)
            let distance = location.distance(from: lastLocation)
            let elapsed = location.timestamp.timeIntervalSince(last.timestamp)
            guard distance >= minPointDistanceMeters || elapsed >= minPointInterval else { return }
        }

        trip.route.append(RoutePoint(location: location))
        lastPersistedPointByTrip[tripID] = (location.coordinate, location.timestamp)
        saveContext()
    }

    /// Finalizes the trip and returns its endpoints so the caller can kick off reverse
    /// geocoding (a network call, done outside this actor).
    @discardableResult
    func finalizeTrip(_ tripID: PersistentIdentifier, endLocation: CLLocation, endedAt: Date) -> TripEndpoints? {
        guard let trip = self[tripID, as: Trip.self] else { return nil }
        finish(trip, at: endLocation.coordinate, endedAt: endedAt)
        saveContext()
        lastPersistedPointByTrip[tripID] = nil
        return TripEndpoints(tripID: tripID, start: trip.startCoordinate, end: trip.endCoordinate)
    }

    private func finish(_ trip: Trip, at end: CLLocationCoordinate2D, endedAt: Date) {
        trip.endDate = max(endedAt, trip.startDate)
        trip.endLatitude = end.latitude
        trip.endLongitude = end.longitude
        trip.distanceMiles = MileageCalculator.distanceMiles(for: trip.route)
        trip.isInProgress = false
        trip.revision += 1
    }

    /// Stores looked-up addresses. A nil (failed lookup) never overwrites an address already
    /// found, so retrying only fills gaps.
    func setAddresses(startAddress: String?, endAddress: String?, for tripID: PersistentIdentifier) {
        guard let trip = self[tripID, as: Trip.self] else { return }
        var changed = false
        if let startAddress, startAddress != trip.startAddress {
            trip.startAddress = startAddress
            changed = true
        }
        if let endAddress, endAddress != trip.endAddress {
            trip.endAddress = endAddress
            changed = true
        }
        guard changed else { return }
        trip.revision += 1
        saveContext()
    }

    /// Deals with trips left `isInProgress` when the app stopped mid-drive (crash, force-quit, or
    /// termination by iOS). The newest one is resumed if its last point is within `resumeWindow`,
    /// meaning the drive is probably still going. Every other one is finished where recording
    /// stopped: its last saved point and that point's time, not wherever the phone is now.
    func recoverInProgressTrips(now: Date, resumeWindow: TimeInterval) -> TripRecovery {
        let descriptor = FetchDescriptor<Trip>(
            predicate: #Predicate { $0.isInProgress },
            sortBy: [SortDescriptor(\.startDate, order: .reverse)]
        )
        guard let trips = try? modelContext.fetch(descriptor), !trips.isEmpty else { return TripRecovery() }

        var recovery = TripRecovery()
        for (index, trip) in trips.enumerated() {
            let lastPoint = trip.sortedRoute.last
            let lastActivityAt = lastPoint?.timestamp ?? trip.startDate
            if index == 0, now.timeIntervalSince(lastActivityAt) <= resumeWindow {
                recovery.resume = (trip.persistentModelID, lastActivityAt)
                continue
            }
            finish(trip, at: lastPoint?.coordinate ?? trip.startCoordinate, endedAt: lastActivityAt)
            recovery.finished.append(TripEndpoints(
                tripID: trip.persistentModelID, start: trip.startCoordinate, end: trip.endCoordinate
            ))
        }
        saveContext()
        return recovery
    }

    /// Finished trips from the last `window` still missing an address, e.g. because the app was
    /// closed before the lookup ran or the phone was offline. Newest first, at most `limit`, to
    /// stay under the geocoder's rate limit.
    func tripsMissingAddresses(within window: TimeInterval, now: Date, limit: Int) -> [TripEndpoints] {
        let cutoff = now.addingTimeInterval(-window)
        var descriptor = FetchDescriptor<Trip>(
            predicate: #Predicate {
                !$0.isInProgress && $0.endDate > cutoff && ($0.startAddress == nil || $0.endAddress == nil)
            },
            sortBy: [SortDescriptor(\.endDate, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        let trips = (try? modelContext.fetch(descriptor)) ?? []
        return trips.map { TripEndpoints(tripID: $0.persistentModelID, start: $0.startCoordinate, end: $0.endCoordinate) }
    }
}
