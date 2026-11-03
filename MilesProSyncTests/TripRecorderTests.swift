import CoreLocation
import Foundation
import SwiftData
import Testing
@testable import MilesProSync

/// The recorder's normal trip lifecycle, as DriveDetectionService drives it on every drive.
struct TripRecorderTests {
    private let container: ModelContainer
    private let recorder: TripRecorder
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    init() throws {
        container = try ModelContainer(
            for: Trip.self, RoutePoint.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        recorder = TripRecorder(modelContainer: container)
    }

    private func fix(_ seconds: TimeInterval, metersNorth: Double) -> CLLocation {
        CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 37 + metersNorth / 111_000, longitude: -122),
            altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5, course: 0,
            speed: 15, timestamp: t0.addingTimeInterval(seconds)
        )
    }

    @Test func beginAppendAndFinalizeRecordsTheDrive() async throws {
        let tripID = await recorder.beginTrip(at: fix(0, metersNorth: 0))
        for second in stride(from: 10.0, through: 100, by: 10) {
            await recorder.appendPoint(fix(second, metersNorth: second * 16.09344), to: tripID)
        }
        // Too close in time and space to the previous point: skipped.
        await recorder.appendPoint(fix(101, metersNorth: 100 * 16.09344 + 2), to: tripID)

        let endpoints = try #require(await recorder.finalizeTrip(tripID, endLocation: fix(160, metersNorth: 1609.344), endedAt: t0.addingTimeInterval(100)))

        let trip = try #require(try ModelContext(container).fetch(FetchDescriptor<Trip>()).first)
        #expect(!trip.isInProgress)
        #expect(trip.route.count == 11)
        #expect(abs(trip.distanceMiles - 1.0) < 0.01) // 10 × 0.1 mi
        #expect(trip.startDate == t0)
        #expect(trip.endDate == t0.addingTimeInterval(100))
        #expect(endpoints.tripID == tripID)
    }

    private func drive(from start: Double, to end: Double, at seconds: TimeInterval) async throws -> Trip {
        let id = await recorder.beginTrip(at: fix(seconds, metersNorth: start))
        await recorder.appendPoint(fix(seconds + 60, metersNorth: (start + end) / 2), to: id)
        await recorder.finalizeTrip(id, endLocation: fix(seconds + 120, metersNorth: end), endedAt: t0.addingTimeInterval(seconds + 120))
        return try #require(try ModelContext(container).fetch(FetchDescriptor<Trip>()).first { $0.startDate == t0.addingTimeInterval(seconds) })
    }

    @Test func repeatRouteTakesTheLastChosenClassification() async throws {
        let first = try await drive(from: 0, to: 1609, at: 0)
        let context = ModelContext(container)
        let stored = try #require(try context.fetch(FetchDescriptor<Trip>()).first { $0.id == first.id })
        stored.classification = .business
        try context.save()

        let second = try await drive(from: 20, to: 1620, at: 10_000)
        #expect(second.classification == .business)
        #expect(!second.isManuallyClassified)

        let other = try await drive(from: 0, to: 4000, at: 20_000)
        #expect(other.classification == .unclassified)
    }
}
