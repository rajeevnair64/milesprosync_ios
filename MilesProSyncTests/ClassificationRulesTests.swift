import CoreLocation
import Foundation
import Testing
@testable import MilesProSync

struct ClassificationRulesTests {
    private let office = CLLocationCoordinate2D(latitude: 30.2672, longitude: -97.7431)
    private let home = CLLocationCoordinate2D(latitude: 30.35, longitude: -97.70)
    private let elsewhere = CLLocationCoordinate2D(latitude: 31.0, longitude: -98.0)

    private func date(weekdayOffset: Int = 0, hour: Int) -> Date {
        // 2026-03-02 is a Monday.
        Calendar.current.date(from: DateComponents(year: 2026, month: 3, day: 2 + weekdayOffset, hour: hour))!
    }

    private func place(_ name: String, _ c: CLLocationCoordinate2D, _ k: TripClassification) -> SavedPlace {
        SavedPlace(name: name, latitude: c.latitude, longitude: c.longitude, classification: k)
    }

    @Test func noRulesLeavesTripAlone() {
        #expect(ClassificationRules().classification(start: home, end: elsewhere, startDate: date(hour: 10)) == nil)
    }

    @Test func destinationPlaceBeatsStartPlace() {
        var rules = ClassificationRules()
        rules.places = [place("Office", office, .business), place("Home", home, .personal)]
        #expect(rules.classification(start: home, end: office, startDate: date(hour: 8)) == .business)
        #expect(rules.classification(start: office, end: home, startDate: date(hour: 18)) == .personal)
        #expect(rules.classification(start: office, end: elsewhere, startDate: date(hour: 18)) == .business)
    }

    @Test func workHoursDecideWhenNoPlaceMatches() {
        var rules = ClassificationRules()
        rules.workHoursEnabled = true
        #expect(rules.classification(start: home, end: elsewhere, startDate: date(hour: 10)) == .business)
        #expect(rules.classification(start: home, end: elsewhere, startDate: date(hour: 18)) == .personal)
        #expect(rules.classification(start: home, end: elsewhere, startDate: date(weekdayOffset: 5, hour: 10)) == .personal)
    }

    @Test func applySkipsTripsTheUserClassified() {
        var rules = ClassificationRules()
        rules.places = [place("Office", office, .business)]
        let auto = Trip(
            startDate: date(hour: 9), endDate: date(hour: 10), distanceMiles: 3,
            startLatitude: home.latitude, startLongitude: home.longitude,
            endLatitude: office.latitude, endLongitude: office.longitude
        )
        #expect(rules.apply(to: auto))
        #expect(auto.classification == .business)
        #expect(!auto.isManuallyClassified)

        let chosen = Trip(
            startDate: date(hour: 9), endDate: date(hour: 10), distanceMiles: 3,
            startLatitude: home.latitude, startLongitude: home.longitude,
            endLatitude: office.latitude, endLongitude: office.longitude,
            classification: .personal, isManuallyClassified: true
        )
        #expect(!rules.apply(to: chosen))
        #expect(chosen.classification == .personal)
    }

    @Test func purposesAddWithoutDuplicates() {
        #expect(TripPurposes.adding(" Training ", to: ["Meeting"]) == ["Meeting", "Training"])
        #expect(TripPurposes.adding("meeting", to: ["Meeting"]) == ["Meeting"])
        #expect(TripPurposes.adding("  ", to: ["Meeting"]) == ["Meeting"])
        #expect(TripPurposes.parse(TripPurposes.encode(["A", "B"])) == ["A", "B"])
    }
}
