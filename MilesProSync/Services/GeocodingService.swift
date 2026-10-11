import CoreLocation
import Foundation

/// Wraps CLGeocoder with a simple in-memory cache, since reverse geocoding is rate-limited
/// and trip start/end coordinates repeat often (home, work, regular stops).
actor GeocodingService {
    static let shared = GeocodingService()

    private var cache: [String: String] = [:]

    func reverseGeocode(latitude: Double, longitude: Double) async -> String? {
        let key = cacheKey(latitude: latitude, longitude: longitude)
        if let cached = cache[key] { return cached }

        // A CLGeocoder handles one request at a time, and the actor can interleave calls at the
        // await below, so each lookup gets its own geocoder.
        let geocoder = CLGeocoder()
        let location = CLLocation(latitude: latitude, longitude: longitude)
        guard let placemarks = try? await geocoder.reverseGeocodeLocation(location),
              let placemark = placemarks.first else {
            return nil
        }

        let address = format(placemark)
        cache[key] = address
        return address
    }

    private func cacheKey(latitude: Double, longitude: Double) -> String {
        // Round to ~11m precision so nearby points (e.g. two points outside the same
        // building) share a cache entry.
        String(format: "%.4f,%.4f", latitude, longitude)
    }

    private func format(_ placemark: CLPlacemark) -> String {
        var parts: [String] = []
        if let subThoroughfare = placemark.subThoroughfare, let thoroughfare = placemark.thoroughfare {
            parts.append("\(subThoroughfare) \(thoroughfare)")
        } else if let thoroughfare = placemark.thoroughfare {
            parts.append(thoroughfare)
        }
        if let locality = placemark.locality {
            parts.append(locality)
        }
        if let administrativeArea = placemark.administrativeArea {
            parts.append(administrativeArea)
        }
        return parts.isEmpty ? "Unknown location" : parts.joined(separator: ", ")
    }
}
