import CoreLocation
import Foundation
import Testing
@testable import MilesProSync

struct ManualTripDraftTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func validDraft() -> ManualTripDraft {
        var draft = ManualTripDraft(now: now)
        draft.fromAddress = "1 Main St"
        draft.toAddress = "2 Oak Ave"
        draft.distanceText = "12.5"
        return draft
    }

    @Test func validDraftHasNoProblems() {
        #expect(validDraft().problems(now: now).isEmpty)
    }

    @Test func reportsEachProblem() {
        var draft = ManualTripDraft(now: now)
        #expect(draft.problems(now: now) == [.missingFrom, .missingTo, .invalidDistance])

        draft = validDraft()
        draft.endDate = draft.startDate.addingTimeInterval(-60)
        #expect(draft.problems(now: now) == [.endBeforeStart])

        draft = validDraft()
        draft.endDate = now.addingTimeInterval(3600)
        #expect(draft.problems(now: now) == [.inFuture])
    }

    @Test func distanceAcceptsCommaAndRejectsZeroOrText() {
        var draft = validDraft()
        draft.distanceText = "3,5"
        #expect(draft.distanceMiles == 3.5)
        draft.distanceText = "0"
        #expect(draft.distanceMiles == nil)
        draft.distanceText = "abc"
        #expect(draft.distanceMiles == nil)
    }

    @Test func makeTripCopiesFieldsAndIsPendingUpload() throws {
        var draft = validDraft()
        draft.classification = .personal
        draft.notes = "  Dentist  "
        let trip = try #require(draft.makeTrip(
            start: CLLocationCoordinate2D(latitude: 1, longitude: 2),
            end: CLLocationCoordinate2D(latitude: 3, longitude: 4)
        ))
        #expect(trip.distanceMiles == 12.5)
        #expect(trip.startAddress == "1 Main St")
        #expect(trip.endAddress == "2 Oak Ave")
        #expect(trip.classification == .personal)
        #expect(trip.isManuallyClassified)
        #expect(trip.notes == "Dentist")
        #expect(!trip.isInProgress)
        #expect(trip.revision > trip.uploadedRevision)
        #expect(trip.endLatitude == 3 && trip.endLongitude == 4)
    }
}
