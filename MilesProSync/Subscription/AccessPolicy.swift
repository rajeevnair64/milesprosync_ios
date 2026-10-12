import Foundation

/// The subscriptions, all in one App Store subscription group so a person has at most one.
enum ProductID {
    /// Single user, not on a team: $4.99/month after the two free months.
    static let individual = "com.aisleweb.MilesProSync.individual.monthly"
    /// The same plan billed yearly: $39.99/year.
    static let individualAnnual = "com.aisleweb.MilesProSync.individual.annual"
    /// Per user on a team: $3.99/month, unlimited trips (the server checks the team products).
    static let team = "com.aisleweb.MilesProSync.team.monthly"
    /// The team plan billed yearly: $34.99/user/year.
    static let teamAnnual = "com.aisleweb.MilesProSync.team.annual"
    static let all = [individual, individualAnnual, team, teamAnnual]
    static let teamPlans = [team, teamAnnual]

    /// Pay once, individual use only: $109.99 for five years (`AccessPolicy.purchaseYears`), no
    /// renewals. Create it in App Store Connect as a non-renewing subscription (the app counts
    /// the five years from the purchase date). Covers every feature released up to that date.
    static let fiveYear = "com.aisleweb.MilesProSync.individual.fiveyear"
    /// A later one-time upgrade (non-consumable) that adds the premium features released since
    /// the purchase. Its price is set in App Store Connect.
    static let fiveYearUpgrade = "com.aisleweb.MilesProSync.individual.fiveyear.upgrade"
    static let oneTime = [fiveYear, fiveYearUpgrade]
    /// Everything the plans screen asks the App Store about.
    static let store = all + oneTime
}

/// A feature that is part of the paid product but not of an older pay-once purchase. A pay-once
/// owner has the features released on or before their purchase (or upgrade) date; anything
/// released later is unlocked by the upgrade or by subscribing. Subscribers and people in the
/// free period have every feature. Add an entry here when shipping a feature that pay-once
/// owners should upgrade for; features not listed are available to everyone.
struct PremiumFeature: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let releasedAt: Date

    static let all: [PremiumFeature] = []

    /// Upgrades stay hidden, and no feature is gated, until this many premium features exist.
    static let featuresNeededToOffer = 2

    static func upgradeIsOffered(among features: [PremiumFeature] = all) -> Bool {
        features.count >= featuresNeededToOffer
    }
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

/// What the person uses the app as: one person paying for themselves, or a member of a team.
/// Never both. What they have paid for decides it; before they pay it is their own choice.
enum AccountType: String, CaseIterable, Equatable, Sendable {
    case individual
    case team

    var displayName: String {
        switch self {
        case .individual: "Individual"
        case .team: "Teams"
        }
    }

    /// The type a payment implies (a team plan means Teams; another plan or a pay-once purchase
    /// means Individual), otherwise the stored choice, which may be nil (not chosen yet).
    static func resolve(stored: AccountType?, state: AccessState) -> AccountType? {
        switch state {
        case .subscribed(let plan?): plan == .team ? .team : .individual
        case .purchased: .individual
        case .subscribed(nil), .trial, .expired: stored
        }
    }

    /// Whether this type may buy `productID`: Individual has the monthly, yearly and pay-once
    /// products; Teams has the per-user products.
    func allows(productID: String) -> Bool {
        switch self {
        case .individual: ProductID.store.contains(productID) && !ProductID.teamPlans.contains(productID)
        case .team: ProductID.teamPlans.contains(productID)
        }
    }

    /// Why this type may not buy `productID`, shown to the person; nil when it may.
    func refusal(forPurchasing productID: String) -> String? {
        guard !allows(productID: productID) else { return nil }
        return switch self {
        case .team: "You're set up as Teams. Per-user team plans are the only plans for a team."
        case .individual: "You're set up as Individual. Team plans are for teams: switch to Teams first."
        }
    }

    /// The type can be changed only while nothing is paid for; a paid plan pins it.
    static func canChange(in state: AccessState) -> Bool {
        switch state {
        case .trial, .expired: true
        case .subscribed, .purchased: false
        }
    }
}

