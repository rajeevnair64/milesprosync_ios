import CoreLocation
import Foundation

/// What the location manager reports back. Delivered on the main actor.
@MainActor
protocol LocationManagerEvents: AnyObject {
    func didUpdate(locations: [CLLocation])
    /// `lastKnown` is the manager's cached position at the time of the exit.
    func didExitRegion(identifier: String, lastKnown: CLLocation?)
    func didChangeAuthorization(_ status: CLAuthorizationStatus)
}

/// The slice of `CLLocationManager` that drive detection uses, so detection can be tested with a
/// scripted location source.
@MainActor
protocol LocationManaging: AnyObject {
    var events: (any LocationManagerEvents)? { get set }
    var authorizationStatus: CLAuthorizationStatus { get }
    /// The most recent fix the system has cached, if any.
    var location: CLLocation? { get }
    var isRegionMonitoringAvailable: Bool { get }

    func requestWhenInUseAuthorization()
    func requestAlwaysAuthorization()
    /// Continuous best-accuracy updates for driving.
    func startDrivingUpdates()
    func stopUpdatingLocation()
    func startMonitoringSignificantLocationChanges()
    func stopMonitoringSignificantLocationChanges()
    /// Replaces any region with the same identifier.
    func startMonitoring(region: CLCircularRegion)
    func stopMonitoring(regionIdentifier: String)
}

/// The real thing: `CLLocationManager` configured for background recording.
@MainActor
final class SystemLocationManager: NSObject, LocationManaging {
    weak var events: (any LocationManagerEvents)?
    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        manager.allowsBackgroundLocationUpdates = true
        manager.pausesLocationUpdatesAutomatically = false
    }

    var authorizationStatus: CLAuthorizationStatus { manager.authorizationStatus }
    var location: CLLocation? { manager.location }
    var isRegionMonitoringAvailable: Bool { CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self) }

    func requestWhenInUseAuthorization() { manager.requestWhenInUseAuthorization() }
    func requestAlwaysAuthorization() { manager.requestAlwaysAuthorization() }

    func startDrivingUpdates() {
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.activityType = .automotiveNavigation
        manager.distanceFilter = kCLDistanceFilterNone
        manager.startUpdatingLocation()
    }

    func stopUpdatingLocation() { manager.stopUpdatingLocation() }
    func startMonitoringSignificantLocationChanges() { manager.startMonitoringSignificantLocationChanges() }
    func stopMonitoringSignificantLocationChanges() { manager.stopMonitoringSignificantLocationChanges() }

    func startMonitoring(region: CLCircularRegion) { manager.startMonitoring(for: region) }

    func stopMonitoring(regionIdentifier: String) {
        for region in manager.monitoredRegions where region.identifier == regionIdentifier {
            manager.stopMonitoring(for: region)
        }
    }
}

extension SystemLocationManager: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in
            self.events?.didUpdate(locations: locations)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        let identifier = region.identifier
        let lastKnown = manager.location
        Task { @MainActor in
            self.events?.didExitRegion(identifier: identifier, lastKnown: lastKnown)
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.events?.didChangeAuthorization(status)
        }
    }
}
