import CoreLocation
import Foundation
import SwiftData

@Model
final class RoutePoint {
    var latitude: Double
    var longitude: Double
    var timestamp: Date
    var speed: Double?
    var horizontalAccuracy: Double?
    var trip: Trip?

    init(
        latitude: Double,
        longitude: Double,
        timestamp: Date,
        speed: Double? = nil,
        horizontalAccuracy: Double? = nil
    ) {
        self.latitude = latitude
        self.longitude = longitude
        self.timestamp = timestamp
        self.speed = speed
        self.horizontalAccuracy = horizontalAccuracy
    }

    convenience init(location: CLLocation) {
        self.init(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            timestamp: location.timestamp,
            speed: location.speed >= 0 ? location.speed : nil,
            horizontalAccuracy: location.horizontalAccuracy >= 0 ? location.horizontalAccuracy : nil
        )
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}
