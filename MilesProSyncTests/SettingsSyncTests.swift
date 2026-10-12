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

    // MARK: - Watching for changes

    /// Polls until `condition` holds, up to `seconds`.
    private func wait(upTo seconds: Double = 6, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return await condition()
    }

    @Test func aSettingChangedOnTheDeviceIsUploadedByItself() async throws {
        await server.enqueue(200, Self.record(mode: "irs", rate: 0.725))
        await service.sync()
        service.start()
        defer { service.stop() }

        // What the Reimbursement screen does: write the key in this account's defaults.
        await server.enqueue(200, Self.record(rate: 0.58, updatedAt: "2026-10-11T11:00:00+00:00"))
        defaults.set("custom", forKey: AppSettings.Key.rateMode)
        defaults.set(0.58, forKey: AppSettings.Key.mileageRate)

        let uploaded = await wait { await settingsRequests().contains { $0.httpMethod == "PUT" } }
        #expect(uploaded)
        let put = try #require(await settingsRequests().first { $0.httpMethod == "PUT" })
        #expect(body(put)["rate_mode"] as? String == "custom")
        #expect(body(put)["mileage_rate"] as? Double == 0.58)
        #expect(body(put)["base_updated_at"] as? String == "2026-10-11T10:00:00+00:00")
        // A burst of edits went up as one request.
        #expect(await settingsRequests().filter { $0.httpMethod == "PUT" }.count == 1)
    }

    @Test func nothingIsUploadedWhileSignedOut() async throws {
        let client = APIClient(
            config: SyncFixtures.config, tokenStore: InMemoryTokenStore(SyncFixtures.session()),
            transport: server.transport
        )
        let signedOut = SettingsSyncService(client: client, defaults: defaults, isSignedIn: { false })
        signedOut.start()
        defer { signedOut.stop() }

        defaults.set("custom", forKey: AppSettings.Key.rateMode)
        defaults.set(0.58, forKey: AppSettings.Key.mileageRate)
        try await Task.sleep(for: .seconds(3))

        #expect(await settingsRequests().isEmpty)
    }

    // MARK: - Status indicator

    private var isSynced: Bool {
        if case .synced = service.status { true } else { false }
    }

    @Test func statusStaysIdleForAPlainDownload() async {
        await server.enqueue(200, Self.record(mode: "favr", rate: 0.5, favrFixed: 300))
        await service.sync()
        #expect(service.status == .idle)
    }

    @Test func statusShowsSyncedAfterAChangeIsUploaded() async {
        await server.enqueue(200, Self.record(mode: "irs", rate: 0.725))
        await service.sync()
        defaults.set("custom", forKey: AppSettings.Key.rateMode)
        defaults.set(0.55, forKey: AppSettings.Key.mileageRate)
        await server.enqueue(200, Self.record(rate: 0.55, updatedAt: "2026-10-11T11:00:00+00:00"))

        await service.sync()

        #expect(isSynced)
    }

    @Test func statusShowsFailedThenSyncedOnTheRetry() async {
        await server.enqueue(200, Self.record(mode: "irs", rate: 0.725))
        await service.sync()
        defaults.set("custom", forKey: AppSettings.Key.rateMode)
        defaults.set(0.55, forKey: AppSettings.Key.mileageRate)
        await server.enqueue(500, #"{"message":"Server error"}"#)
        await service.sync()
        #expect(service.status == .failed)

        await server.enqueue(200, Self.record(rate: 0.55, updatedAt: "2026-10-11T11:00:00+00:00"))
        await service.sync()
        #expect(isSynced)
    }

    @Test func statusGoesPendingWhenASettingChangesThenSynced() async throws {
        await server.enqueue(200, Self.record(mode: "irs", rate: 0.725))
        await service.sync()
        service.start()
        defer { service.stop() }

        await server.enqueue(200, Self.record(rate: 0.58, updatedAt: "2026-10-11T11:00:00+00:00"))
        defaults.set("custom", forKey: AppSettings.Key.rateMode)
        defaults.set(0.58, forKey: AppSettings.Key.mileageRate)
        // The notification is delivered on the next main-queue turn.
        let pending = await wait(upTo: 1) { service.status == .pending }
        #expect(pending)

        let synced = await wait { isSynced }
        #expect(synced)
    }

    @Test func statusIsClearedOnSignOut() async {
        await server.enqueue(200, Self.record(mode: "irs", rate: 0.725))
        await service.sync()
        defaults.set(0.55, forKey: AppSettings.Key.mileageRate)
        defaults.set("custom", forKey: AppSettings.Key.rateMode)
        await server.enqueue(200, Self.record(rate: 0.55, updatedAt: "2026-10-11T11:00:00+00:00"))
        await service.sync()
        #expect(isSynced)

        service.didSignOut()

        #expect(service.status == .idle)
    }
}


