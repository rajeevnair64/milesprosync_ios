import CoreLocation
import Foundation

/// The parts of a reverse-geocoding result an address is built from.
struct AddressParts: Equatable, Sendable {
    var name: String?
    var subThoroughfare: String?
    var thoroughfare: String?
    var locality: String?
    var administrativeArea: String?
    var postalCode: String?

    init(
        name: String? = nil, subThoroughfare: String? = nil, thoroughfare: String? = nil,
        locality: String? = nil, administrativeArea: String? = nil, postalCode: String? = nil
    ) {
        self.name = name
        self.subThoroughfare = subThoroughfare
        self.thoroughfare = thoroughfare
        self.locality = locality
        self.administrativeArea = administrativeArea
        self.postalCode = postalCode
    }

    init(_ placemark: CLPlacemark) {
        self.init(
            name: placemark.name, subThoroughfare: placemark.subThoroughfare,
            thoroughfare: placemark.thoroughfare, locality: placemark.locality,
            administrativeArea: placemark.administrativeArea, postalCode: placemark.postalCode
        )
    }

    var hasHouseNumber: Bool {
        subThoroughfare != nil && thoroughfare != nil
    }

    /// "123 Main St, Austin, TX 78701". Without a house number, a place name (a business, a
    /// landmark) leads when there is one, then the street.
    var formatted: String {
        var street: [String] = []
        if let subThoroughfare, let thoroughfare {
            street.append("\(subThoroughfare) \(thoroughfare)")
        } else {
            if let name, name != thoroughfare, name != locality, name != administrativeArea {
                street.append(name)
            }
            if let thoroughfare { street.append(thoroughfare) }
        }

        var parts = street
        if let locality { parts.append(locality) }
        let region = [administrativeArea, postalCode].compactMap { $0 }.joined(separator: " ")
        if !region.isEmpty { parts.append(region) }
        return parts.isEmpty ? "Unknown location" : parts.joined(separator: ", ")
    }
}

/// One reverse-geocoding result with where the system placed it.
struct AddressCandidate: Sendable {
    let parts: AddressParts
    let location: CLLocation?
}

