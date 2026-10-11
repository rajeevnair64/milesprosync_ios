import CoreLocation
import Foundation
import SwiftData
import Testing
@testable import MilesProSync

/// A location source the test drives by hand, recording what the service asked of it.
@MainActor
final class FakeLocationManager: LocationManaging {
    weak var events: (any LocationManagerEvents)?
    var authorizationStatus: CLAuthorizationStatus = .authorizedAlways
    var location: CLLocation?
    var isRegionMonitoringAvailable = true

    private(set) var isUpdating = false
    private(set) var isMonitoringSignificantChanges = false
    private(set) var regions: [String: CLCircularRegion] = [:]
    private(set) var requestedWhenInUse = false
    private(set) var requestedAlways = false

    func requestWhenInUseAuthorization() { requestedWhenInUse = true }
    func requestAlwaysAuthorization() { requestedAlways = true }
    func startDrivingUpdates() { isUpdating = true }
    func stopUpdatingLocation() { isUpdating = false }
    func startMonitoringSignificantLocationChanges() { isMonitoringSignificantChanges = true }
    func stopMonitoringSignificantLocationChanges() { isMonitoringSignificantChanges = false }
    func startMonitoring(region: CLCircularRegion) { regions[region.identifier] = region }
    func stopMonitoring(regionIdentifier: String) { regions[regionIdentifier] = nil }

    // MARK: Test controls

    func deliver(_ locations: CLLocation...) {
        events?.didUpdate(locations: locations)
    }

    func exitRegion(_ identifier: String) {
        events?.didExitRegion(identifier: identifier, lastKnown: location)
    }

    func changeAuthorization(to status: CLAuthorizationStatus) {
        authorizationStatus = status
        events?.didChangeAuthorization(status)
    }
}

@MainActor
private final class Counter {
    var value = 0
}

@MainActor
struct DriveDetectionServiceTests {
    private let base = Date()
    private let container: ModelContainer
    private let locations = FakeLocationManager()
    private let finished = Counter()
    private let service: DriveDetectionService

