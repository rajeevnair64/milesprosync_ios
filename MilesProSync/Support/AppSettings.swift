import Foundation

/// Global user preferences, persisted in `UserDefaults` and read in views via `@AppStorage`
/// with these keys and defaults.
enum AppSettings {
    enum Key {
        static let countryCode = "settings.countryCode"
        static let mileageRate = "settings.mileageRate"
        static let rateMode = "settings.rateMode"
        static let favrFixedMonthly = "settings.favrFixedMonthly"
        static let favrPerMile = "settings.favrPerMile"
        static let favrMinMonthlyMiles = "settings.favrMinMonthlyMiles"
    }

    /// How trips are paid. IRS is the default: each trip at the IRS rate for its year, updated
    /// automatically. Custom and FAVR are the person's own values and are never changed for them.
    enum RateMode: String, CaseIterable, Identifiable {
        case irs, custom, favr

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .irs: "IRS rate"
            case .custom: "My rate"
            case .favr: "FAVR"
            }
        }
    }

    /// The rate before the IRS table existed (the 2026 IRS rate, the app's old fixed default).
    static let fallbackIRSRate = 0.725

    static let defaultCountryCode = "US"
    /// IRS standard mileage rate for business use in 2026, in dollars per mile.
    static let defaultMileageRate = 0.725

    /// The mode in effect. Before modes existed the app stored only a per-mile rate: a stored rate
    /// other than the old default was the person's own, so it becomes Custom and keeps its value;
    /// no stored rate, or the old default, means they were using the IRS rate. The result is
    /// written, so a later change to the IRS table can't flip anyone between modes.
    @discardableResult
    static func resolveRateMode(defaults: UserDefaults) -> RateMode {
        if let stored = defaults.string(forKey: Key.rateMode), let mode = RateMode(rawValue: stored) { return mode }
        var mode = RateMode.irs
        if defaults.object(forKey: Key.mileageRate) != nil {
            let rate = defaults.double(forKey: Key.mileageRate)
            if abs(rate - defaultMileageRate) > 0.0000_1 { mode = .custom }
        }
        defaults.set(mode.rawValue, forKey: Key.rateMode)
        return mode
    }

    /// The reimbursement rate for the saved mode. `at` picks which year's IRS rate the label shows.
    static func reimbursementRate(
        mode: RateMode, customPerMile: Double, favrFixedMonthly: Double, favrPerMile: Double,
        favrMinMonthlyMiles: Double, countryCode: String, at date: Date = .now,
        table: [Int: Double] = IRSRates.table()
    ) -> ReimbursementRate {
        let symbol = currencySymbol(for: normalizedCountryCode(countryCode))
        switch mode {
        case .irs:
            return ReimbursementRate(perMile: IRSRates.rate(on: date, in: table), currencySymbol: symbol, irsTable: table)
        case .custom:
            return ReimbursementRate(perMile: customPerMile, currencySymbol: symbol)
        case .favr:
            return ReimbursementRate(
                perMile: favrPerMile, currencySymbol: symbol,
                fixedMonthly: favrFixedMonthly, minMonthlyMiles: favrMinMonthlyMiles
            )
        }
    }

    struct Country: Identifiable, Hashable {
        let code: String
        let name: String
        var id: String { code }
    }

    /// The countries the app is set up for. Only the United States for now (the IRS rate and US
    /// reporting); `allCountries` is ready for when more are added.
    static let countries: [Country] = allCountries.filter { $0.code == defaultCountryCode }

    /// A stored country code, or the default if it is one the app isn't set up for (an earlier
    /// version let any country be chosen).
    static func normalizedCountryCode(_ code: String) -> String {
        countries.contains { $0.code == code } ? code : defaultCountryCode
    }

    /// Every ISO country/territory, sorted by its name in the user's language.
    static let allCountries: [Country] = Locale.Region.isoRegions
        .filter { $0.subRegions.isEmpty && $0.identifier.count == 2 && $0.identifier.allSatisfy(\.isLetter) }
        .compactMap { region in
            Locale.current.localizedString(forRegionCode: region.identifier)
                .map { Country(code: region.identifier, name: $0) }
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

    /// "1.0 (2)": marketing version and build number, as shown in Settings → About.
    static func versionText(bundle: Bundle = .main) -> String {
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(version) (\(build))"
    }

    static func countryName(for code: String) -> String {
        Locale.current.localizedString(forRegionCode: code) ?? code
    }

    /// Symbol of the country's local currency, e.g. "$" for US, "£" for GB, "€" for DE.
    static func currencySymbol(for countryCode: String) -> String {
        Locale(identifier: "en_\(countryCode)").currencySymbol ?? "$"
    }

    static func reimbursementRate(perMile: Double, countryCode: String) -> ReimbursementRate {
        ReimbursementRate(perMile: perMile, currencySymbol: currencySymbol(for: countryCode))
    }

    /// Rate as typed/displayed: "0.725", "0.70" — at least two decimals, up to three.
    static func formatRate(_ rate: Double) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.minimumIntegerDigits = 1
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 3
        return formatter.string(from: NSNumber(value: rate)) ?? String(rate)
    }

    /// Parses a typed rate, accepting either "." or "," as the decimal separator (the decimal
    /// keypad shows whichever the device locale uses). Returns nil for anything that isn't a
    /// finite, non-negative number.
    static func parseRate(_ text: String) -> Double? {
        let normalized = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard let value = Double(normalized), value.isFinite, value >= 0 else { return nil }
        return value
    }
}
