import Foundation
import Testing
@testable import MilesProSync

@MainActor
struct SettingsSyncTests {
    private let server = FakeServer()
    private let defaults = UserDefaults(suiteName: UUID().uuidString)!
    private let service: SettingsSyncService
    private var clock: Date

    init() {
        let client = APIClient(
            config: SyncFixtures.config,
            tokenStore: InMemoryTokenStore(SyncFixtures.session()),
            transport: server.transport
        )
        service = SettingsSyncService(client: client, defaults: defaults, isSignedIn: { true })
        clock = .now
    }

    private static func record(
        mode: String = "custom", rate: Double = 0.5, favrFixed: Double = 0, updatedAt: String = "2026-10-11T10:00:00+00:00"
    ) -> String {
        """
        {"country_code":"US","rate_mode":"\(mode)","mileage_rate":\(rate),"favr_fixed_monthly":\(favrFixed),
         "favr_per_mile":0,"favr_min_monthly_miles":0,"updated_at":"\(updatedAt)"}
        """
    }

    private func settingsRequests() async -> [URLRequest] {
        await server.requests.filter { $0.url?.path() == "/api/v1/settings" }
    }

    private func body(_ request: URLRequest) -> [String: Any] {
        (SyncFixtures.body(of: request) as? [String: Any]) ?? [:]
    }

    @Test func firstSyncUploadsThisDevicesSettingsWhenTheAccountHasNone() async throws {
        defaults.set("custom", forKey: AppSettings.Key.rateMode)
        defaults.set(0.61, forKey: AppSettings.Key.mileageRate)
        await server.enqueue(404, #"{"message":"No settings are saved for this account."}"#)
        await server.enqueue(200, Self.record(rate: 0.61))

        await service.sync()

        let requests = await settingsRequests()
        #expect(requests.map(\.httpMethod) == ["GET", "PUT"])
        let sent = body(requests[1])
        #expect(sent["rate_mode"] as? String == "custom")
        #expect(sent["mileage_rate"] as? Double == 0.61)
        #expect(sent["base_updated_at"] == nil)
        #expect(defaults.string(forKey: SettingsSyncService.baseKey) == "2026-10-11T10:00:00+00:00")
    }

    @Test func firstSyncAppliesTheAccountsSavedSettings() async {
        await server.enqueue(200, Self.record(mode: "favr", rate: 0.5, favrFixed: 300))

        await service.sync()

        #expect(await settingsRequests().map(\.httpMethod) == ["GET"])
        #expect(defaults.string(forKey: AppSettings.Key.rateMode) == "favr")
        #expect(defaults.double(forKey: AppSettings.Key.favrFixedMonthly) == 300)
        #expect(defaults.double(forKey: AppSettings.Key.mileageRate) == 0.5)
    }

    @Test func aLocalChangeIsUploadedWithTheLastSeenTime() async throws {
        await server.enqueue(200, Self.record(mode: "irs", rate: 0.725))
        await service.sync()

        defaults.set("custom", forKey: AppSettings.Key.rateMode)
        defaults.set(0.55, forKey: AppSettings.Key.mileageRate)
        await server.enqueue(200, Self.record(rate: 0.55, updatedAt: "2026-10-11T11:00:00+00:00"))
        await service.sync()

        let requests = await settingsRequests()
        #expect(requests.map(\.httpMethod) == ["GET", "PUT"])
        let sent = body(requests[1])
        #expect(sent["base_updated_at"] as? String == "2026-10-11T10:00:00+00:00")
        #expect(sent["mileage_rate"] as? Double == 0.55)
        #expect(defaults.string(forKey: SettingsSyncService.baseKey) == "2026-10-11T11:00:00+00:00")
    }

    @Test func aNewerChangeFromAnotherDeviceWinsOverALocalOne() async {
        await server.enqueue(200, Self.record(mode: "irs", rate: 0.725))
        await service.sync()

        defaults.set("custom", forKey: AppSettings.Key.rateMode)
        defaults.set(0.4, forKey: AppSettings.Key.mileageRate)
        await server.enqueue(409, #"{"message":"Settings were changed on another device."}"#)
        await server.enqueue(200, Self.record(mode: "favr", rate: 0.9, updatedAt: "2026-10-11T12:00:00+00:00"))
        await service.sync()

        #expect(await settingsRequests().map(\.httpMethod) == ["GET", "PUT", "GET"])
        #expect(defaults.string(forKey: AppSettings.Key.rateMode) == "favr")
        #expect(defaults.double(forKey: AppSettings.Key.mileageRate) == 0.9)
        #expect(defaults.string(forKey: SettingsSyncService.baseKey) == "2026-10-11T12:00:00+00:00")
    }

    @Test func nothingIsSentWhenSettingsMatchAndTheServerWasJustChecked() async {
        await server.enqueue(200, Self.record())
        await service.sync()
        await service.sync()

        #expect(await settingsRequests().count == 1)
    }

    @Test func aDifferentAccountStartsOverInsteadOfReusingTheSavedTime() async {
        defaults.set("user-1", forKey: SettingsSyncService.userIDKey)
        defaults.set("2026-10-11T10:00:00+00:00", forKey: SettingsSyncService.baseKey)
        await server.enqueue(404, #"{"message":"No settings are saved for this account."}"#)
        await server.enqueue(200, Self.record(updatedAt: "2026-10-12T09:00:00+00:00"))

        service.didSignIn(userID: "user-2")

        // Cleared before anything runs, so the first request is a fresh GET, not a PUT carrying
        // user-1's time.
        #expect(defaults.string(forKey: SettingsSyncService.baseKey) == nil)
        #expect(defaults.string(forKey: SettingsSyncService.userIDKey) == "user-2")
        await service.sync()
        #expect(await settingsRequests().map(\.httpMethod) == ["GET", "PUT"])
        #expect(body(await settingsRequests()[1])["base_updated_at"] == nil)
    }

    @Test func aRateModeThisVersionDoesntKnowLeavesTheDeviceAlone() async {
        defaults.set("custom", forKey: AppSettings.Key.rateMode)
        defaults.set(0.61, forKey: AppSettings.Key.mileageRate)
        await server.enqueue(200, Self.record(mode: "per-diem", rate: 0.9))

        await service.sync()

        #expect(defaults.string(forKey: AppSettings.Key.rateMode) == "custom")
        #expect(defaults.double(forKey: AppSettings.Key.mileageRate) == 0.61)
        #expect(defaults.string(forKey: SettingsSyncService.baseKey) == nil)
    }

    @Test func payloadUsesTheScreensDefaultsForUnsetValues() {
        let payload = SettingsPayload(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        #expect(payload == SettingsPayload(
            countryCode: "US", rateMode: "irs", mileageRate: 0.725,
            favrFixedMonthly: 0, favrPerMile: 0, favrMinMonthlyMiles: 0
        ))
    }
}
