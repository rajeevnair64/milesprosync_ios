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

    @Test func refusalExplainsWhichSideTheProductIsOn() {
        #expect(AccountType.individual.refusal(forPurchasing: ProductID.individualAnnual) == nil)
        #expect(AccountType.individual.refusal(forPurchasing: ProductID.fiveYear) == nil)
        #expect(AccountType.individual.refusal(forPurchasing: ProductID.team)?.contains("switch to Teams") == true)
        #expect(AccountType.team.refusal(forPurchasing: ProductID.teamAnnual) == nil)
        #expect(AccountType.team.refusal(forPurchasing: ProductID.fiveYear)?.contains("Teams") == true)
        #expect(AccountType.team.refusal(forPurchasing: ProductID.individual) != nil)
    }

    @Test func everyProductBelongsToExactlyOneType() {
        for id in ProductID.store {
            let owners = AccountType.allCases.filter { $0.allows(productID: id) }
            #expect(owners.count == 1, "\(id) belongs to \(owners.count) types")
        }
    }

    @Test func aPaidPlanDecidesTheTypeInEveryCombination() {
        let plans: [(AccessState, AccountType)] = [
            (.subscribed(.team), .team),
            (.subscribed(.individual), .individual),
            (.purchased(featuresThrough: later, endsAt: later), .individual),
        ]
        for (state, expected) in plans {
            for stored in [nil, AccountType.individual, .team] {
                #expect(AccountType.resolve(stored: stored, state: state) == expected)
            }
        }
    }

    @Test func nothingPaidAndNothingChosenMeansAskingThePerson() {
        #expect(AccountType.resolve(stored: nil, state: .trial(endsAt: later)) == nil)
        #expect(AccountType.resolve(stored: nil, state: .expired) == nil)
        #expect(AccountType.resolve(stored: nil, state: .subscribed(nil)) == nil)
    }

    @Test func policyStateAndTypeAgreeForEachPlan() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let until = start.addingTimeInterval(86_400 * 30)
        let now = start.addingTimeInterval(86_400)
        let individual = AccessPolicy.state(
            trialStart: start, subscribedUntil: until, plan: Plan(productID: ProductID.individualAnnual), now: now
        )
        let team = AccessPolicy.state(
            trialStart: start, subscribedUntil: until, plan: Plan(productID: ProductID.team), now: now
        )
        let payOnce = AccessPolicy.state(trialStart: start, subscribedUntil: nil, plan: nil, purchasedAt: start, now: now)
        #expect(AccountType.resolve(stored: nil, state: individual) == .individual)
        #expect(AccountType.resolve(stored: nil, state: team) == .team)
        #expect(AccountType.resolve(stored: nil, state: payOnce) == .individual)
    }
}

@MainActor
struct AccountTypeManagerTests {
    @Test func choosingBeforePayingIsAllowedAndChangeable() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let manager = SubscriptionManager(defaults: defaults)
        #expect(manager.accountType == nil)

        #expect(manager.chooseAccountType(.team))
        #expect(manager.accountType == .team)
        #expect(AccessStore.storedAccountType(defaults: defaults) == .team)

        #expect(manager.chooseAccountType(.individual))
        #expect(manager.accountType == .individual)
    }

    @Test func aStoredChoiceIsRestoredOnLaunch() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        AccessStore.saveAccountType(.team, defaults: defaults)
        #expect(SubscriptionManager(defaults: defaults).accountType == .team)
    }

    @Test func aCachedPaidPlanOverridesTheStoredChoiceAndPinsIt() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        AccessStore.saveAccountType(.individual, defaults: defaults)
        AccessStore.saveSubscription(
            until: Date().addingTimeInterval(86_400 * 30), plan: .team, productID: ProductID.team, defaults: defaults
        )
        let manager = SubscriptionManager(defaults: defaults)

        #expect(manager.accountType == .team)
        #expect(!manager.chooseAccountType(.individual))
        #expect(manager.accountType == .team)
    }
}
