import Foundation

/// The subscriptions, all in one App Store subscription group so a person has at most one.
enum ProductID {
    /// Single user, not on a team: $4.99/month after the two free months.
    static let individual = "com.aisleweb.MilesProSync.individual.monthly"
    /// The same plan billed yearly: $39.99/year.
    static let individualAnnual = "com.aisleweb.MilesProSync.individual.annual"
    /// Per user on a team: $3.99/month, unlimited trips (the server checks the team products).
    static let team = "com.aisleweb.MilesProSync.team.monthly"
    /// The team plan billed yearly: $39.99/user/year.
    static let teamAnnual = "com.aisleweb.MilesProSync.team.annual"
    static let all = [individual, individualAnnual, team, teamAnnual]
    static let teamPlans = [team, teamAnnual]
}

enum Plan: String, Equatable, Sendable {
    case individual
    case team

    init?(productID: String) {
        switch productID {
        case ProductID.individual, ProductID.individualAnnual: self = .individual
        case ProductID.team, ProductID.teamAnnual: self = .team
        default: return nil
        }
    }

    var displayName: String {
        switch self {
        case .individual: "Individual"
        case .team: "Team"
        }
    }
}

enum AccessState: Equatable, Sendable {
    /// The free period for a new user: every feature, two months from first launch.
    case trial(endsAt: Date)
    case subscribed(Plan?)
    /// Free period over and no subscription: existing trips stay viewable and exportable, but no
    /// new drives are recorded.
    case expired

    var allowsRecording: Bool {
        if case .expired = self { return false }
        return true
    }
}

/// Free for two months, then a subscription. A pure function of its inputs so it can be tested
/// and read when iOS relaunches the app in the background.
enum AccessPolicy {
    static let trialMonths = 2

    static func trialEnd(from start: Date, calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: .month, value: trialMonths, to: start) ?? start.addingTimeInterval(61 * 86_400)
    }

    static func state(
        trialStart: Date, subscribedUntil: Date?, plan: Plan?, now: Date = .now, calendar: Calendar = .current
    ) -> AccessState {
        if let subscribedUntil, subscribedUntil > now { return .subscribed(plan) }
        let end = trialEnd(from: trialStart, calendar: calendar)
        return now < end ? .trial(endsAt: end) : .expired
    }
}

/// Where the free period's start and the last known subscription are kept. The start is in the
/// Keychain (like the account), so deleting and reinstalling the app doesn't restart it.
enum AccessStore {
    static let trialItem = KeychainItem(service: "com.aisleweb.MilesProSync.trial", account: "start")
    static let subscribedUntilKey = "access.subscribedUntil"
    static let planKey = "access.plan"
    static let productKey = "access.product"

    /// The first-launch date, recorded now if this is the first time anyone asked.
    static func trialStart(now: Date = .now, item: KeychainItem = trialItem) -> Date {
        if let data = item.read(), let text = String(data: data, encoding: .utf8),
           let seconds = TimeInterval(text) {
            return Date(timeIntervalSince1970: seconds)
        }
        item.write(Data(String(now.timeIntervalSince1970).utf8))
        return now
    }

    static func state(now: Date = .now, defaults: UserDefaults = .standard, item: KeychainItem = trialItem) -> AccessState {
        let until = defaults.object(forKey: subscribedUntilKey) as? Date
        let plan = defaults.string(forKey: planKey).flatMap(Plan.init(rawValue:))
        return AccessPolicy.state(
            trialStart: trialStart(now: now, item: item), subscribedUntil: until, plan: plan, now: now
        )
    }

    static func isRecordingAllowed(now: Date = .now, defaults: UserDefaults = .standard) -> Bool {
        state(now: now, defaults: defaults).allowsRecording
    }

    static func saveSubscription(
        until: Date?, plan: Plan?, productID: String? = nil, defaults: UserDefaults = .standard
    ) {
        defaults.set(until, forKey: subscribedUntilKey)
        defaults.set(plan?.rawValue, forKey: planKey)
        defaults.set(productID, forKey: productKey)
    }
}
