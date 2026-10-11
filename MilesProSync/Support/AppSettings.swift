import Foundation

/// Global user preferences, persisted in `UserDefaults` and read in views via `@AppStorage`
/// with these keys and defaults.
enum AppSettings {
    enum Key {
        static let countryCode = "settings.countryCode"
        static let mileageRate = "settings.mileageRate"
    }

    static let defaultCountryCode = "US"
    /// IRS standard mileage rate for business use in 2026, in dollars per mile.
    static let defaultMileageRate = 0.725

    struct Country: Identifiable, Hashable {
        let code: String
        let name: String
        var id: String { code }
    }

    /// Every ISO country/territory, sorted by its name in the user's language.
    static let countries: [Country] = Locale.Region.isoRegions
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
