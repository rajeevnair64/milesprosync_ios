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
