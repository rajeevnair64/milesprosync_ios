import CoreLocation
import Foundation

/// Pure drive-detection state machine. `DriveDetectionService` feeds it location and motion
/// events and performs the actions it returns. Transitions are synchronous and do no I/O, so a
/// location that arrives while trip data is being saved can never observe a half-applied
/// transition, and the logic is unit testable without location hardware.
struct DriveStateMachine {
    enum Phase: Equatable {
        case idle
        case candidateDriving
        case recording
        case candidateStopped
    }

    enum Action: Equatable, Sendable {
        /// Switch from significant-change monitoring to continuous high-accuracy GPS.
        case startContinuousUpdates
        /// Create a trip from the confirmed candidate points; the first point is the trip start.
        case beginTrip([CLLocation])
        case appendPoint(CLLocation)
        /// `end` is where the vehicle came to rest; `endedAt` is when it last moved, so the trip's
        /// end time isn't pushed back by the minutes spent confirming the stop.
        case finalizeTrip(end: CLLocation, endedAt: Date)
        /// Stop continuous GPS and fall back to significant-change monitoring.
        case returnToIdle
    }

    struct Configuration {
        var drivingSpeed = 5.0 // m/s, ~11 mph
        var movingSpeed = 1.0 // m/s, allows for red-light stops
        /// Fixes less accurate than this aren't added to the route; at a standstill or with a
        /// poor signal, GPS wanders and every wander would count as miles driven.
        var maxRouteAccuracy = 50.0 // meters
        /// Significant-change updates rarely carry a valid speed, so while idle any update this
        /// far from where monitoring went idle is treated as a possible drive.
        var idleWakeDistance = 250.0 // meters
        var candidateConfirmDuration: TimeInterval = 45
        /// How long continuous GPS stays on waiting for driving speed before backing off to idle.
        var candidateTimeout: TimeInterval = 3 * 60
        var stopGraceDuration: TimeInterval = 30
        var stopConfirmDuration: TimeInterval = 5 * 60
        /// Finalize even if motion still reports automotive (e.g. phone left in a parked car).
        var maxStopDuration: TimeInterval = 15 * 60
        /// Monitoring only wakes the app once the car is already a few hundred meters along, and the
        /// trip is confirmed 45 s after that. The place the car was parked (where monitoring went
        /// idle) becomes the trip's start if it is within this distance of the wake-up fix.
        var maxOriginDistance = 1000.0 // meters
        /// A parked position less accurate than this isn't trusted as the start of a trip.
        var maxOriginAccuracy = 100.0 // meters
    }

    let config: Configuration
    private(set) var phase: Phase = .idle
    /// Latest motion-coprocessor verdict: true = automotive, false = confidently not automotive,
    /// nil = unknown or unavailable (simulators, devices without a motion coprocessor).
    var isAutomotive: Bool?

    /// Where monitoring went idle: the end of the last trip, or the last known position at launch.
    private(set) var idleAnchor: CLLocation?
    private var candidateOrigin: CLLocation?
    private var candidateWakeFix: CLLocation?
    private var candidateStartedAt: Date?
    private var candidatePoints: [CLLocation] = []
    private var candidateSawDrivingSpeed = false
    private var lastMovingAt: Date?
    private var stoppedSince: Date?
    /// The latest fix seen while recording, where a manual finish ends the trip if the caller has
    /// no fresher one.
    private var lastRecordingFix: CLLocation?
    /// The fix before the one being handled, for speeds the system didn't report.
    private var previousFix: CLLocation?

    init(config: Configuration = Configuration()) {
        self.config = config
    }

    /// Picks up a trip left in progress before the app was relaunched (crash, force-quit, or
    /// termination by iOS). `lastMovingAt` is the trip's last recorded activity, so if the vehicle
    /// has been parked since then the trip finishes promptly with the right end time.
    mutating func resumeRecording(lastMovingAt: Date) {
        resetCandidate()
        phase = .recording
        self.lastMovingAt = lastMovingAt
        stoppedSince = nil
    }

