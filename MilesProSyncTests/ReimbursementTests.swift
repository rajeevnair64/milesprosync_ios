import Foundation
import Testing
@testable import MilesProSync

struct ReimbursementTests {
    @Test func amountIsDisplayedMilesTimesRateRoundedToCents() {
        #expect(Reimbursement.amount(miles: 10, rate: 0.725) == 7.25)
        // 12.34 mi prints as 12.3 → 12.3 × 0.725 = 8.9175 → $8.92
        #expect(Reimbursement.amount(miles: 12.34, rate: 0.725) == 8.92)
        #expect(Reimbursement.amount(miles: 0, rate: 0.725) == 0)
    }

    @Test func totalSumsPerTripAmounts() {
        let trips = [12.34, 5.0].map {
            Trip(
                startDate: .now, endDate: .now, distanceMiles: $0,
                startLatitude: 0, startLongitude: 0, endLatitude: 0, endLongitude: 0
            )
        }
        #expect(abs(Reimbursement.total(trips, rate: 0.725) - (8.92 + 3.63)) < 0.0001)
    }

    @Test func rateLabelShowsTwoToThreeDecimals() {
        #expect(ReimbursementRate(perMile: 0.725).label == "$0.725/mi")
        #expect(ReimbursementRate(perMile: 0.7).label == "$0.70/mi")
        #expect(Reimbursement.columnTitle(rate: ReimbursementRate(perMile: 0.67)) == "Reimbursement ($0.67/mi)")
    }

    @Test func rateUsesCountryCurrencySymbol() {
        let uk = AppSettings.reimbursementRate(perMile: 0.45, countryCode: "GB")
        #expect(uk.label == "£0.45/mi")
        #expect(uk.format(4.5) == "£4.50")
        #expect(AppSettings.reimbursementRate(perMile: 0.725, countryCode: "US").format(7.25) == "$7.25")
    }

    @Test func totalMilesMatchesSumOfDisplayedMiles() {
        // 7.15 and 1.56 print as 7.2 and 1.6; the total must read 8.8, not 8.7.
        let trips = [7.15, 1.56].map {
            Trip(
                startDate: .now, endDate: .now, distanceMiles: $0,
                startLatitude: 0, startLongitude: 0, endLatitude: 0, endLongitude: 0
            )
        }
        #expect(abs(ExportFetcher.totalMiles(trips) - 8.8) < 0.0001)
    }
}
