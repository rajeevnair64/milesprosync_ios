import CoreLocation
import Foundation
import Testing
@testable import MilesProSync

struct AddressFormatTests {
    @Test func fullAddressIncludesNumberCityStateAndZip() {
        let parts = AddressParts(
            subThoroughfare: "123", thoroughfare: "Main St", locality: "Austin",
            administrativeArea: "TX", postalCode: "78701"
        )
        #expect(parts.formatted == "123 Main St, Austin, TX 78701")
    }

    @Test func withoutNumberUsesPlaceNameThenStreet() {
        let parts = AddressParts(
            name: "Zilker Park", thoroughfare: "Barton Springs Rd", locality: "Austin",
            administrativeArea: "TX", postalCode: "78704"
        )
        #expect(parts.formatted == "Zilker Park, Barton Springs Rd, Austin, TX 78704")
    }

    @Test func nameRepeatingTheStreetIsNotDuplicated() {
        let parts = AddressParts(name: "Main St", thoroughfare: "Main St", locality: "Austin", administrativeArea: "TX")
        #expect(parts.formatted == "Main St, Austin, TX")
    }
}

struct NearestAddressTests {
    private let origin = (latitude: 37.0, longitude: -122.0)

    private func candidate(_ parts: AddressParts, at coordinate: CLLocationCoordinate2D) -> AddressCandidate {
        AddressCandidate(
            parts: parts,
            location: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        )
    }

    @Test func exactHouseNumberIsUsedWithoutProbing() async {
        let calls = LockedCounter()
        let service = GeocodingService { location in
            calls.increment()
            return AddressCandidate(
                parts: AddressParts(subThoroughfare: "10", thoroughfare: "Oak Ave", locality: "Town", administrativeArea: "CA", postalCode: "90000"),
                location: location
            )
        }
        let address = await service.reverseGeocode(latitude: origin.latitude, longitude: origin.longitude)
        #expect(address == "10 Oak Ave, Town, CA 90000")
        #expect(calls.value == 1)
    }

    @Test func missingNumberFallsBackToNearestNumberedNeighbour() async {
        let north = GeocodingService.offset(CLLocationCoordinate2D(latitude: origin.latitude, longitude: origin.longitude), meters: 25, bearingDegrees: 0)
        let service = GeocodingService { location in
            let isNorthProbe = abs(location.coordinate.latitude - north.latitude) < 1e-7
            if isNorthProbe {
                return AddressCandidate(
                    parts: AddressParts(subThoroughfare: "42", thoroughfare: "Elm St", locality: "Town", administrativeArea: "CA", postalCode: "90000"),
                    location: location
                )
            }
            return AddressCandidate(
                parts: AddressParts(thoroughfare: "Elm St", locality: "Town", administrativeArea: "CA", postalCode: "90000"),
                location: location
            )
        }
        let address = await service.reverseGeocode(latitude: origin.latitude, longitude: origin.longitude)
        #expect(address == "42 Elm St, Town, CA 90000")
    }

    @Test func noNeighbourHasNumberUsesBestDescription() async {
        let service = GeocodingService { location in
            AddressCandidate(
                parts: AddressParts(thoroughfare: "Rural Rd", locality: "Town", administrativeArea: "CA", postalCode: "90000"),
                location: location
            )
        }
        let address = await service.reverseGeocode(latitude: origin.latitude, longitude: origin.longitude)
        #expect(address == "Rural Rd, Town, CA 90000")
    }

    @Test func failedLookupReturnsNil() async {
        let service = GeocodingService { _ in nil }
        let address = await service.reverseGeocode(latitude: origin.latitude, longitude: origin.longitude)
        #expect(address == nil)
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

struct ManualFinishTests {
    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    private func fix(_ seconds: TimeInterval, metersNorth: Double = 0, speed: Double) -> CLLocation {
        CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 37.0 + metersNorth / 111_000, longitude: -122.0),
            altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5, course: 0,
            speed: speed, timestamp: base.addingTimeInterval(seconds)
        )
    }

    private func recordingMachine() -> DriveStateMachine {
        var machine = DriveStateMachine()
        _ = machine.handle(fix(0, speed: 10))
        for second in stride(from: 5.0, through: 50, by: 5) {
            _ = machine.handle(fix(second, metersNorth: second * 10, speed: 10))
        }
        #expect(machine.phase == .recording)
        return machine
    }

    @Test func finishWhileRecordingEndsTripNowAndGoesIdle() {
        var machine = recordingMachine()
        let here = fix(60, metersNorth: 600, speed: 8)
        let now = base.addingTimeInterval(60)
        let actions = machine.finishManually(currentLocation: here, now: now)
        #expect(actions == [.finalizeTrip(end: here, endedAt: now), .returnToIdle])
        #expect(machine.phase == .idle)
        #expect(machine.idleAnchor == here)
    }

    @Test func finishAfterStoppingUsesTimeVehicleLastMoved() {
        var machine = recordingMachine()
        _ = machine.handle(fix(60, metersNorth: 600, speed: 0))
        _ = machine.handle(fix(100, metersNorth: 600, speed: 0))
        #expect(machine.phase == .candidateStopped)
        let here = fix(120, metersNorth: 600, speed: 0)
        let actions = machine.finishManually(currentLocation: here, now: base.addingTimeInterval(120))
        #expect(actions == [.finalizeTrip(end: here, endedAt: base.addingTimeInterval(50)), .returnToIdle])
    }

    @Test func finishWhenNotRecordingDoesNothing() {
        var machine = DriveStateMachine()
        #expect(machine.finishManually(currentLocation: fix(0, speed: 0), now: base).isEmpty)
        #expect(machine.phase == .idle)
    }
}