/// Wraps CLGeocoder with a simple in-memory cache, since reverse geocoding is rate-limited
/// and trip start/end coordinates repeat often (home, work, regular stops).
actor GeocodingService {
    /// Apple allows about 50 reverse-geocoding requests a minute; spacing real lookups by this much
    /// keeps a launch that fills in many trips' addresses (each can take several lookups) under it.
    static let systemLookupInterval: Duration = .milliseconds(1300)
    static let shared = GeocodingService(minimumInterval: systemLookupInterval)

    typealias Lookup = @Sendable (CLLocation) async -> AddressCandidate?

    private var cache: [String: String] = [:]
    private let lookup: Lookup
    /// Least time between two lookups; `.zero` (the default, for tests) means no spacing.
    private let minimumInterval: Duration
    /// When the latest lookup was (or is) due to start. Reserved before waiting, so lookups that
    /// interleave at an `await` still keep their spacing.
    private var nextLookupAt: ContinuousClock.Instant?

    /// Distances (meters) at which neighbouring points are tried when the exact point has no house
    /// number, nearest ring first.
    static let probeRadii: [CLLocationDistance] = [25, 60]
    private static let probeBearings: [Double] = [0, 90, 180, 270]

    /// After this many probes in a row find nothing, the neighbours aren't tried further: the
    /// geocoder is rate-limiting or offline, and more requests would only make it worse.
    private static let probeFailureLimit = 3

    init(lookup: @escaping Lookup = GeocodingService.systemLookup, minimumInterval: Duration = .zero) {
        self.lookup = lookup
        self.minimumInterval = minimumInterval
    }

    /// One lookup, started no sooner than `minimumInterval` after the previous one.
    private func pacedLookup(_ location: CLLocation) async -> AddressCandidate? {
        if minimumInterval > .zero {
            let now = ContinuousClock.now
            let start = max(now, nextLookupAt ?? now)
            nextLookupAt = start + minimumInterval
            if start > now { try? await Task.sleep(until: start, clock: .continuous) }
        }
        return await lookup(location)
    }

    /// The full street address at the point; when the point itself has no house number, the
    /// nearest address that does. nil only when nothing could be looked up.
    func reverseGeocode(latitude: Double, longitude: Double) async -> String? {
        let key = cacheKey(latitude: latitude, longitude: longitude)
        if let cached = cache[key] { return cached }

        let origin = CLLocation(latitude: latitude, longitude: longitude)
        guard let exact = await pacedLookup(origin) else { return nil }

        var best = exact.parts
        if !exact.parts.hasHouseNumber, let nearest = await nearestNumberedAddress(to: origin) {
            best = nearest
            // Keep the locality the exact lookup found if the neighbour lacks one.
            best.locality = best.locality ?? exact.parts.locality
            best.administrativeArea = best.administrativeArea ?? exact.parts.administrativeArea
            best.postalCode = best.postalCode ?? exact.parts.postalCode
        }

        let address = best.formatted
        cache[key] = address
        return address
    }

    /// Looks up points around `origin`, ring by ring, and returns the closest result that has a
    /// house number. Sequential on purpose: reverse geocoding is rate-limited.
    private func nearestNumberedAddress(to origin: CLLocation) async -> AddressParts? {
        var failuresInARow = 0
        for radius in Self.probeRadii {
            var best: (parts: AddressParts, distance: CLLocationDistance)?
            for bearing in Self.probeBearings {
                let probe = Self.offset(origin.coordinate, meters: radius, bearingDegrees: bearing)
                guard let candidate = await pacedLookup(CLLocation(latitude: probe.latitude, longitude: probe.longitude)) else {
                    failuresInARow += 1
                    if failuresInARow >= Self.probeFailureLimit { return nil }
                    continue
                }
                failuresInARow = 0
                guard candidate.parts.hasHouseNumber else { continue }
                let distance = candidate.location?.distance(from: origin) ?? radius
                if best == nil || distance < best!.distance {
                    best = (candidate.parts, distance)
                }
            }
            if let best { return best.parts }
        }
        return nil
    }

    static func offset(_ coordinate: CLLocationCoordinate2D, meters: Double, bearingDegrees: Double) -> CLLocationCoordinate2D {
        let bearing = bearingDegrees * .pi / 180
        let latitudeMeters = 111_320.0
        let dLat = meters * cos(bearing) / latitudeMeters
        let dLon = meters * sin(bearing) / (latitudeMeters * max(cos(coordinate.latitude * .pi / 180), 0.01))
        return CLLocationCoordinate2D(latitude: coordinate.latitude + dLat, longitude: coordinate.longitude + dLon)
    }

    @Sendable
    static func systemLookup(_ location: CLLocation) async -> AddressCandidate? {
        // A CLGeocoder handles one request at a time, and the actor can interleave calls at the
        // await below, so each lookup gets its own geocoder.
        let geocoder = CLGeocoder()
        guard let placemarks = try? await geocoder.reverseGeocodeLocation(location),
              let placemark = placemarks.first else {
            return nil
        }
        return AddressCandidate(parts: AddressParts(placemark), location: placemark.location)
    }

    /// Forward geocoding: the coordinate for a typed address, or nil when it can't be found.
    static func coordinate(for address: String) async -> CLLocationCoordinate2D? {
        let geocoder = CLGeocoder()
        guard let placemark = try? await geocoder.geocodeAddressString(address).first,
              let location = placemark.location else { return nil }
        return location.coordinate
    }

    private func cacheKey(latitude: Double, longitude: Double) -> String {
        // Round to ~11m precision so nearby points (e.g. two points outside the same
        // building) share a cache entry.
        String(format: "%.4f,%.4f", latitude, longitude)
    }
}
