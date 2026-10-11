import CoreLocation
import Foundation

enum MileageCalculator {
    private static let metersPerMile = 1609.344

    /// Sums the great-circle distance between consecutive points and converts to miles.
    static func distanceMiles(for coordinates: [CLLocationCoordinate2D]) -> Double {
        guard coordinates.count > 1 else { return 0 }
        var totalMeters = 0.0
        for i in 1..<coordinates.count {
            let a = CLLocation(latitude: coordinates[i - 1].latitude, longitude: coordinates[i - 1].longitude)
            let b = CLLocation(latitude: coordinates[i].latitude, longitude: coordinates[i].longitude)
            totalMeters += b.distance(from: a)
        }
        return totalMeters / metersPerMile
    }

    static func distanceMiles(for points: [RoutePoint]) -> Double {
        distanceMiles(for: points.sorted { $0.timestamp < $1.timestamp }.map(\.coordinate))
    }
}
