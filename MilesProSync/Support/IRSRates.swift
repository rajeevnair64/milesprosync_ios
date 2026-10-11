import Foundation

/// The IRS standard business mileage rate by year. Someone who hasn't set a rate of their own is
/// paid each trip at the rate for the year it was made, so adding a new year's rate here (or
/// receiving it from the website's `/api/v1/irs-rates`) updates them at year end with nothing for
/// them to do. A rate someone typed in, or FAVR figures, are their own stored values and this
/// table never touches them.
enum IRSRates {
    /// Shipped with the app. The website's table is merged over it (and cached) when reachable.
    static let builtIn: [Int: Double] = [
        2023: 0.655,
        2024: 0.670,
        2025: 0.700,
        2026: 0.725,
    ]

    static let cacheKey = "irsRates.cache"

    /// Built-in table with the cached website table laid over it.
    static func table(defaults: UserDefaults = .standard) -> [Int: Double] {
        var table = builtIn
        if let cached = defaults.dictionary(forKey: cacheKey) as? [String: Double] {
            for (year, rate) in cached {
                if let year = Int(year), isPlausible(rate) { table[year] = rate }
            }
        }
        return table
    }

    /// The rate for `year`. A year after the latest known uses the latest (until its rate is added);
    /// one before the earliest uses the earliest.
    static func rate(forYear year: Int, in table: [Int: Double] = IRSRates.table()) -> Double {
        if let rate = table[year] { return rate }
        guard let first = table.keys.min(), let last = table.keys.max() else { return AppSettings.fallbackIRSRate }
        return year > last ? table[last]! : table[first]!
    }

    static func rate(on date: Date, in table: [Int: Double] = IRSRates.table(), calendar: Calendar = .current) -> Double {
        rate(forYear: calendar.component(.year, from: date), in: table)
    }

    static func isPlausible(_ rate: Double) -> Bool {
        rate.isFinite && rate > 0 && rate < 5
    }

    /// Saves a table received from the website.
    static func cache(_ rates: [Int: Double], defaults: UserDefaults = .standard) {
        let valid = rates.filter { isPlausible($0.value) }
        defaults.set(Dictionary(uniqueKeysWithValues: valid.map { (String($0.key), $0.value) }), forKey: cacheKey)
    }

    /// Decodes the website's `{"rates": {"2026": "0.725", ...}}`.
    static func decode(_ data: Data) -> [Int: Double]? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rates = object["rates"] as? [String: Any] else { return nil }
        var table: [Int: Double] = [:]
        for (year, value) in rates {
            guard let year = Int(year) else { continue }
            let rate = (value as? String).flatMap(Double.init) ?? (value as? Double)
            if let rate, isPlausible(rate) { table[year] = rate }
        }
        return table.isEmpty ? nil : table
    }

    /// Fetches the website's table and caches it. A failure changes nothing.
    static func refresh(baseURL: URL, defaults: UserDefaults = .standard) async {
        var request = URLRequest(url: baseURL.appending(path: "api/v1/irs-rates"))
        request.timeoutInterval = 15
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let table = decode(data) else { return }
        cache(table, defaults: defaults)
    }
}
