import CoreLocation
import CoreMotion
import Foundation
import Observation
import SwiftData

/// Automatic drive detection: significant-location-change monitoring while idle (battery
/// friendly, wakes the app in the background), escalating to continuous high-accuracy GPS once
/// a drive looks likely, and finalizing the trip once the vehicle has been stopped for a while.
/// The transition logic lives in `DriveStateMachine`; this class wires it to CoreLocation,
/// CoreMotion and `TripRecorder`.
@Observable
@MainActor
final class DriveDetectionService {
    private(set) var authorizationStatus: CLAuthorizationStatus
    var phase: DriveStateMachine.Phase { machine.phase }
    /// Called once a finished trip is fully saved, addresses included (e.g. to upload it).
    @ObservationIgnored var onTripFinished: (@MainActor () -> Void)?

    private let locationManager: any LocationManaging
    private let motionActivityManager = CMMotionActivityManager()
    private let recorder: TripRecorder
    private let reverseGeocode: @Sendable (Double, Double) async -> String?
    private let defaults: UserDefaults

    private var machine = DriveStateMachine()
    private var hasStarted = false
    private var hasFinishedStaleTrips = false
    /// Set by `start()`. Permission changes re-run `start()` only once it has been asked for:
    /// CLLocationManager reports authorization as soon as its delegate is set, which must not
    /// switch detection on for a session that was never started.
    private var wantsToRun = false
    /// Set by `stop()` on sign-out; nothing restarts location or motion updates after that.
    private var isStopped = false
    /// The trip being recorded, set once `beginTrip` has persisted it.
    private var currentTripID: PersistentIdentifier?
    /// Tail of a serial queue: each batch of state-machine actions awaits the previous batch, so
    /// trip writes land in the order they were emitted even though each one suspends.
    private var actionQueue: Task<Void, Never>?

    /// `locationManager` and `reverseGeocode` default to the system's; tests pass scripted ones.
    init(
        modelContainer: ModelContainer,
        defaults: UserDefaults = .standard,
        locationManager: (any LocationManaging)? = nil,
        reverseGeocode: @escaping @Sendable (Double, Double) async -> String? = { latitude, longitude in
            await GeocodingService.shared.reverseGeocode(latitude: latitude, longitude: longitude)
        }
    ) {
        let locationManager = locationManager ?? SystemLocationManager()
        self.locationManager = locationManager
        self.reverseGeocode = reverseGeocode
        self.defaults = defaults
        self.recorder = TripRecorder(modelContainer: modelContainer)
        self.authorizationStatus = locationManager.authorizationStatus
        locationManager.events = self
    }

    /// Ends the trip being recorded where the vehicle is now (the driver stopped at a destination
    /// and tapped Finish). Whatever follows is recorded as a new trip. A trip left "in progress"
    /// that nothing is recording is finished at its last point instead.
    func finishCurrentTrip() {
        enqueue {
            guard !self.isStopped else { return }
            let actions = self.machine.finishManually(
                currentLocation: self.locationManager.location, now: Date()
            )
            if actions.isEmpty {
                if self.currentTripID == nil { await self.finishStaleTrips() }
            } else {
                await self.perform(actions)
            }
        }
    }

    /// Completes once everything queued so far (recovery, location fixes, region exits) has run.
    func waitForPendingActions() async {
        await actionQueue?.value
    }

    // MARK: - Lifecycle

