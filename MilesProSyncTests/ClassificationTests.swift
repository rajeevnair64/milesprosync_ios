import Foundation
import Testing
@testable import MilesProSync

struct ClassificationTests {
    @Test func newTripDefaultsToUnclassified() {
        let trip = Trip(
            startDate: .now, endDate: .now, distanceMiles: 1,
            startLatitude: 0, startLongitude: 0, endLatitude: 0, endLongitude: 0
        )
        #expect(trip.classification == .unclassified)
        #expect(trip.isManuallyClassified == false)
    }

    @Test func settingClassificationMarksManualOverride() {
        let trip = Trip(
            startDate: .now, endDate: .now, distanceMiles: 1,
            startLatitude: 0, startLongitude: 0, endLatitude: 0, endLongitude: 0
        )
        trip.classification = .business
        #expect(trip.classification == .business)
        #expect(trip.isManuallyClassified == true)
    }

    @Test func deletingKeepsRecordAndBumpsRevisionOnce() {
        let trip = Trip(
            startDate: .now, endDate: .now, distanceMiles: 1,
            startLatitude: 0, startLongitude: 0, endLatitude: 0, endLongitude: 0
        )
        let revision = trip.revision
        let deletedAt = Date(timeIntervalSince1970: 100)

        trip.markDeleted(at: deletedAt)
        trip.markDeleted(at: deletedAt.addingTimeInterval(60))

        #expect(trip.isDeleted)
        #expect(trip.deletedAt == deletedAt)
        #expect(trip.revision == revision + 1)
    }

    @Test func overrideCanBeChangedAgain() {
        let trip = Trip(
            startDate: .now, endDate: .now, distanceMiles: 1,
            startLatitude: 0, startLongitude: 0, endLatitude: 0, endLongitude: 0,
            classification: .business, isManuallyClassified: true
        )
        trip.classification = .personal
        #expect(trip.classification == .personal)
        #expect(trip.isManuallyClassified == true)
    }
}
