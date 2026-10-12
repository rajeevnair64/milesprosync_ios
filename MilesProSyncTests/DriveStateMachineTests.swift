import CoreLocation
import Foundation
import Testing
@testable import MilesProSync

struct DriveStateMachineTests {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    /// A fix `seconds` after t0, `metersNorth` of a fixed origin. Speed -1 means "invalid", as
    /// significant-change updates usually report.
    private func fix(_ seconds: TimeInterval, speed: Double, metersNorth: Double = 0, accuracy: Double = 5) -> CLLocation {
        CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 37.0 + metersNorth / 111_000, longitude: -122.0),
            altitude: 0, horizontalAccuracy: accuracy, verticalAccuracy: 5, course: 0,
            speed: speed, timestamp: t0.addingTimeInterval(seconds)
        )
    }

    /// Drives the machine from idle into `.recording` and returns the emitted actions.
    private func startRecording(_ machine: inout DriveStateMachine) -> [DriveStateMachine.Action] {
        _ = machine.handle(fix(0, speed: -1))
        var actions: [DriveStateMachine.Action] = []
        for second in stride(from: 5.0, through: 60, by: 5) {
            actions += machine.handle(fix(second, speed: 12, metersNorth: second * 12))
        }
        return actions
    }

    // MARK: - Idle → candidate

    @Test func significantChangeWithoutSpeedStillEscalatesToGPS() {
        var machine = DriveStateMachine()
        let actions = machine.handle(fix(0, speed: -1))
        #expect(actions == [.startContinuousUpdates])
        #expect(machine.phase == .candidateDriving)
    }

    @Test func redeliveredFixAtIdleAnchorDoesNotReEscalate() {
        var machine = DriveStateMachine()
        _ = machine.handle(fix(0, speed: -1))
        // No driving within the candidate window → back to idle, anchored here.
        let timeout = machine.handle(fix(200, speed: 0))
        #expect(timeout == [.returnToIdle])
        #expect(machine.phase == .idle)

        // Restarting significant-change monitoring re-delivers roughly the same position.
        #expect(machine.handle(fix(201, speed: -1, metersNorth: 50)).isEmpty)
        #expect(machine.phase == .idle)

        // Moving well away wakes it up again.
        #expect(machine.handle(fix(900, speed: -1, metersNorth: 1_000)) == [.startContinuousUpdates])
    }

    // MARK: - Candidate confirmation

    @Test func sustainedDrivingSpeedBeginsTripWithCandidatePoints() {
        var machine = DriveStateMachine()
        let actions = startRecording(&machine)
        #expect(machine.phase == .recording)
        // Confirmed at 50s (45s after the first moving fix); the 55s and 60s fixes are appended.
        #expect(actions.count == 3)
        guard case .beginTrip(let points) = actions.first else {
            Issue.record("expected beginTrip, got \(actions)")
            return
        }
        #expect(points.first?.timestamp == t0.addingTimeInterval(5))
        #expect(points.count >= 10)
    }

    @Test func briefSlowSampleDuringCandidateDoesNotAbort() {
        var machine = DriveStateMachine()
        _ = machine.handle(fix(0, speed: -1))
        _ = machine.handle(fix(5, speed: 12))
        #expect(machine.handle(fix(10, speed: 0)).isEmpty)
        #expect(machine.phase == .candidateDriving)
    }

    @Test func walkingSpeedNeverConfirmsTrip() {
        var machine = DriveStateMachine()
        _ = machine.handle(fix(0, speed: -1))
        for second in stride(from: 5.0, through: 170, by: 5) {
            #expect(machine.handle(fix(second, speed: 1.5)).isEmpty)
        }
        #expect(machine.handle(fix(180, speed: 1.5)) == [.returnToIdle])
    }

    @Test func oneMovingFixThenStandingStillNeverStartsATrip() {
        // Motion detection unavailable (isAutomotive nil): a single moving GPS sample followed by
        // 45 s of standing still used to count as a confirmed drive and record a zero-mile trip.
        var machine = DriveStateMachine()
        machine.isAutomotive = nil
        _ = machine.handle(fix(0, speed: -1))
        _ = machine.handle(fix(5, speed: 12))
        for second in stride(from: 10.0, through: 120, by: 5) {
            let actions = machine.handle(fix(second, speed: 0))
            let began = actions.contains { if case .beginTrip = $0 { true } else { false } }
            #expect(!began, "second \(second)")
        }
        #expect(machine.phase != .recording)
    }

    @Test func aLongStopRestartsTheConfirmationWindow() {
        var machine = DriveStateMachine()
        _ = machine.handle(fix(0, speed: -1))
        _ = machine.handle(fix(5, speed: 12))
        _ = machine.handle(fix(40, speed: 0)) // stopped past the grace period: earlier evidence is dropped
        var began = false
        for second in stride(from: 100.0, through: 140, by: 5) {
            let actions = machine.handle(fix(second, speed: 12, metersNorth: second * 12))
            began = began || actions.contains { if case .beginTrip = $0 { true } else { false } }
        }
        #expect(!began) // 45 s of driving hasn't passed since the new window opened at 100 s
        let actions = machine.handle(fix(145, speed: 12, metersNorth: 145 * 12))
        #expect(actions.contains { if case .beginTrip = $0 { true } else { false } })
        #expect(machine.phase == .recording)
    }

    @Test func motionSayingNotAutomotiveBlocksConfirmation() {
        var machine = DriveStateMachine()
        machine.isAutomotive = false
        _ = machine.handle(fix(0, speed: -1))
        for second in stride(from: 5.0, through: 60, by: 5) {
            _ = machine.handle(fix(second, speed: 12))
        }
        #expect(machine.phase == .candidateDriving)
    }

    // MARK: - Stopping

    @Test func redLightResumesRecording() {
        var machine = DriveStateMachine()
        _ = startRecording(&machine)
        _ = machine.handle(fix(70, speed: 0))
        _ = machine.handle(fix(105, speed: 0))
        #expect(machine.phase == .candidateStopped)

        let resume = fix(110, speed: 8)
        #expect(machine.handle(resume) == [.appendPoint(resume)])
        #expect(machine.phase == .recording)
    }

    @Test func finalizesAfterStopWhenMotionUnavailable() {
        var machine = DriveStateMachine()
        machine.isAutomotive = nil
        _ = startRecording(&machine)
        _ = machine.handle(fix(70, speed: 0))
        _ = machine.handle(fix(105, speed: 0))
        #expect(machine.handle(fix(200, speed: 0)).isEmpty)

        let end = fix(365, speed: 0)
        #expect(machine.handle(end) == [.finalizeTrip(end: end, endedAt: t0.addingTimeInterval(60)), .returnToIdle])
        #expect(machine.phase == .idle)
    }

    @Test func automotiveMotionDelaysFinalizeUntilHardCap() {
        var machine = DriveStateMachine()
        _ = startRecording(&machine)
        machine.isAutomotive = true
        _ = machine.handle(fix(70, speed: 0))
        _ = machine.handle(fix(105, speed: 0))
        #expect(machine.handle(fix(400, speed: 0)).isEmpty)

        let end = fix(60 + 15 * 60, speed: 0)
        #expect(machine.handle(end) == [.finalizeTrip(end: end, endedAt: t0.addingTimeInterval(60)), .returnToIdle])
    }

    @Test func finalizeIsEmittedOnlyOnce() {
        var machine = DriveStateMachine()
        _ = startRecording(&machine)
        _ = machine.handle(fix(70, speed: 0))
        _ = machine.handle(fix(105, speed: 0))
        _ = machine.handle(fix(400, speed: 0))
        #expect(machine.phase == .idle)
        // A late fix from the same spot must not finalize again or restart GPS.
        #expect(machine.handle(fix(401, speed: 0)).isEmpty)
    }

    @Test func resumedTripRecordsAndStops() {
        var machine = DriveStateMachine()
        machine.resumeRecording(lastMovingAt: t0)
        let point = fix(1, speed: 10)
        #expect(machine.handle(point) == [.appendPoint(point)])
        #expect(machine.phase == .recording)
    }

    // MARK: - Route quality

    @Test func stationaryFixesAreNotAddedToRoute() {
        var machine = DriveStateMachine()
        _ = startRecording(&machine)
        #expect(machine.handle(fix(65, speed: 0, metersNorth: 725)).isEmpty)
        #expect(machine.handle(fix(66, speed: 0.5, metersNorth: 740)).isEmpty)
        #expect(machine.phase == .recording)
    }

    @Test func inaccurateFixesAreNotAddedToRouteButStillTrackMovement() {
        var machine = DriveStateMachine()
        _ = startRecording(&machine)
        // A coarse significant-change fix mid-drive.
        #expect(machine.handle(fix(65, speed: 12, accuracy: 500)).isEmpty)
        #expect(machine.handle(fix(66, speed: -1, accuracy: -1)).isEmpty)
        #expect(machine.phase == .recording)
        let good = fix(70, speed: 12)
        #expect(machine.handle(good) == [.appendPoint(good)])
    }

    @Test func inaccurateFixesDoNotCountAsCandidateDriving() {
        var machine = DriveStateMachine()
        _ = machine.handle(fix(0, speed: -1))
        for second in stride(from: 5.0, through: 60, by: 5) {
            _ = machine.handle(fix(second, speed: 12, accuracy: 200))
        }
        #expect(machine.phase == .candidateDriving)
    }

    @Test func weakSignalWhileParkedStillFinalizes() {
        var machine = DriveStateMachine()
        _ = startRecording(&machine)
        _ = machine.handle(fix(70, speed: -1, accuracy: 300))
        _ = machine.handle(fix(105, speed: -1, accuracy: 300))
        #expect(machine.phase == .candidateStopped)
        let end = fix(400, speed: -1, accuracy: 300)
        #expect(machine.handle(end) == [.finalizeTrip(end: end, endedAt: t0.addingTimeInterval(60)), .returnToIdle])
    }

    // MARK: - Relaunch mid-trip

    @Test func tripEndTimeIsWhenVehicleStoppedNotWhenStopWasConfirmed() {
        var machine = DriveStateMachine()
        _ = startRecording(&machine)
        _ = machine.handle(fix(70, speed: 0))
        _ = machine.handle(fix(105, speed: 0))
        let actions = machine.handle(fix(400, speed: 0))
        guard case .finalizeTrip(_, let endedAt) = actions.first else {
            Issue.record("expected finalizeTrip, got \(actions)")
            return
        }
        #expect(endedAt == t0.addingTimeInterval(60)) // last moving fix, not the 400s confirmation
    }

    @Test func resumedAfterRelaunchWhileParkedFinishesAtLastRecordedActivity() {
        // App relaunched 8 minutes after the trip's last point; the car has been parked since.
        var machine = DriveStateMachine()
        let lastActivity = t0
        machine.resumeRecording(lastMovingAt: lastActivity)

        _ = machine.handle(fix(480, speed: 0))
        _ = machine.handle(fix(515, speed: 0)) // 30s grace passes
        #expect(machine.phase == .candidateStopped)
        let end = fix(516, speed: 0)
        #expect(machine.handle(end) == [.finalizeTrip(end: end, endedAt: lastActivity), .returnToIdle])
    }

    @Test func resumedAfterRelaunchWhileDrivingKeepsRecording() {
        var machine = DriveStateMachine()
        machine.resumeRecording(lastMovingAt: t0)
        for second in stride(from: 120.0, through: 600, by: 30) {
            let point = fix(second, speed: 15, metersNorth: second * 15)
            #expect(machine.handle(point) == [.appendPoint(point)])
        }
        #expect(machine.phase == .recording)
    }

    // MARK: - Trip start from the parked position

    /// Parks the machine at `metersNorth: 0` (idle anchor), then wakes it 400 m up the road.
    private func driveOffFromParkedCar(_ machine: inout DriveStateMachine) -> [DriveStateMachine.Action] {
        machine.seedIdleAnchor(fix(-3_600, speed: 0))
        _ = machine.handle(fix(0, speed: -1, metersNorth: 400))
        var actions: [DriveStateMachine.Action] = []
        for second in stride(from: 5.0, through: 60, by: 5) {
            actions += machine.handle(fix(second, speed: 12, metersNorth: 400 + second * 12))
        }
        return actions
    }

    @Test func tripStartsAtTheParkedPositionNotWhereTheDriveWasNoticed() {
        var machine = DriveStateMachine()
        let actions = driveOffFromParkedCar(&machine)
        guard case .beginTrip(let points) = actions.first, let start = points.first, let next = points.dropFirst().first else {
            Issue.record("expected beginTrip, got \(actions)")
            return
        }
        #expect(abs(start.coordinate.latitude - 37.0) < 0.00001)
        #expect(start.timestamp < next.timestamp)
        // Departure is estimated from the distance covered at the first recorded speed (~460 m at 12 m/s).
        #expect(next.timestamp.timeIntervalSince(start.timestamp) > 20)
        #expect(start.timestamp > t0.addingTimeInterval(-3_600))
    }

    @Test func staleParkedPositionFarFromTheWakeFixIsIgnored() {
        var machine = DriveStateMachine()
        machine.seedIdleAnchor(fix(-3_600, speed: 0, metersNorth: -50_000))
        _ = machine.handle(fix(0, speed: -1))
        var actions: [DriveStateMachine.Action] = []
        for second in stride(from: 5.0, through: 60, by: 5) {
            actions += machine.handle(fix(second, speed: 12, metersNorth: second * 12))
        }
        guard case .beginTrip(let points) = actions.first else {
            Issue.record("expected beginTrip, got \(actions)")
            return
        }
        #expect(points.first?.timestamp == t0.addingTimeInterval(5))
    }

    @Test func leavingTheParkedRegionStartsLookingForADriveImmediately() {
        var machine = DriveStateMachine()
        #expect(machine.regionExited(at: nil, now: t0) == [.startContinuousUpdates])
        #expect(machine.phase == .candidateDriving)
        // No driving follows (e.g. a walk): back to idle after the candidate timeout.
        #expect(machine.handle(fix(200, speed: 0)) == [.returnToIdle])
        #expect(machine.regionExited(at: nil, now: t0) == [.startContinuousUpdates])
        #expect(machine.regionExited(at: nil, now: t0).isEmpty)
    }
}