extension SettingsSyncTests {
    @Test func editDuringUploadIsPreservedAndUploadedWithNewServerTime() async throws {
        await server.enqueue(200, Self.record(rate: 0.5))
        await service.sync()
        defaults.set(0.6, forKey: AppSettings.Key.mileageRate)
        let change: @MainActor @Sendable () -> Void = {
            self.defaults.set(0.7, forKey: AppSettings.Key.mileageRate)
        }
        await server.setOnRequest { _ in await change() }
        await server.enqueue(200, Self.record(rate: 0.6, updatedAt: "version-2"))
        await server.enqueue(200, Self.record(rate: 0.7, updatedAt: "version-3"))

        await service.sync()

        let puts = await settingsRequests().filter { $0.httpMethod == "PUT" }
        #expect(puts.count == 2)
        let latest = try #require(puts.last)
        #expect(body(latest)["mileage_rate"] as? Double == 0.7)
        #expect(body(latest)["base_updated_at"] as? String == "version-2")
        #expect(defaults.double(forKey: AppSettings.Key.mileageRate) == 0.7)
        #expect(defaults.string(forKey: SettingsSyncService.baseKey) == "version-3")
        #expect(isSynced)
    }

    @Test func failedFollowUpUploadKeepsNewerEditForRetry() async throws {
        await server.enqueue(200, Self.record(rate: 0.5))
        await service.sync()
        defaults.set(0.6, forKey: AppSettings.Key.mileageRate)
        let change: @MainActor @Sendable () -> Void = {
            self.defaults.set(0.7, forKey: AppSettings.Key.mileageRate)
        }
        await server.setOnRequest { _ in await change() }
        await server.enqueue(200, Self.record(rate: 0.6, updatedAt: "version-2"))
        await server.enqueue(500)

        await service.sync()

        #expect(defaults.double(forKey: AppSettings.Key.mileageRate) == 0.7)
        #expect(service.status == .failed)
        #expect(defaults.string(forKey: SettingsSyncService.baseKey) == "version-2")
        await server.enqueue(200, Self.record(rate: 0.7, updatedAt: "version-3"))
        await service.sync()
        #expect(isSynced)
        #expect(body(try #require(await settingsRequests().last))["mileage_rate"] as? Double == 0.7)
    }

    @Test func editDuringInitialDownloadIsPreservedAndUploaded() async throws {
        defaults.set("custom", forKey: AppSettings.Key.rateMode)
        defaults.set(0.5, forKey: AppSettings.Key.mileageRate)
        let change: @MainActor @Sendable () -> Void = {
            self.defaults.set(0.7, forKey: AppSettings.Key.mileageRate)
        }
        await server.setOnRequest { _ in await change() }
        await server.enqueue(200, Self.record(rate: 0.6, updatedAt: "version-2"))
        await server.enqueue(200, Self.record(rate: 0.7, updatedAt: "version-3"))

        await service.sync()

        let requests = await settingsRequests()
        #expect(requests.map(\.httpMethod) == ["GET", "PUT"])
        let put = try #require(requests.last)
        #expect(body(put)["base_updated_at"] as? String == "version-2")
        #expect(body(put)["mileage_rate"] as? Double == 0.7)
        #expect(defaults.double(forKey: AppSettings.Key.mileageRate) == 0.7)
        #expect(isSynced)
    }
}