    /// The driver ended the trip (stopped at a destination and tapped Finish). Closes the trip
    /// where the vehicle is now and goes idle there, so the next movement is a new trip that
    /// starts at this stop. Does nothing unless a trip is being recorded.
    mutating func finishManually(currentLocation: CLLocation?, now: Date) -> [Action] {
        guard phase == .recording || phase == .candidateStopped,
              let end = currentLocation ?? lastRecordingFix else { return [] }
        // Already stopped: the trip ended when the vehicle last moved, not when Finish was tapped.
        let stopped = phase == .candidateStopped || stoppedSince != nil
        let endedAt = min(stopped ? (lastMovingAt ?? now) : now, now)
        return [.finalizeTrip(end: end, endedAt: endedAt)] + enterIdle(anchor: end)
    }

    /// Gives idle monitoring a starting position after a relaunch, when no trip has ended yet.
    mutating func seedIdleAnchor(_ location: CLLocation) {
        guard idleAnchor == nil else { return }
        idleAnchor = location
    }

    /// The device left the region set around where it was parked: start looking for a drive right
    /// away, well before a significant location change would be reported.
    mutating func regionExited(at location: CLLocation?, now: Date) -> [Action] {
        guard phase == .idle else { return [] }
        beginCandidate(at: now, wakeFix: location)
        return [.startContinuousUpdates]
    }

    mutating func handle(_ location: CLLocation) -> [Action] {
        let speed = max(location.speed, 0)
        let previous = previousFix
        previousFix = location

        switch phase {
        case .idle:
            if let idleAnchor,
               location.distance(from: idleAnchor) < config.idleWakeDistance,
               speed < config.drivingSpeed {
                // Typically the cached fix re-delivered when significant-change monitoring restarts.
                return []
            }
            beginCandidate(at: location.timestamp, wakeFix: location)
            return [.startContinuousUpdates]

        case .candidateDriving:
            let isMoving = speed >= config.movingSpeed && isRouteQuality(location)
            if !isMoving, let last = candidatePoints.last,
               location.timestamp.timeIntervalSince(last.timestamp) >= config.stopGraceDuration {
                // A prolonged stop ends the evidence for this candidate. Brief red lights
                // remain tolerated, but a later drive needs its own confirmation window.
                candidatePoints = []
                candidateSawDrivingSpeed = false
            }
            if isMoving {
                candidatePoints.append(location)
                if speed >= config.drivingSpeed { candidateSawDrivingSpeed = true }
            }
            if isMoving, let first = candidatePoints.first,
               candidateSawDrivingSpeed,
               isAutomotive != false,
               location.timestamp.timeIntervalSince(first.timestamp) >= config.candidateConfirmDuration {
                let points = pointsWithOrigin(candidatePoints)
                resetCandidate()
                phase = .recording
                lastMovingAt = location.timestamp
                stoppedSince = nil
                return [.beginTrip(points)]
            }
            let startedAt = candidateStartedAt ?? location.timestamp
            if location.timestamp.timeIntervalSince(startedAt) >= config.candidateTimeout {
                return enterIdle(anchor: location)
            }
            return []

        case .recording:
            let speed = movementSpeed(of: location, since: previous)
            lastRecordingFix = location
            // Poor or stationary fixes still drive stop detection (a parking garage has weak
            // GPS), they just aren't added to the route.
            if speed >= config.movingSpeed {
                lastMovingAt = location.timestamp
                stoppedSince = nil
                return isRouteQuality(location) ? [.appendPoint(location)] : []
            }
            let since = stoppedSince ?? location.timestamp
            stoppedSince = since
            if location.timestamp.timeIntervalSince(since) >= config.stopGraceDuration {
                phase = .candidateStopped
            }
            return []

        case .candidateStopped:
            let speed = movementSpeed(of: location, since: previous)
            lastRecordingFix = location
            if speed >= config.movingSpeed {
                // Resumed driving (e.g. was just a red light) — back to recording.
                phase = .recording
                lastMovingAt = location.timestamp
                stoppedSince = nil
                return isRouteQuality(location) ? [.appendPoint(location)] : []
            }
            let stoppedFor = lastMovingAt.map { location.timestamp.timeIntervalSince($0) } ?? .infinity
            let confirmedStop = stoppedFor >= config.stopConfirmDuration && isAutomotive != true
            if confirmedStop || stoppedFor >= config.maxStopDuration {
                let endedAt = lastMovingAt ?? location.timestamp
                return [.finalizeTrip(end: location, endedAt: endedAt)] + enterIdle(anchor: location)
            }
            return []
        }
    }

