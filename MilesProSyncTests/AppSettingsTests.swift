import Foundation
import Testing
@testable import MilesProSync

struct AppSettingsTests {
    @Test func defaultsToUnitedStatesAndIRSRate() {
        #expect(AppSettings.defaultCountryCode == "US")
        #expect(AppSettings.defaultMileageRate == 0.725)
    }

    @Test func countryListContainsDefaultAndOnlyCountries() {
        let codes = AppSettings.countries.map(\.code)
        #expect(codes.contains(AppSettings.defaultCountryCode))
        #expect(codes.contains("CA"))
        #expect(!codes.contains("001")) // "World" is a region, not a country
        #expect(Set(codes).count == codes.count)
    }

    @Test func parsesTypedRates() {
        #expect(AppSettings.parseRate("0.67") == 0.67)
        #expect(AppSettings.parseRate("0,67") == 0.67) // comma-decimal locales
        #expect(AppSettings.parseRate(" 1 ") == 1)
        #expect(AppSettings.parseRate("0") == 0)
        #expect(AppSettings.parseRate("") == nil)
        #expect(AppSettings.parseRate(".") == nil)
        #expect(AppSettings.parseRate("-0.5") == nil)
        #expect(AppSettings.parseRate("abc") == nil)
        #expect(AppSettings.parseRate("inf") == nil)
    }

    @Test func formatsRateForTheTextField() {
        #expect(AppSettings.formatRate(0.725) == "0.725")
        #expect(AppSettings.formatRate(0.7) == "0.70")
        #expect(AppSettings.formatRate(1) == "1.00")
    }
}
