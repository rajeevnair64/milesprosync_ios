import Foundation
import Testing
@testable import MilesProSync

struct AccountTypeTests {
    private let later = Date(timeIntervalSince1970: 2_000_000_000)

    @Test func aTeamPlanMakesTheAccountTeamsWhateverWasChosen() {
        #expect(AccountType.resolve(stored: .individual, state: .subscribed(.team)) == .team)
    }

    @Test func individualPlansAndPayOnceMakeTheAccountIndividual() {
        #expect(AccountType.resolve(stored: .team, state: .subscribed(.individual)) == .individual)
        #expect(AccountType.resolve(stored: nil, state: .purchased(featuresThrough: later, endsAt: later)) == .individual)
    }

    @Test func withoutAPaymentTheChoiceStands() {
        #expect(AccountType.resolve(stored: nil, state: .trial(endsAt: later)) == nil)
        #expect(AccountType.resolve(stored: .team, state: .trial(endsAt: later)) == .team)
        #expect(AccountType.resolve(stored: .individual, state: .expired) == .individual)
    }

    @Test func eachTypeBuysOnlyItsOwnProducts() {
        for id in [ProductID.individual, ProductID.individualAnnual, ProductID.fiveYear, ProductID.fiveYearUpgrade] {
            #expect(AccountType.individual.allows(productID: id))
            #expect(!AccountType.team.allows(productID: id))
        }
        for id in ProductID.teamPlans {
            #expect(AccountType.team.allows(productID: id))
            #expect(!AccountType.individual.allows(productID: id))
        }
    }

    @Test func theTypeIsPinnedWhileAPlanIsPaidFor() {
        #expect(AccountType.canChange(in: .trial(endsAt: later)))
        #expect(AccountType.canChange(in: .expired))
        #expect(!AccountType.canChange(in: .subscribed(.team)))
        #expect(!AccountType.canChange(in: .purchased(featuresThrough: later, endsAt: later)))
    }

    @Test func choiceIsStoredAndCleared() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        #expect(AccessStore.storedAccountType(defaults: defaults) == nil)
        AccessStore.saveAccountType(.team, defaults: defaults)
        #expect(AccessStore.storedAccountType(defaults: defaults) == .team)
        AccessStore.saveAccountType(nil, defaults: defaults)
        #expect(AccessStore.storedAccountType(defaults: defaults) == nil)
    }
}