    /// The fix's speed, or, when the system reports none (-1, common between updates), the speed
    /// implied by how far the car moved since the last fix. Without it those fixes read as
    /// stopped and are left out of the route, which then crosses the gap in a straight line.
    /// Movement counts only when it exceeds both fixes' accuracy, so GPS wander at a standstill
    /// isn't mistaken for driving.
    private func movementSpeed(of location: CLLocation, since previous: CLLocation?) -> Double {
        if location.speed >= 0 { return location.speed }
        guard let previous, isRouteQuality(location), isRouteQuality(previous) else { return 0 }
        let seconds = location.timestamp.timeIntervalSince(previous.timestamp)
        let meters = location.distance(from: previous)
        guard seconds > 0, seconds <= 30,
              meters > location.horizontalAccuracy + previous.horizontalAccuracy else { return 0 }
        return meters / seconds
    }

    private func isRouteQuality(_ location: CLLocation) -> Bool {
        location.horizontalAccuracy >= 0 && location.horizontalAccuracy <= config.maxRouteAccuracy
    }

    private mutating func enterIdle(anchor: CLLocation) -> [Action] {
        resetCandidate()
        phase = .idle
        idleAnchor = anchor
        lastMovingAt = nil
        stoppedSince = nil
        lastRecordingFix = nil
        return [.returnToIdle]
    }

    private mutating func beginCandidate(at date: Date, wakeFix: CLLocation?) {
        resetCandidate()
        phase = .candidateDriving
        candidateStartedAt = date
        candidateOrigin = idleAnchor
        candidateWakeFix = wakeFix
    }

    /// Prepends the parked position as the trip's first point, timed from how far the car travelled
    /// at its first recorded speed, so the start (time, address, distance) isn't where monitoring
    /// happened to notice the drive.
    private func pointsWithOrigin(_ points: [CLLocation]) -> [CLLocation] {
        guard let first = points.first, let origin = candidateOrigin,
              origin.horizontalAccuracy >= 0, origin.horizontalAccuracy <= config.maxOriginAccuracy,
              origin.distance(from: (candidateWakeFix ?? first)) <= config.maxOriginDistance else { return points }
        let gap = origin.distance(from: first)
        guard gap >= 20, gap <= 2 * config.maxOriginDistance else { return points }
        let travelTime = min(max(gap / max(first.speed, 3), 5), 10 * 60)
        let departedAt = min(first.timestamp.addingTimeInterval(-travelTime), first.timestamp)
        let start = CLLocation(
            coordinate: origin.coordinate,
            altitude: origin.altitude,
            horizontalAccuracy: origin.horizontalAccuracy,
            verticalAccuracy: origin.verticalAccuracy,
            timestamp: max(departedAt, min(origin.timestamp, first.timestamp))
        )
        return [start] + points
    }

    private mutating func resetCandidate() {
        candidateStartedAt = nil
        candidateOrigin = nil
        candidateWakeFix = nil
        candidatePoints = []
        candidateSawDrivingSpeed = false
    }
}