    /// Safe to call repeatedly; must run on every launch (including background relaunches from
    /// significant location changes) so monitoring is re-armed.
    func start() {
        guard !isStopped else { return }
        wantsToRun = true
        switch locationManager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            if locationManager.authorizationStatus == .authorizedWhenInUse {
                // Significant-change relaunches only happen with Always authorization. iOS shows
                // this prompt at most once, so repeat calls are harmless.
                locationManager.requestAlwaysAuthorization()
            }
            guard !hasStarted else { return }
            hasStarted = true
            enqueue { await self.recoverAfterLaunch() }
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
        default:
            // Without access nothing can resume a trip left in progress, so finish it where it
            // stopped instead of leaving it "Recording" (and out of exports and sync) indefinitely.
            // If access was lost while running, also drop the in-memory trip and monitoring so
            // regaining access starts cleanly instead of being ignored by `hasStarted`.
            let wasRunning = hasStarted
            hasStarted = false
            guard wasRunning || !hasFinishedStaleTrips else { break }
            hasFinishedStaleTrips = true
            enqueue {
                if wasRunning { self.resetAfterLosingAccess() }
                await self.finishStaleTrips()
            }
        }
    }

    private func resetAfterLosingAccess() {
        currentTripID = nil
        machine = DriveStateMachine()
        locationManager.stopUpdatingLocation()
        locationManager.stopMonitoringSignificantLocationChanges()
        stopMonitoringParkedRegion()
        stopMonitoringRouteRegion()
        motionActivityManager.stopActivityUpdates()
    }

    private func finishStaleTrips() async {
        let recovery = await recorder.recoverInProgressTrips(now: Date(), resumeWindow: 0)
        guard !recovery.finished.isEmpty else { return }
        Task {
            for trip in recovery.finished {
                await self.lookUpAddresses(for: trip.tripID, start: trip.start, end: trip.end, knownStart: trip.startAddress)
            }
            self.onTripFinished?()
        }
    }

    /// How recently an unfinished trip must have recorded a point to be resumed after a relaunch
    /// rather than finished where recording stopped.
    static let resumeWindow: TimeInterval = 10 * 60
    private static let addressRetryWindow: TimeInterval = 30 * 24 * 3600
    private static let addressRetryLimit = 20
    /// Raised when the saved address format changes, so older trips are looked up again once.
    private static let addressFormatVersion = 2
    private static let addressFormatKey = "drive.addressFormatVersion"

    /// Runs on every launch, including background relaunches. Resumes a trip interrupted moments
    /// ago, finishes any interrupted longer ago, and fills in addresses that were never looked up.
    private func recoverAfterLaunch() async {
        let now = Date()
        let recovery = await recorder.recoverInProgressTrips(now: now, resumeWindow: Self.resumeWindow)
        if let resume = recovery.resume {
            currentTripID = resume.tripID
            machine.resumeRecording(lastMovingAt: resume.lastActivityAt)
            beginContinuousUpdates()
            if let lastKnown = locationManager.location { followRoute(with: lastKnown) }
        } else {
            beginIdleMonitoring()
        }

        var missing = await recorder.tripsMissingAddresses(
            within: Self.addressRetryWindow, now: now, limit: Self.addressRetryLimit
        )
        if defaults.integer(forKey: Self.addressFormatKey) < Self.addressFormatVersion {
            // Addresses saved by an earlier build are short ("Main St, Austin, TX"): look the
            // most recent ones up again, once, in the full format.
            let known = Set(missing.map(\.tripID))
            let refresh = await recorder.recentFinishedTrips(
                within: Self.addressRetryWindow, now: now, limit: Self.addressRetryLimit
            )
            missing += refresh.filter { !known.contains($0.tripID) }
            defaults.set(Self.addressFormatVersion, forKey: Self.addressFormatKey)
        }
        guard !missing.isEmpty || !recovery.finished.isEmpty else { return }
        // Not awaited: geocoding is a network call and shouldn't hold up the action queue.
        Task {
            for trip in missing {
                await self.lookUpAddresses(for: trip.tripID, start: trip.start, end: trip.end, knownStart: trip.startAddress)
            }
            self.onTripFinished?()
        }
    }

    // MARK: - Power-conscious monitoring

    /// Stops all location and motion updates for good; used when this session is replaced by
    /// another account's. A trip in progress stays in progress and is recovered when that
    /// account's session next starts.
    func stop() {
        isStopped = true
        locationManager.stopUpdatingLocation()
        locationManager.stopMonitoringSignificantLocationChanges()
        stopMonitoringParkedRegion()
        stopMonitoringRouteRegion()
        locationManager.events = nil
        motionActivityManager.stopActivityUpdates()
        onTripFinished = nil
    }

    /// Radius of the region set around where the car is parked. Leaving it wakes the app much
    /// sooner than a significant location change (which comes after several hundred meters).
    private static let parkedRegionRadius: CLLocationDistance = 100
    nonisolated private static let parkedRegionID = "parked"
    /// While recording, a region follows the car: if the app is killed mid-drive, leaving it
    /// relaunches the app within a couple hundred meters instead of waiting for the next
    /// significant location change. It is re-centred once the car is `routeRegionRecenter` from
    /// the centre, so the app is relaunched at most about radius + recenter meters after the kill.
    private static let routeRegionRadius: CLLocationDistance = 150
    private static let routeRegionRecenter: CLLocationDistance = 75
    nonisolated private static let routeRegionID = "route"
    private var routeRegionCenter: CLLocation?

    private func beginIdleMonitoring() {
        guard !isStopped else { return }
        locationManager.stopUpdatingLocation()
        locationManager.startMonitoringSignificantLocationChanges()
        motionActivityManager.stopActivityUpdates()
        machine.isAutomotive = nil
        stopMonitoringRouteRegion()
        if machine.idleAnchor == nil {
            // The remembered parking spot beats the cached fix: after a relaunch caused by a drive
            // starting, the cached fix is already along the route and would hide the start.
            if let saved = savedIdleAnchor() {
                machine.seedIdleAnchor(saved)
            } else if let lastKnown = locationManager.location {
                machine.seedIdleAnchor(lastKnown)
            }
        }
        if let anchor = machine.idleAnchor { saveIdleAnchor(anchor) }
        monitorParkedRegion()
    }

    private static let idleAnchorKey = "drive.idleAnchor"

    private func saveIdleAnchor(_ anchor: CLLocation) {
        defaults.set([
            anchor.coordinate.latitude, anchor.coordinate.longitude,
            anchor.horizontalAccuracy, anchor.timestamp.timeIntervalSince1970,
        ], forKey: Self.idleAnchorKey)
    }

    private func savedIdleAnchor() -> CLLocation? {
        guard let values = defaults.array(forKey: Self.idleAnchorKey) as? [Double], values.count == 4 else { return nil }
        return CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: values[0], longitude: values[1]),
            altitude: 0, horizontalAccuracy: values[2], verticalAccuracy: -1,
            timestamp: Date(timeIntervalSince1970: values[3])
        )
    }

    private func monitorParkedRegion() {
        stopMonitoringParkedRegion()
        guard let anchor = machine.idleAnchor,
              locationManager.isRegionMonitoringAvailable else { return }
        let region = CLCircularRegion(
            center: anchor.coordinate, radius: Self.parkedRegionRadius, identifier: Self.parkedRegionID
        )
        region.notifyOnEntry = false
        region.notifyOnExit = true
        locationManager.startMonitoring(region: region)
    }

    /// Keeps the route region within `routeRegionRecenter` of the car. Re-registering with the
    /// same identifier replaces the earlier region.
    private func followRoute(with location: CLLocation) {
        guard !isStopped, location.horizontalAccuracy >= 0,
              locationManager.isRegionMonitoringAvailable else { return }
        if let center = routeRegionCenter, location.distance(from: center) < Self.routeRegionRecenter { return }
        let region = CLCircularRegion(
            center: location.coordinate, radius: Self.routeRegionRadius, identifier: Self.routeRegionID
        )
        region.notifyOnEntry = false
        region.notifyOnExit = true
        locationManager.startMonitoring(region: region)
        routeRegionCenter = location
    }

    private func stopMonitoringRouteRegion() {
        routeRegionCenter = nil
        locationManager.stopMonitoring(regionIdentifier: Self.routeRegionID)
    }

    private func stopMonitoringParkedRegion() {
        locationManager.stopMonitoring(regionIdentifier: Self.parkedRegionID)
    }

    private func parkedRegionExited(lastKnown: CLLocation?) {
        enqueue {
            guard !self.isStopped else { return }
            let actions = self.machine.regionExited(at: lastKnown, now: Date())
            await self.perform(actions)
        }
    }

    private func beginContinuousUpdates() {
        guard !isStopped else { return }
        stopMonitoringParkedRegion()
        // Significant-change monitoring stays on during a drive: it's what lets iOS relaunch the
        // app if it's terminated mid-trip, so the in-progress trip can be resumed. Its coarse
        // fixes are kept off the route by the state machine's accuracy filter.
        locationManager.startMonitoringSignificantLocationChanges()
        locationManager.startDrivingUpdates()

        guard CMMotionActivityManager.isActivityAvailable() else { return }
        motionActivityManager.startActivityUpdates(to: .main) { [weak self] activity in
            guard let self, let activity else { return }
            let isAutomotive: Bool? = if activity.automotive {
                true
            } else if activity.unknown || activity.confidence == .low {
                nil
            } else {
                false
            }
            Task { @MainActor in
                self.machine.isAutomotive = isAutomotive
            }
        }
    }

    // MARK: - Action execution

    /// Runs on the action queue, behind launch recovery, so a fix delivered while a relaunch is
    /// still resuming an unfinished trip is applied to the resumed state, not dropped.
    private func process(_ location: CLLocation) {
        enqueue {
            guard !self.isStopped else { return }
            let actions = self.machine.handle(location)
            await self.perform(actions)
        }
    }

    private func enqueue(_ operation: @escaping @MainActor () async -> Void) {
        let previous = actionQueue
        actionQueue = Task {
            await previous?.value
            await operation()
        }
    }

    private func perform(_ actions: [DriveStateMachine.Action]) async {
        for action in actions {
            switch action {
            case .startContinuousUpdates:
                beginContinuousUpdates()

            case .returnToIdle:
                beginIdleMonitoring()

            case .beginTrip(let points):
                guard let first = points.first else { continue }
                let tripID = await recorder.beginTrip(at: first)
                for point in points.dropFirst() {
                    await recorder.appendPoint(point, to: tripID)
                }
                currentTripID = tripID
                if let last = points.last { followRoute(with: last) }
                // The start is known as soon as the trip begins; resolve it now so the trip shows
                // where it began while it is still recording.
                let start = first.coordinate
                Task {
                    guard let address = await self.reverseGeocode(start.latitude, start.longitude) else { return }
                    await self.recorder.setAddresses(startAddress: address, endAddress: nil, for: tripID)
                }

            case .appendPoint(let location):
                guard let currentTripID else { continue }
                await recorder.appendPoint(location, to: currentTripID)
                followRoute(with: location)

            case .finalizeTrip(let end, let endedAt):
                guard let tripID = currentTripID else { continue }
                currentTripID = nil
                guard let endpoints = await recorder.finalizeTrip(tripID, endLocation: end, endedAt: endedAt) else { continue }
                // Not awaited: geocoding is a network call and shouldn't hold up the queue.
                Task {
                    await self.lookUpAddresses(for: tripID, start: endpoints.start, end: endpoints.end, knownStart: endpoints.startAddress)
                    self.onTripFinished?()
                }
            }
        }
    }

    private func lookUpAddresses(
        for tripID: PersistentIdentifier, start: CLLocationCoordinate2D, end: CLLocationCoordinate2D,
        knownStart: String? = nil
    ) async {
        // Sequential on purpose: reverse geocoding is rate-limited, and firing both at once
        // tends to get one of them rejected.
        let startAddress: String?
        if let knownStart {
            startAddress = knownStart
        } else {
            startAddress = await reverseGeocode(start.latitude, start.longitude)
        }
        let endAddress = await reverseGeocode(end.latitude, end.longitude)
        await recorder.setAddresses(startAddress: startAddress, endAddress: endAddress, for: tripID)
    }
}

extension DriveDetectionService: LocationManagerEvents {
    func didUpdate(locations: [CLLocation]) {
        for location in locations {
            process(location)
        }
    }

    func didExitRegion(identifier: String, lastKnown: CLLocation?) {
        // Leaving the route region needs no action: being relaunched is the point of it.
        guard identifier == Self.parkedRegionID else { return }
        parkedRegionExited(lastKnown: lastKnown)
    }

    func didChangeAuthorization(_ status: CLAuthorizationStatus) {
        authorizationStatus = status
        if wantsToRun {
            start()
        }
    }
}