enum AccessState: Equatable, Sendable {
    /// The free period for a new user: every feature, two months from first launch.
    case trial(endsAt: Date)
    case subscribed(Plan?)
    /// Bought once: everything for five years from the purchase (`endsAt`), including every
    /// feature released on or before `featuresThrough` (see `PremiumFeature`). After `endsAt`
    /// the state is `.expired`, like a lapsed subscription.
    case purchased(featuresThrough: Date, endsAt: Date)
    /// Free period over and no subscription: existing trips stay viewable and exportable, but no
    /// new drives are recorded.
    case expired

    var allowsRecording: Bool {
        if case .expired = self { return false }
        return true
    }

    /// Whether a premium feature is available in this state.
    func includes(_ feature: PremiumFeature) -> Bool {
        switch self {
        case .trial, .subscribed: true
        case .purchased(let featuresThrough, _): feature.releasedAt <= featuresThrough
        case .expired: false
        }
    }
}

/// Free for two months, then a subscription. A pure function of its inputs so it can be tested
/// and read when iOS relaunches the app in the background.
enum AccessPolicy {
    static let trialMonths = 2

    static func trialEnd(from start: Date, calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: .month, value: trialMonths, to: start) ?? start.addingTimeInterval(61 * 86_400)
    }

    /// How long a pay-once purchase lasts.
    static let purchaseYears = 5

    static func purchaseEnd(from purchasedAt: Date, calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: .year, value: purchaseYears, to: purchasedAt)
            ?? purchasedAt.addingTimeInterval(Double(purchaseYears) * 365 * 86_400)
    }

    /// The date a pay-once owner's features run through: the purchase, or the later upgrade.
    /// Nil without a purchase (an upgrade alone unlocks nothing). The upgrade adds features, not time.
    static func featureCoverage(purchasedAt: Date?, upgradedAt: Date?) -> Date? {
        guard let purchasedAt else { return nil }
        return max(purchasedAt, upgradedAt ?? purchasedAt)
    }

    /// An active subscription has everything; a pay-once purchase has everything for five years;
    /// otherwise the free period, then expired.
    static func state(
        trialStart: Date, subscribedUntil: Date?, plan: Plan?,
        purchasedAt: Date? = nil, featuresThrough: Date? = nil,
        now: Date = .now, calendar: Calendar = .current
    ) -> AccessState {
        if let subscribedUntil, subscribedUntil > now { return .subscribed(plan) }
        if let purchasedAt {
            let end = purchaseEnd(from: purchasedAt, calendar: calendar)
            if now < end { return .purchased(featuresThrough: featuresThrough ?? purchasedAt, endsAt: end) }
        }
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
    static let purchasedAtKey = "access.purchasedAt"
    static let featuresThroughKey = "access.featuresThrough"
    static let accountTypeKey = "access.accountType"
    static let accountTypePromptedKey = "access.accountTypePrompted"

    static func storedAccountType(defaults: UserDefaults = .standard) -> AccountType? {
        defaults.string(forKey: accountTypeKey).flatMap(AccountType.init(rawValue:))
    }

    static func saveAccountType(_ type: AccountType?, defaults: UserDefaults = .standard) {
        defaults.set(type?.rawValue, forKey: accountTypeKey)
    }

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
        let purchasedAt = defaults.object(forKey: purchasedAtKey) as? Date
        let featuresThrough = defaults.object(forKey: featuresThroughKey) as? Date
        return AccessPolicy.state(
            trialStart: trialStart(now: now, item: item), subscribedUntil: until, plan: plan,
            purchasedAt: purchasedAt, featuresThrough: featuresThrough, now: now
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

    /// The cached pay-once purchase (nil when there isn't one).
    static func savePurchase(at purchasedAt: Date?, featuresThrough: Date?, defaults: UserDefaults = .standard) {
        defaults.set(purchasedAt, forKey: purchasedAtKey)
        defaults.set(featuresThrough, forKey: featuresThroughKey)
    }
}
