import CoreLocation
import Foundation
import Testing
@testable import MilesProSync

struct RecordingStatusTests {
    @Test func alwaysAccessIsReadyOrRecording() {
        #expect(RecordingStatus.resolve(authorization: .authorizedAlways, planAllowsRecording: true, isRecording: false) == .ready)
        #expect(RecordingStatus.resolve(authorization: .authorizedAlways, planAllowsRecording: true, isRecording: true) == .recording)
    }

    @Test func missingLocationNeedsAction() {
        #expect(RecordingStatus.resolve(authorization: .denied, planAllowsRecording: true, isRecording: false) == .actionNeeded(.locationOff))
        #expect(RecordingStatus.resolve(authorization: .restricted, planAllowsRecording: true, isRecording: false) == .actionNeeded(.locationOff))
        #expect(RecordingStatus.resolve(authorization: .authorizedWhenInUse, planAllowsRecording: true, isRecording: false) == .actionNeeded(.locationNotAlways))
        #expect(RecordingStatus.resolve(authorization: .notDetermined, planAllowsRecording: true, isRecording: false) == .actionNeeded(.setupIncomplete))
    }

    @Test func expiredPlanNeedsAction() {
        #expect(RecordingStatus.resolve(authorization: .authorizedAlways, planAllowsRecording: false, isRecording: false) == .actionNeeded(.planExpired))
    }

    @Test func onboardingIsOnlyNeededBeforeLocationIsAsked() {
        let defaults = UserDefaults(suiteName: "onboarding-\(UUID().uuidString)")!
        #expect(Onboarding.isNeeded(status: .notDetermined, defaults: defaults))
        #expect(!Onboarding.isNeeded(status: .authorizedAlways, defaults: defaults))
        Onboarding.markComplete(defaults: defaults)
        #expect(!Onboarding.isNeeded(status: .notDetermined, defaults: defaults))
    }
}

struct TripMergeTests {
    private func trip(_ start: Double, _ end: Double, miles: Double, _ c: TripClassification = .unclassified) -> Trip {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        return Trip(
            startDate: base.addingTimeInterval(start), endDate: base.addingTimeInterval(end),
            distanceMiles: miles, startLatitude: 1, startLongitude: 1, endLatitude: Double(miles), endLongitude: 2,
            endAddress: "End \(miles)", classification: c
        )
    }

    @Test func mergeJoinsDistanceAndEndAndDeletesTheLaterTrip() {
        let first = trip(0, 600, miles: 3)
        let second = trip(900, 1500, miles: 4, .business)
        let kept = Trip.merge(second, first)
        #expect(kept === first)
        #expect(first.distanceMiles == 7)
        #expect(first.endDate == second.endDate)
        #expect(first.endAddress == "End 4.0")
        #expect(first.classification == .business)
        #expect(second.isDeleted)
    }

    @Test func inProgressTripsCannotMerge() {
        let done = trip(0, 600, miles: 3)
        let live = trip(900, 1500, miles: 4)
        live.isInProgress = true
        #expect(!done.canMerge(with: live))
    }
}
