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

/// Trips on a route the person has classified before are classified the same way; a route they
/// never classified is left to the saved places and work hours; one they classified both ways is
/// left to them.
struct RouteMemoryTests {
    private let home = CLLocationCoordinate2D(latitude: 30.3000, longitude: -97.7000)
    private let office = CLLocationCoordinate2D(latitude: 30.2672, longitude: -97.7431)
    private let clinic = CLLocationCoordinate2D(latitude: 30.4000, longitude: -97.8000)

    /// About `meters` north of a coordinate.
    private func moved(_ coordinate: CLLocationCoordinate2D, meters: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: coordinate.latitude + meters / 111_320, longitude: coordinate.longitude)
    }

    private func trip(
        _ start: CLLocationCoordinate2D, _ end: CLLocationCoordinate2D, _ classification: TripClassification = .unclassified,
        manual: Bool = false, at date: Date = Date(timeIntervalSince1970: 1_800_000_000)
    ) -> Trip {
        Trip(
            startDate: date, endDate: date.addingTimeInterval(1_200), distanceMiles: 5,
            startLatitude: start.latitude, startLongitude: start.longitude, endLatitude: end.latitude, endLongitude: end.longitude,
            classification: classification, isManuallyClassified: manual
        )
    }

    @Test func aRouteNeverClassifiedHasNoHistory() {
        let history = [trip(home, clinic, .business, manual: true)]
        #expect(RouteMemory.verdict(for: trip(home, office), among: history) == .noHistory)
        #expect(RouteMemory.verdict(for: trip(home, office), among: []) == .noHistory)
    }

    @Test func aRouteClassifiedBeforeGivesTheSameClassification() {
        let history = [trip(home, office, .business, manual: true)]
        // A few meters off at each end is still the same route.
        let again = trip(moved(home, meters: 60), moved(office, meters: 90))
        #expect(RouteMemory.verdict(for: again, among: history) == .classification(.business))
    }

    @Test func theReturnLegIsTheSameRoute() {
        let history = [trip(home, office, .personal, manual: true)]
        #expect(RouteMemory.verdict(for: trip(office, home), among: history) == .classification(.personal))
    }

    @Test func aDifferentStartOrEndIsADifferentRoute() {
        let history = [trip(home, office, .business, manual: true)]
        #expect(RouteMemory.verdict(for: trip(moved(home, meters: 400), office), among: history) == .noHistory)
        #expect(RouteMemory.verdict(for: trip(home, moved(office, meters: 400)), among: history) == .noHistory)
        #expect(RouteMemory.verdict(for: trip(home, clinic), among: history) == .noHistory)
    }

    @Test func onlyTripsThePersonClassifiedAreHistory() {
        let automatic = trip(home, office, .business, manual: false)
        let unclassified = trip(home, office, .unclassified, manual: true)
        let deleted = trip(home, office, .business, manual: true)
        deleted.markDeleted()
        #expect(RouteMemory.verdict(for: trip(home, office), among: [automatic, unclassified, deleted]) == .noHistory)
    }

    @Test func aRouteClassifiedBothWaysIsLeftToThePerson() {
        let history = [trip(home, office, .business, manual: true), trip(office, home, .personal, manual: true)]
        #expect(RouteMemory.verdict(for: trip(home, office), among: history) == .ambiguous)
        // Many trips that agree are not ambiguous.
        let agreeing = [trip(home, office, .business, manual: true), trip(office, home, .business, manual: true), trip(home, office, .business, manual: true)]
        #expect(RouteMemory.verdict(for: trip(home, office), among: agreeing) == .classification(.business))
    }

    @Test func aTripIsNeverItsOwnHistory() {
        let only = trip(home, office, .business, manual: true)
        #expect(RouteMemory.verdict(for: only, among: [only]) == .noHistory)
    }

    // MARK: - With the rules

    private var workHours: ClassificationRules {
        var rules = ClassificationRules()
        rules.workHoursEnabled = true
        return rules
    }

    /// A Monday 10:00 local time, inside the default work hours.
    private var duringWork: Date { Calendar.current.date(from: DateComponents(year: 2026, month: 3, day: 2, hour: 10))! }

    @Test func aLearnedRouteBeatsWorkHoursAndSavedPlaces() {
        var rules = workHours
        rules.places = [SavedPlace(name: "Office", latitude: office.latitude, longitude: office.longitude, classification: .business)]
        let history = [trip(home, office, .personal, manual: true)]   // the person says commuting is Personal
        let commute = trip(home, office, at: duringWork)

        #expect(rules.apply(to: commute, learningFrom: history))
        #expect(commute.classification == .personal)
        #expect(!commute.isManuallyClassified)
    }

    @Test func aRouteNeverClassifiedFallsBackToTheRules() {
        let history = [trip(home, clinic, .personal, manual: true)]
        let drive = trip(home, office, at: duringWork)

        #expect(workHours.apply(to: drive, learningFrom: history))
        #expect(drive.classification == .business)
    }

    @Test func withNoRulesAndNoHistoryTheTripStaysUnclassified() {
        let drive = trip(home, office, at: duringWork)
        #expect(!ClassificationRules().apply(to: drive, learningFrom: []))
        #expect(drive.classification == .unclassified)
    }

    @Test func anAmbiguousRouteIsNotGuessedByTheRules() {
        let history = [trip(home, office, .business, manual: true), trip(home, office, .personal, manual: true)]
        let drive = trip(home, office, at: duringWork)

        #expect(!workHours.apply(to: drive, learningFrom: history))
        #expect(drive.classification == .unclassified)
    }

    @Test func aTripThePersonClassifiedIsNeverChanged() {
        let chosen = trip(home, office, .personal, manual: true)
        let history = [trip(home, office, .business, manual: true)]

        #expect(!workHours.apply(to: chosen, learningFrom: history))
        #expect(chosen.classification == .personal)
    }
}
