import CoreLocation
import Testing
@testable import MilesProSync

struct MileageCalculatorTests {
    @Test func zeroDistanceForSinglePoint() {
        let coordinate = CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194)
        #expect(MileageCalculator.distanceMiles(for: [coordinate]) == 0)
    }

    @Test func zeroDistanceForEmptyRoute() {
        let coordinates: [CLLocationCoordinate2D] = []
        #expect(MileageCalculator.distanceMiles(for: coordinates) == 0)
    }

    @Test func knownDistanceBetweenTwoPoints() {
        // Roughly Ferry Building to the Golden Gate Bridge toll plaza in San Francisco.
        let start = CLLocationCoordinate2D(latitude: 37.7955, longitude: -122.3937)
        let end = CLLocationCoordinate2D(latitude: 37.8199, longitude: -122.4783)
        let miles = MileageCalculator.distanceMiles(for: [start, end])
        #expect(miles > 4 && miles < 6)
    }

    @Test func sumsMultipleSegments() {
        let a = CLLocationCoordinate2D(latitude: 0, longitude: 0)
        let b = CLLocationCoordinate2D(latitude: 0, longitude: 0.01)
        let c = CLLocationCoordinate2D(latitude: 0.01, longitude: 0.01)
        let total = MileageCalculator.distanceMiles(for: [a, b, c])
        let ab = MileageCalculator.distanceMiles(for: [a, b])
        let bc = MileageCalculator.distanceMiles(for: [b, c])
        #expect(abs(total - (ab + bc)) < 0.0001)
    }
}
