import Foundation
import Testing
@testable import MilesProSync

struct AccessPolicyTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        calendar.date(from: DateComponents(timeZone: TimeZone(identifier: "UTC"), year: y, month: m, day: d))!
    }

    @Test func newUsersGetTwoFreeMonths() {
        let start = date(2026, 1, 15)
        #expect(AccessPolicy.trialEnd(from: start, calendar: calendar) == date(2026, 3, 15))
        let during = AccessPolicy.state(trialStart: start, subscribedUntil: nil, plan: nil, now: date(2026, 3, 14), calendar: calendar)
        #expect(during == .trial(endsAt: date(2026, 3, 15)))
        #expect(during.allowsRecording)
    }

    @Test func recordingStopsAfterTheFreePeriodWithoutASubscription() {
        let state = AccessPolicy.state(
            trialStart: date(2026, 1, 15), subscribedUntil: nil, plan: nil, now: date(2026, 3, 15), calendar: calendar
        )
        #expect(state == .expired)
        #expect(!state.allowsRecording)
    }

    @Test func aCurrentSubscriptionKeepsRecordingOn() {
        let state = AccessPolicy.state(
            trialStart: date(2026, 1, 15), subscribedUntil: date(2026, 5, 1), plan: .individual,
            now: date(2026, 4, 1), calendar: calendar
        )
        #expect(state == .subscribed(.individual))
        #expect(state.allowsRecording)
    }

    @Test func aLapsedSubscriptionAfterTheTrialIsExpired() {
        let state = AccessPolicy.state(
            trialStart: date(2026, 1, 15), subscribedUntil: date(2026, 4, 1), plan: .team,
            now: date(2026, 4, 2), calendar: calendar
        )
        #expect(state == .expired)
    }

    @Test func productsMapToPlans() {
        #expect(Plan(productID: ProductID.individual) == .individual)
        #expect(Plan(productID: ProductID.individualAnnual) == .individual)
        #expect(Plan(productID: ProductID.team) == .team)
        #expect(Plan(productID: ProductID.teamAnnual) == .team)
        #expect(Set(ProductID.all).count == 4)
        #expect(ProductID.teamPlans == [ProductID.team, ProductID.teamAnnual])
        #expect(Plan(productID: "other") == nil)
    }

    // MARK: Pay-once (five-year) purchase

    @Test func aPurchaseLastsFiveYears() {
        let bought = date(2026, 6, 1)
        #expect(AccessPolicy.purchaseEnd(from: bought, calendar: calendar) == date(2031, 6, 1))
        let during = AccessPolicy.state(
            trialStart: date(2026, 1, 15), subscribedUntil: nil, plan: nil, purchasedAt: bought,
            now: date(2031, 5, 31), calendar: calendar
        )
        #expect(during == .purchased(featuresThrough: bought, endsAt: date(2031, 6, 1)))
        #expect(during.allowsRecording)
    }

    @Test func recordingStopsWhenTheFiveYearsEnd() {
        let state = AccessPolicy.state(
            trialStart: date(2026, 1, 15), subscribedUntil: nil, plan: nil, purchasedAt: date(2026, 6, 1),
            now: date(2031, 6, 1), calendar: calendar
        )
        #expect(state == .expired)
        #expect(!state.allowsRecording)
    }

    @Test func aSubscriptionTakesPrecedenceOverAPurchase() {
        let state = AccessPolicy.state(
            trialStart: date(2026, 1, 15), subscribedUntil: date(2026, 9, 1), plan: .individual,
            purchasedAt: date(2026, 6, 1), now: date(2026, 7, 1), calendar: calendar
        )
        #expect(state == .subscribed(.individual))
    }

    @Test func aPurchaseCoversFeaturesReleasedUpToIt() {
        let old = PremiumFeature(id: "old", name: "Old", releasedAt: date(2026, 3, 1))
        let same = PremiumFeature(id: "same", name: "Same", releasedAt: date(2026, 6, 1))
        let later = PremiumFeature(id: "later", name: "Later", releasedAt: date(2026, 9, 1))
        let state = AccessState.purchased(featuresThrough: date(2026, 6, 1), endsAt: date(2031, 6, 1))
        #expect(state.includes(old))
        #expect(state.includes(same))
        #expect(!state.includes(later))
    }

    @Test func subscribersAndTrialsHaveEveryFeature() {
        let later = PremiumFeature(id: "later", name: "Later", releasedAt: date(2030, 1, 1))
        #expect(AccessState.subscribed(.individual).includes(later))
        #expect(AccessState.trial(endsAt: date(2026, 3, 15)).includes(later))
        #expect(!AccessState.expired.includes(later))
    }

    @Test func anUpgradeAddsFeaturesButNotTime() {
        let bought = date(2026, 6, 1)
        let upgraded = date(2027, 2, 1)
        #expect(AccessPolicy.featureCoverage(purchasedAt: bought, upgradedAt: nil) == bought)
        #expect(AccessPolicy.featureCoverage(purchasedAt: bought, upgradedAt: upgraded) == upgraded)
        let feature = PremiumFeature(id: "f", name: "F", releasedAt: date(2026, 12, 1))
        let state = AccessPolicy.state(
            trialStart: date(2026, 1, 15), subscribedUntil: nil, plan: nil, purchasedAt: bought,
            featuresThrough: upgraded, now: date(2027, 3, 1), calendar: calendar
        )
        #expect(state.includes(feature))
        #expect(state == .purchased(featuresThrough: upgraded, endsAt: date(2031, 6, 1)))
    }

    @Test func upgradesStayHiddenUntilACoupleOfFeaturesExist() {
        let one = PremiumFeature(id: "a", name: "A", releasedAt: date(2026, 9, 1))
        let two = PremiumFeature(id: "b", name: "B", releasedAt: date(2026, 10, 1))
        #expect(!PremiumFeature.upgradeIsOffered(among: []))
        #expect(!PremiumFeature.upgradeIsOffered(among: [one]))
        #expect(PremiumFeature.upgradeIsOffered(among: [one, two]))
        #expect(!PremiumFeature.upgradeIsOffered())
    }

    @Test func anUpgradeAloneUnlocksNothing() {
        #expect(AccessPolicy.featureCoverage(purchasedAt: nil, upgradedAt: date(2027, 2, 1)) == nil)
    }

    @Test func oneTimeProductsAreNotSubscriptionsOrTeamPlans() {
        #expect(Plan(productID: ProductID.fiveYear) == nil)
        #expect(Plan(productID: ProductID.fiveYearUpgrade) == nil)
        #expect(!ProductID.all.contains(ProductID.fiveYear))
        #expect(!ProductID.teamPlans.contains(ProductID.fiveYear))
        #expect(ProductID.oneTime == [ProductID.fiveYear, ProductID.fiveYearUpgrade])
        #expect(Set(ProductID.store).count == 6)
    }

    @Test func theCachedPurchaseDrivesAccessState() {
        let suite = "access-purchase-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let item = KeychainItem(service: "com.aisleweb.MilesProSync.tests.\(suite)", account: "start")
        defer { _ = item.write(nil) }
        let now = date(2027, 1, 1)
        // Trial started long ago, so without the purchase this would be expired.
        _ = item.write(Data(String(date(2026, 1, 1).timeIntervalSince1970).utf8))
        #expect(AccessStore.state(now: now, defaults: defaults, item: item) == .expired)

        AccessStore.savePurchase(at: date(2026, 6, 1), featuresThrough: date(2026, 6, 1), defaults: defaults)
        let state = AccessStore.state(now: now, defaults: defaults, item: item)
        #expect(state.allowsRecording)
        if case .purchased(_, let end) = state {
            #expect(end == AccessPolicy.purchaseEnd(from: date(2026, 6, 1)))
        } else {
            Issue.record("Expected a purchased state, got \(state)")
        }

        AccessStore.savePurchase(at: nil, featuresThrough: nil, defaults: defaults)
        #expect(AccessStore.state(now: now, defaults: defaults, item: item) == .expired)
    }

    @Test func teamStatusDecodesTheServersResponse() throws {
        let json = """
        {"subscription":{"active":true,"expires_at":"2026-11-10T12:00:00.123456+00:00","price":"$3.99","product_ids":["x"]},
         "team":{"id":"t1","name":"Acme","role":"driver","joined_at":"2026-10-01T00:00:00+00:00","timezone":"UTC",
                 "rate":{"per_mile":"0.725","symbol":"$"}},
         "reports":[{"month":"2026-09","status":"rejected","submitted_at":null,"reviewed_at":null,"comment":"Missing a trip",
                     "trip_count":null,"miles":null,"amount":null,"symbol":"$"}]}
        """
        let status = try #require(TeamStatus.decode(Data(json.utf8)))
        #expect(status.subscription.active)
        #expect(status.team?.name == "Acme")
        #expect(status.team?.rate.perMile == "0.725")
        #expect(status.reports.first?.comment == "Missing a trip")
        #expect(TeamService.recentMonths(now: date(2026, 1, 20), calendar: calendar) == ["2026-01", "2025-12", "2025-11"])
    }

    @Test func teamCallsSendTheSignedInToken() async throws {
        let server = FakeServer()
        await server.enqueue(200, #"{"subscription":{"active":false},"team":null,"reports":[]}"#)
        let session = AuthSession(accessToken: "tok", refreshToken: "r", expiresAt: .now.addingTimeInterval(3600), userID: "u", email: nil)
        let client = APIClient(config: SyncFixtures.config, tokenStore: InMemoryTokenStore(session), transport: server.transport)

        let status = try await client.teamStatus()

        #expect(status.team == nil)
        let request = try #require(await server.requests.first)
        #expect(request.url?.absoluteString == "https://miles.example/api/v1/team")
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
    }
}