    init() throws {
        container = try ModelContainer(
            for: Trip.self, RoutePoint.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        service = DriveDetectionService(
            modelContainer: container,
            locationManager: locations,
            reverseGeocode: { latitude, _ in "Near \(String(format: "%.3f", latitude))" }
        )
        let finished = finished
        service.onTripFinished = { finished.value += 1 }
    }

    // MARK: - Helpers

    /// A fix `seconds` after `base`, `metersNorth` of a fixed origin.
    private func fix(_ seconds: TimeInterval, metersNorth: Double = 0, speed: Double) -> CLLocation {
        CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 37.0 + metersNorth / 111_000, longitude: -122.0),
            altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5, course: 0,
            speed: speed, timestamp: base.addingTimeInterval(seconds)
        )
    }

    private func start(status: CLAuthorizationStatus = .authorizedAlways, lastKnown: CLLocation? = nil) async {
        locations.authorizationStatus = status
        locations.location = lastKnown
        service.start()
        await service.waitForPendingActions()
    }

    @discardableResult
    private func insertInProgressTrip(lastPointMinutesAgo minutes: Double) throws -> UUID {
        let context = ModelContext(container)
        let startedAt = Date().addingTimeInterval(-(minutes + 10) * 60)
        let trip = Trip(
            startDate: startedAt, endDate: startedAt, distanceMiles: 0,
            startLatitude: 37, startLongitude: -122, endLatitude: 37, endLongitude: -122,
            isInProgress: true
        )
        context.insert(trip)
        for step in 0..<3 {
            trip.route.append(RoutePoint(
                latitude: 37 + Double(step) * 0.001, longitude: -122,
                timestamp: Date().addingTimeInterval(-minutes * 60 - Double(2 - step) * 10)
            ))
        }
        try context.save()
        return trip.id
    }

    private func trips() throws -> [Trip] {
        try ModelContext(container).fetch(FetchDescriptor<Trip>())
    }

    private func waitUntil(_ description: String, _ condition: () -> Bool) async {
        for _ in 0..<300 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for \(description)")
    }

    // MARK: - Authorization

    @Test func armsIdleMonitoringWhenAuthorized() async {
        await start(lastKnown: fix(0, speed: 0))

        #expect(locations.isMonitoringSignificantChanges)
        #expect(!locations.isUpdating)
        #expect(Set(locations.regions.keys) == ["parked"])
        #expect(service.phase == .idle)
        let parked = locations.regions["parked"]
        #expect(parked?.notifyOnExit == true)
        #expect(parked?.notifyOnEntry == false)
        #expect(abs((parked?.center.latitude ?? 0) - 37.0) < 0.00001)
    }

    @Test func withoutAKnownPositionThereIsNoParkedRegionYet() async {
        await start()
        #expect(locations.isMonitoringSignificantChanges)
        #expect(locations.regions.isEmpty)
    }

    @Test func whenInUseAccessAsksForAlwaysButStillRecords() async {
        await start(status: .authorizedWhenInUse)
        #expect(locations.requestedAlways)
        #expect(locations.isMonitoringSignificantChanges)
    }

    @Test func undeterminedAccessAsksThenStartsOnceGranted() async {
        await start(status: .notDetermined)
        #expect(locations.requestedWhenInUse)
        #expect(!locations.isMonitoringSignificantChanges)

        locations.changeAuthorization(to: .authorizedAlways)
        await service.waitForPendingActions()
        #expect(locations.isMonitoringSignificantChanges)
        #expect(service.authorizationStatus == .authorizedAlways)
    }

    @Test func authorizationChangeBeforeStartDoesNotSwitchDetectionOn() async {
        locations.changeAuthorization(to: .authorizedAlways)
        await service.waitForPendingActions()
        #expect(!locations.isMonitoringSignificantChanges)
    }

    @Test func deniedAccessFinishesStaleTripsAndFillsInAddresses() async throws {
        let id = try insertInProgressTrip(lastPointMinutesAgo: 30)

        await start(status: .denied)
        await waitUntil("the trip to be reported finished") { finished.value == 1 }

        let trip = try #require(try trips().first { $0.id == id })
        #expect(!trip.isInProgress)
        #expect(trip.startAddress?.hasPrefix("Near") == true)
        #expect(!locations.isMonitoringSignificantChanges)
        #expect(locations.regions.isEmpty)
    }

    // MARK: - Relaunch recovery

    @Test func recentInterruptedTripIsResumedAndFollowed() async throws {
        let id = try insertInProgressTrip(lastPointMinutesAgo: 1)

        await start(lastKnown: fix(0, speed: 10))

        #expect(service.phase == .recording)
        #expect(locations.isUpdating)
        #expect(Set(locations.regions.keys) == ["route"])
        let trip = try #require(try trips().first { $0.id == id })
        #expect(trip.isInProgress)
    }

    @Test func staleInterruptedTripIsFinishedAndMonitoringGoesIdle() async throws {
        let id = try insertInProgressTrip(lastPointMinutesAgo: 30)

        await start(lastKnown: fix(0, speed: 0))
        await waitUntil("the trip to be reported finished") { finished.value == 1 }

        let trip = try #require(try trips().first { $0.id == id })
        #expect(!trip.isInProgress)
        #expect(service.phase == .idle)
        #expect(!locations.isUpdating)
        #expect(Set(locations.regions.keys) == ["parked"])
    }

    // MARK: - Driving

    @Test func leavingTheParkedRegionStartsGPSAndDropsTheRegion() async {
        await start(lastKnown: fix(0, speed: 0))

        locations.exitRegion("parked")
        await service.waitForPendingActions()

        #expect(locations.isUpdating)
        #expect(service.phase == .candidateDriving)
        #expect(locations.regions["parked"] == nil)
    }

    @Test func routeRegionExitNeedsNoAction() async throws {
        let id = try insertInProgressTrip(lastPointMinutesAgo: 1)
        await start(lastKnown: fix(0, speed: 10))

        locations.exitRegion("route")
        await service.waitForPendingActions()

        #expect(service.phase == .recording)
        #expect(try trips().first { $0.id == id }?.isInProgress == true)
    }

    @Test func aWholeDriveIsRecordedFollowedAndFinished() async throws {
        await start(lastKnown: fix(-600, speed: 0))
        locations.exitRegion("parked")

        // 100 m up the road at the first fix, then 60 s at 12 m/s.
        for second in stride(from: 0.0, through: 60, by: 5) {
            locations.deliver(fix(second, metersNorth: 100 + second * 12, speed: 12))
        }
        await service.waitForPendingActions()
        #expect(service.phase == .recording)
        var recording = try #require(try trips().first)
        #expect(recording.isInProgress)
        // Starts where the car was parked, not where the drive was noticed.
        #expect(abs(recording.startLatitude - 37.0) < 0.0001)
        #expect(recording.startDate < base)
        // The route region follows the car, and the parked one is gone.
        #expect(Set(locations.regions.keys) == ["route"])
        let followed = try #require(locations.regions["route"])
        #expect(followed.center.latitude > 37.0 + 600 / 111_000)

        // Stops: moving ends at +60 s, grace period, then a confirmed stop five minutes later.
        locations.deliver(fix(70, metersNorth: 820, speed: 0))
        locations.deliver(fix(100, metersNorth: 820, speed: 0))
        locations.deliver(fix(370, metersNorth: 820, speed: 0))
        await service.waitForPendingActions()
        await waitUntil("the trip to be reported finished") { finished.value == 1 }

        recording = try #require(try trips().first)
        #expect(!recording.isInProgress)
        #expect(recording.endDate == base.addingTimeInterval(60))
        #expect(recording.distanceMiles > 0.4)
        #expect(recording.startAddress?.hasPrefix("Near") == true)
        #expect(recording.endAddress?.hasPrefix("Near") == true)
        #expect(service.phase == .idle)
        #expect(!locations.isUpdating)
        #expect(Set(locations.regions.keys) == ["parked"])
        #expect(try trips().count == 1)
    }

    @Test func shortWalkOutOfTheRegionFallsBackToIdle() async {
        await start(lastKnown: fix(0, speed: 0))
        locations.exitRegion("parked")
        // Walking pace for longer than the candidate timeout: never confirmed as a drive.
        for second in stride(from: 0.0, through: 200, by: 20) {
            locations.deliver(fix(second, metersNorth: 50 + second * 1.5, speed: 1.5))
        }
        await service.waitForPendingActions()

        #expect(service.phase == .idle)
        #expect(!locations.isUpdating)
        #expect(Set(locations.regions.keys) == ["parked"])
        #expect((try? trips().count) == 0)
    }

    // MARK: - Stopping

    @Test func stopRemovesEverythingAndIgnoresLaterEvents() async throws {
        await start(lastKnown: fix(0, speed: 0))
        locations.exitRegion("parked")
        await service.waitForPendingActions()

        service.stop()

        #expect(!locations.isUpdating)
        #expect(!locations.isMonitoringSignificantChanges)
        #expect(locations.regions.isEmpty)
        #expect(locations.events == nil)

        // Nothing is wired up any more, so late fixes are never recorded.
        locations.deliver(fix(5, metersNorth: 200, speed: 12))
        await service.waitForPendingActions()
        #expect(try trips().isEmpty)
    }
}
