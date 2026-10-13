import Foundation

/// One GPS fix in a trip's uploaded `route`.
struct RoutePointPayload: Encodable, Equatable, Sendable {
    let latitude: Double
    let longitude: Double
    let recordedAt: Date
    let speedMetersPerSecond: Double?
    let horizontalAccuracyMeters: Double?

    init(point: RoutePoint) {
        latitude = point.latitude
        longitude = point.longitude
        recordedAt = point.timestamp
        speedMetersPerSecond = point.speed
        horizontalAccuracyMeters = point.horizontalAccuracy
    }

    private enum CodingKeys: String, CodingKey {
        case latitude
        case longitude
        case recordedAt = "recorded_at"
        case speedMetersPerSecond = "speed_mps"
        case horizontalAccuracyMeters = "horizontal_accuracy_m"
    }
}

/// A trip as uploaded to the server (`POST /api/v1/trips`, see website/trips/api.py). A plain value snapshot, so
/// it can leave the SwiftData context and cross to the network actor.
struct TripPayload: Encodable, Equatable, Sendable {
    let id: UUID
    let startedAt: Date
    let endedAt: Date
    let distanceMiles: Double
    let startLatitude: Double
    let startLongitude: Double
    let endLatitude: Double
    let endLongitude: Double
    let startAddress: String?
    let endAddress: String?
    let classification: String
    let isManuallyClassified: Bool
    let notes: String?
    let purpose: String?
    let route: [RoutePointPayload]
    let deletedAt: Date?

    init(trip: Trip) {
        id = trip.id
        startedAt = trip.startDate
        endedAt = trip.endDate
        distanceMiles = trip.distanceMiles
        startLatitude = trip.startLatitude
        startLongitude = trip.startLongitude
        endLatitude = trip.endLatitude
        endLongitude = trip.endLongitude
        startAddress = trip.startAddress
        endAddress = trip.endAddress
        classification = trip.classification.rawValue
        isManuallyClassified = trip.isManuallyClassified
        notes = trip.notes
        purpose = trip.purpose
        route = trip.sortedRoute.map(RoutePointPayload.init)
        deletedAt = trip.deletedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case distanceMiles = "distance_miles"
        case startLatitude = "start_latitude"
        case startLongitude = "start_longitude"
        case endLatitude = "end_latitude"
        case endLongitude = "end_longitude"
        case startAddress = "start_address"
        case endAddress = "end_address"
        case classification
        case isManuallyClassified = "is_manually_classified"
        case notes
        case purpose
        case route
        case deletedAt = "deleted_at"
    }

    /// Written by hand so nil values encode as JSON null. The synthesized version omits them, and
    /// an explicit null is what clears a value on the server (e.g. notes the user erased).
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(startedAt, forKey: .startedAt)
        try container.encode(endedAt, forKey: .endedAt)
        try container.encode(distanceMiles, forKey: .distanceMiles)
        try container.encode(startLatitude, forKey: .startLatitude)
        try container.encode(startLongitude, forKey: .startLongitude)
        try container.encode(endLatitude, forKey: .endLatitude)
        try container.encode(endLongitude, forKey: .endLongitude)
        try container.encode(startAddress, forKey: .startAddress)
        try container.encode(endAddress, forKey: .endAddress)
        try container.encode(classification, forKey: .classification)
        try container.encode(isManuallyClassified, forKey: .isManuallyClassified)
        try container.encode(notes, forKey: .notes)
        try container.encode(purpose, forKey: .purpose)
        try container.encode(route, forKey: .route)
        try container.encode(deletedAt, forKey: .deletedAt)
    }
}

/// A trip as the website returns it when restoring an account's trips (`GET /api/v1/trips/restore`,
/// see website/trips/restore_api.py): the upload's fields, without `deleted_at` (deleted trips are
/// never sent back).
struct RestoredTrip: Decodable, Equatable, Sendable {
    struct Point: Decodable, Equatable, Sendable {
        let latitude: Double
        let longitude: Double
        let recordedAt: Date
        let speedMetersPerSecond: Double?
        let horizontalAccuracyMeters: Double?

        private enum CodingKeys: String, CodingKey {
            case latitude
            case longitude
            case recordedAt = "recorded_at"
            case speedMetersPerSecond = "speed_mps"
            case horizontalAccuracyMeters = "horizontal_accuracy_m"
        }
    }

    let id: UUID
    let startedAt: Date
    let endedAt: Date
    let distanceMiles: Double
    let startLatitude: Double
    let startLongitude: Double
    let endLatitude: Double
    let endLongitude: Double
    let startAddress: String?
    let endAddress: String?
    let classification: String
    let isManuallyClassified: Bool
    let notes: String?
    let purpose: String?
    let route: [Point]

    private enum CodingKeys: String, CodingKey {
        case id
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case distanceMiles = "distance_miles"
        case startLatitude = "start_latitude"
        case startLongitude = "start_longitude"
        case endLatitude = "end_latitude"
        case endLongitude = "end_longitude"
        case startAddress = "start_address"
        case endAddress = "end_address"
        case classification
        case isManuallyClassified = "is_manually_classified"
        case notes
        case purpose
        case route
    }

    /// A trip ready to insert: finished, and already in sync with the cloud (it came from there),
    /// so it isn't uploaded again until it is edited.
    func makeTrip() -> Trip {
        let trip = Trip(
            id: id, startDate: startedAt, endDate: endedAt, distanceMiles: distanceMiles,
            startLatitude: startLatitude, startLongitude: startLongitude,
            endLatitude: endLatitude, endLongitude: endLongitude,
            startAddress: startAddress, endAddress: endAddress,
            classification: TripClassification(rawValue: classification) ?? .unclassified,
            isManuallyClassified: isManuallyClassified, notes: notes
        )
        trip.route = route.map {
            RoutePoint(
                latitude: $0.latitude, longitude: $0.longitude, timestamp: $0.recordedAt,
                speed: $0.speedMetersPerSecond, horizontalAccuracy: $0.horizontalAccuracyMeters
            )
        }
        trip.purpose = purpose
        trip.uploadedRevision = trip.revision
        return trip
    }
}

/// One page of `GET /api/v1/trips/restore`. `next` is the cursor for the following page, nil on the last.
struct RestoredTripPage: Decodable, Equatable, Sendable {
    let trips: [RestoredTrip]
    let next: UUID?

    /// The server writes dates as ISO 8601 with a time zone, with or without fractional seconds.
    static func decode(_ data: Data) throws -> RestoredTripPage {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            let plain = Date.ISO8601FormatStyle()
            let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
            if let date = try? fractional.parse(text) { return date }
            if let date = try? plain.parse(text) { return date }
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Not an ISO 8601 date: \(text)")
            )
        }
        return try decoder.decode(RestoredTripPage.self, from: data)
    }
}
