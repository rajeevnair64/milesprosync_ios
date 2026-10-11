import CoreLocation
import Foundation
import SwiftData

enum PreviewData {
    /// A short breadcrumb route roughly following surface streets so the map preview has a
    /// realistic-looking polyline instead of a single straight line.
    private static func route(from start: CLLocationCoordinate2D, to end: CLLocationCoordinate2D, steps: Int) -> [CLLocationCoordinate2D] {
        (0...steps).map { step in
            let t = Double(step) / Double(steps)
            let jitter = sin(t * .pi * 3) * 0.0015
            return CLLocationCoordinate2D(
                latitude: start.latitude + (end.latitude - start.latitude) * t + jitter,
                longitude: start.longitude + (end.longitude - start.longitude) * t
            )
        }
    }

    /// Inserts sample trips (with routes) into `context`, for SwiftUI previews.
    static func insertTrips(into context: ModelContext) {
        let calendar = Calendar.current
        let now = Date()

        func trip(
            daysAgo: Int,
            hour: Int,
            durationMinutes: Int,
            start: CLLocationCoordinate2D,
            end: CLLocationCoordinate2D,
            startAddress: String,
            endAddress: String,
            classification: TripClassification,
            manual: Bool
        ) -> Trip {
            let startDate = calendar.date(byAdding: .hour, value: hour, to: calendar.date(byAdding: .day, value: -daysAgo, to: calendar.startOfDay(for: now))!)!
            let endDate = calendar.date(byAdding: .minute, value: durationMinutes, to: startDate)!
            let coordinates = route(from: start, to: end, steps: 12)
            let distance = MileageCalculator.distanceMiles(for: coordinates)

            let trip = Trip(
                startDate: startDate,
                endDate: endDate,
                distanceMiles: distance,
                startLatitude: start.latitude,
                startLongitude: start.longitude,
                endLatitude: end.latitude,
                endLongitude: end.longitude,
                startAddress: startAddress,
                endAddress: endAddress,
                classification: classification,
                isManuallyClassified: manual
            )
            // Insert before attaching the route; see TripRecorder.beginTrip.
            context.insert(trip)
            trip.route = coordinates.enumerated().map { index, coordinate in
                RoutePoint(
                    latitude: coordinate.latitude,
                    longitude: coordinate.longitude,
                    timestamp: startDate.addingTimeInterval(Double(index) * Double(durationMinutes * 60) / 12.0)
                )
            }
            return trip
        }

        let home = CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194)
        let office = CLLocationCoordinate2D(latitude: 37.7897, longitude: -122.4000)
        let client = CLLocationCoordinate2D(latitude: 37.8044, longitude: -122.2712)
        let store = CLLocationCoordinate2D(latitude: 37.7599, longitude: -122.4148)

        _ = [
            trip(daysAgo: 0, hour: 8, durationMinutes: 22, start: home, end: office, startAddress: "123 Elm St, San Francisco, CA", endAddress: "500 Market St, San Francisco, CA", classification: .business, manual: false),
            trip(daysAgo: 0, hour: 17, durationMinutes: 25, start: office, end: home, startAddress: "500 Market St, San Francisco, CA", endAddress: "123 Elm St, San Francisco, CA", classification: .business, manual: false),
            trip(daysAgo: 2, hour: 12, durationMinutes: 15, start: home, end: store, startAddress: "123 Elm St, San Francisco, CA", endAddress: "899 Valencia St, San Francisco, CA", classification: .personal, manual: true),
            trip(daysAgo: 5, hour: 9, durationMinutes: 40, start: office, end: client, startAddress: "500 Market St, San Francisco, CA", endAddress: "1200 Broadway, Oakland, CA", classification: .business, manual: false),
            trip(daysAgo: 33, hour: 10, durationMinutes: 18, start: home, end: store, startAddress: "123 Elm St, San Francisco, CA", endAddress: "899 Valencia St, San Francisco, CA", classification: .unclassified, manual: false),
        ]
    }
}

/// Account store for SwiftUI previews; nothing is saved.
struct PreviewAccountStore: AccountStore {
    func load() -> DeviceAccount? { DeviceAccount(storageKey: "preview", appleUserID: nil, email: nil) }
    func save(_ account: DeviceAccount?) {}
}

extension AppSession {
    /// A session for SwiftUI previews, stored in a scratch directory with no services running.
    static func preview() -> AppSession {
        AppSession(
            accountStore: PreviewAccountStore(), apiConfig: nil,
            storageRoot: FileManager.default.temporaryDirectory.appending(path: "Previews"), startsServices: false
        )
    }
}
