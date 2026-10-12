import Foundation

/// The reimbursement settings as stored with the account (`GET`/`PUT /api/v1/settings`, see
/// website/trips/settings_api.py): the `AppSettings` values a second device or the website needs to
/// price trips the same way.
struct SettingsPayload: Codable, Equatable, Sendable {
    var countryCode: String
    var rateMode: String
    var mileageRate: Double
    var favrFixedMonthly: Double
    var favrPerMile: Double
    var favrMinMonthlyMiles: Double

    private enum CodingKeys: String, CodingKey {
        case countryCode = "country_code"
        case rateMode = "rate_mode"
        case mileageRate = "mileage_rate"
        case favrFixedMonthly = "favr_fixed_monthly"
        case favrPerMile = "favr_per_mile"
        case favrMinMonthlyMiles = "favr_min_monthly_miles"
    }

    /// This device's settings, with the same defaults the Settings screens show for unset values.
    init(defaults: UserDefaults) {
        let mode = AppSettings.resolveRateMode(defaults: defaults)
        countryCode = AppSettings.normalizedCountryCode(
            defaults.string(forKey: AppSettings.Key.countryCode) ?? AppSettings.defaultCountryCode
        )
        rateMode = mode.rawValue
        mileageRate = defaults.object(forKey: AppSettings.Key.mileageRate) == nil
            ? AppSettings.defaultMileageRate : defaults.double(forKey: AppSettings.Key.mileageRate)
        favrFixedMonthly = defaults.double(forKey: AppSettings.Key.favrFixedMonthly)
        favrPerMile = defaults.double(forKey: AppSettings.Key.favrPerMile)
        favrMinMonthlyMiles = defaults.double(forKey: AppSettings.Key.favrMinMonthlyMiles)
    }

    init(
        countryCode: String = AppSettings.defaultCountryCode, rateMode: String = AppSettings.RateMode.irs.rawValue,
        mileageRate: Double = AppSettings.defaultMileageRate, favrFixedMonthly: Double = 0,
        favrPerMile: Double = 0, favrMinMonthlyMiles: Double = 0
    ) {
        self.countryCode = countryCode
        self.rateMode = rateMode
        self.mileageRate = mileageRate
        self.favrFixedMonthly = favrFixedMonthly
        self.favrPerMile = favrPerMile
        self.favrMinMonthlyMiles = favrMinMonthlyMiles
    }

    /// Writes these settings to the device. A rate mode this version doesn't know (a newer app
    /// wrote it) leaves the device's settings unchanged.
    @discardableResult
    func apply(to defaults: UserDefaults) -> Bool {
        guard AppSettings.RateMode(rawValue: rateMode) != nil else { return false }
        defaults.set(AppSettings.normalizedCountryCode(countryCode), forKey: AppSettings.Key.countryCode)
        defaults.set(rateMode, forKey: AppSettings.Key.rateMode)
        defaults.set(mileageRate, forKey: AppSettings.Key.mileageRate)
        defaults.set(favrFixedMonthly, forKey: AppSettings.Key.favrFixedMonthly)
        defaults.set(favrPerMile, forKey: AppSettings.Key.favrPerMile)
        defaults.set(favrMinMonthlyMiles, forKey: AppSettings.Key.favrMinMonthlyMiles)
        return true
    }
}

/// What the server answers: the settings plus the time they were saved. `updatedAt` is kept as the
/// server's own string and sent back unchanged as `base_updated_at`.
struct SettingsRecord: Decodable, Equatable, Sendable {
    let settings: SettingsPayload
    let updatedAt: String

    private enum CodingKeys: String, CodingKey {
        case updatedAt = "updated_at"
    }

    init(settings: SettingsPayload, updatedAt: String) {
        self.settings = settings
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        settings = try SettingsPayload(from: decoder)
        updatedAt = try decoder.container(keyedBy: CodingKeys.self).decode(String.self, forKey: .updatedAt)
    }
}

private struct SettingsRequest: Encodable {
    let settings: SettingsPayload
    let baseUpdatedAt: String?

    private enum CodingKeys: String, CodingKey {
        case baseUpdatedAt = "base_updated_at"
    }

    func encode(to encoder: Encoder) throws {
        try settings.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(baseUpdatedAt, forKey: .baseUpdatedAt)
    }
}

extension APIClient {
    /// The account's saved settings, or nil if none were saved yet (404).
    func fetchSettings() async throws -> SettingsRecord? {
        do {
            return try decodeSettings(await authorized("GET", path: "settings"))
        } catch SyncError.server(status: 404, _) {
            return nil
        }
    }

    /// Replaces the saved settings. `baseUpdatedAt` is the `updatedAt` this device last saw (nil for
    /// the first save); throws `SyncError.server(status: 409, ...)` if the server's are newer.
    func saveSettings(_ settings: SettingsPayload, baseUpdatedAt: String?) async throws -> SettingsRecord {
        let body = SettingsRequest(settings: settings, baseUpdatedAt: baseUpdatedAt)
        return try decodeSettings(await authorized("PUT", path: "settings", body: body))
    }

    private func decodeSettings(_ data: Data) throws -> SettingsRecord {
        guard let record = try? JSONDecoder().decode(SettingsRecord.self, from: data) else {
            throw SyncError.invalidResponse
        }
        return record
    }
}
