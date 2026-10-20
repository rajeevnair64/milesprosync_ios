import Foundation
import Observation
import StoreKit

/// Apple in-app purchase for the subscriptions and the five-year pay-once purchase (StoreKit 2). Purchases are verified on the
/// device by StoreKit; the Team transaction is also sent to the website, which verifies Apple's
/// signature again before unlocking team features.
@Observable
@MainActor
final class SubscriptionManager {
    private(set) var products: [Product] = []
    private(set) var state: AccessState
    /// Individual or Teams; nil until the person chooses (or pays, which decides it).
    private(set) var accountType: AccountType?
    private(set) var isWorking = false
    private(set) var errorMessage: String?
    /// The signed Team transaction currently in force, for the website (nil without a Team plan).
    private(set) var teamTransaction: String?
    /// A plan the subscription will change to at its next renewal (the App Store defers some
    /// switches), and the date it takes over; nil when none is scheduled.
    /// Temporary: what the App Store listed on the last refresh, shown on the plans screen to
    /// diagnose a switch that doesn't show up.
    private(set) var entitlementSummary = ""
    private(set) var switchSummary = ""
    private(set) var pendingProductID: String?
    private(set) var pendingSwitchDate: Date?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var updatesTask: Task<Void, Never>?

    @ObservationIgnored private let trialItem: KeychainItem
    @ObservationIgnored private let appStoreFirstDownload: @Sendable () async -> Date?

    /// The date this Apple ID first got the app, verified by StoreKit; nil when it can't be read
    /// (offline, or no App Store record such as a local debug run).
    nonisolated static func storeKitFirstDownload() async -> Date? {
        guard case .verified(let transaction)? = try? await AppTransaction.shared else { return nil }
        return transaction.originalPurchaseDate
    }

    init(
        defaults: UserDefaults = .standard,
        trialItem: KeychainItem = AccessStore.trialItem,
        appStoreFirstDownload: @escaping @Sendable () async -> Date? = SubscriptionManager.storeKitFirstDownload
    ) {
        self.defaults = defaults
        self.trialItem = trialItem
        self.appStoreFirstDownload = appStoreFirstDownload
        let initial = AccessStore.state(defaults: defaults, item: trialItem)
        state = initial
        accountType = AccountType.resolve(stored: AccessStore.storedAccountType(defaults: defaults), state: initial)
        updatesTask = Task { [weak self] in
            for await update in Transaction.updates {
                await self?.handle(update)
            }
        }
        Task { await refresh() }
    }

    deinit {
        updatesTask?.cancel()
    }

    func product(_ id: String) -> Product? { products.first { $0.id == id } }

    /// The product in force now, so the plans screen can mark it and offer the others.
    var currentProductID: String? { defaults.string(forKey: AccessStore.productKey) }

    /// Premium features a pay-once owner doesn't have yet (empty for everyone else), so the plans
    /// screen can offer the upgrade.
    var lockedFeatures: [PremiumFeature] {
        guard PremiumFeature.upgradeIsOffered(), case .purchased = state else { return [] }
        return PremiumFeature.all.filter { !state.includes($0) }
    }

    /// Whether a premium feature is available now. Until upgrades are offered, everything is.
    func hasAccess(to feature: PremiumFeature) -> Bool {
        !PremiumFeature.upgradeIsOffered() || state.includes(feature)
    }

    func loadProducts() async {
        guard products.count < ProductID.store.count else { return }
        do {
            let loaded = try await Product.products(for: ProductID.store)
            products = loaded.sorted { $0.price > $1.price }
            let missing = ProductID.store.filter { id in !loaded.contains { $0.id == id } }
            errorMessage = if loaded.isEmpty {
                "Plans aren't available from the App Store right now. Try again in a moment.\n\nApp Store returned 0 of \(ProductID.store.count) products. Missing: \(missing.joined(separator: ", "))"
            } else if !missing.isEmpty {
                "Some plans aren't available from the App Store.\n\nReturned: \(loaded.map(\.id).sorted().joined(separator: ", "))\nMissing: \(missing.joined(separator: ", "))"
            } else {
                nil
            }
            await refreshPendingSwitch()
        } catch {
            errorMessage = "Couldn't load subscription options. Check your connection and try again.\n\n\(error.localizedDescription)"
        }
    }

    /// Chooses Individual or Teams. Refused once a plan is paid for, which decides it.
    @discardableResult
    func chooseAccountType(_ type: AccountType) -> Bool {
        guard AccountType.canChange(in: state) else { return false }
        AccessStore.saveAccountType(type, defaults: defaults)
        accountType = type
        return true
    }

    /// `confirmedSwitch` is set once the person has read the switch warning; it lets a subscriber
    /// buy a plan of the other type. The type itself changes only if the purchase succeeds.
    func purchase(_ product: Product, confirmedSwitch: Bool = false) async {
        errorMessage = nil
        // One or the other: a person on Teams buys per-user plans only, an individual the rest.
        // Buying before choosing chooses.
        if let message = accountType?.refusal(forPurchasing: product.id),
           !(confirmedSwitch && AccountType.canSwitch(in: state)) {
            errorMessage = message
            return
        }
        isWorking = true
        defer { isWorking = false }
        do {
            switch try await product.purchase() {
            case .success(let verification):
                await handle(verification)
            case .pending:
                errorMessage = "The purchase is waiting for approval."
            case .userCancelled:
                break
            @unknown default:
                break
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func restore() async {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            try await AppStore.sync()
        } catch {
            errorMessage = "Couldn't restore purchases. Try again in a moment."
        }
        await refresh()
    }

    /// Re-reads what the App Store says is in force and updates the cached state.
    /// `including` is a purchase that just completed: the entitlement list can lag behind it, so it
    /// is counted too.
    func refresh(including purchase: VerificationResult<Transaction>? = nil) async {
        var best: (transaction: Transaction, jws: String)?
        var purchasedAt: Date?
        var upgradedAt: Date?
        var results: [VerificationResult<Transaction>] = []
        for await result in Transaction.currentEntitlements { results.append(result) }
        if let purchase { results.append(purchase) }
        var seen: [String] = []
        for result in results {
            guard case .verified(let transaction) = result, transaction.revocationDate == nil else { continue }
            seen.append("\(transaction.productID.split(separator: ".").suffix(2).joined(separator: ".")) until \(transaction.expirationDate?.formatted(date: .omitted, time: .standard) ?? "-")")
            switch transaction.productID {
            case ProductID.fiveYear:
                // originalPurchaseDate is the same on every device and after a restore. The
                // five years are counted from it by AccessPolicy.
                purchasedAt = transaction.originalPurchaseDate
            case ProductID.fiveYearUpgrade:
                upgradedAt = transaction.originalPurchaseDate
            case let id where ProductID.all.contains(id):
                guard let expires = transaction.expirationDate, expires > .now else { continue }
                // The newest purchase wins: right after a switch the old plan can still be listed.
                if best == nil || transaction.purchaseDate > (best?.transaction.purchaseDate ?? .distantPast) {
                    best = (transaction, result.jwsRepresentation)
                }
            default:
                continue
            }
        }
        let plan = best.flatMap { Plan(productID: $0.transaction.productID) }
        entitlementSummary = "Apple lists: " + (seen.isEmpty ? "nothing" : seen.joined(separator: "; "))
            + ". Using: " + (best.map { $0.transaction.productID.split(separator: ".").suffix(2).joined(separator: ".") } ?? "none")
        AccessStore.saveSubscription(
            until: best?.transaction.expirationDate, plan: plan, productID: best?.transaction.productID,
            defaults: defaults
        )
        AccessStore.savePurchase(
            at: purchasedAt,
            featuresThrough: AccessPolicy.featureCoverage(purchasedAt: purchasedAt, upgradedAt: upgradedAt),
            defaults: defaults
        )
        teamTransaction = plan == .team ? best?.jws : nil
        await adoptAppStoreStart()
        state = AccessStore.state(defaults: defaults, item: trialItem)
        // What was paid for decides the type, and is remembered if the plan later lapses.
        let resolved = AccountType.resolve(stored: AccessStore.storedAccountType(defaults: defaults), state: state)
        if resolved != AccessStore.storedAccountType(defaults: defaults) {
            AccessStore.saveAccountType(resolved, defaults: defaults)
        }
        accountType = resolved
        await refreshPendingSwitch()
    }

    /// Looks for a switch the App Store has scheduled for the next renewal, so the plans screen
    /// can say so instead of still showing the old plan with no explanation.
    func refreshPendingSwitch() async {
        guard let groupID = products.compactMap({ $0.subscription?.subscriptionGroupID }).first else {
            switchSummary = "Switch check: plans not loaded."
            return
        }
        guard let statuses = try? await Product.SubscriptionInfo.status(for: groupID) else {
            switchSummary = "Switch check: status lookup failed."
            return
        }
        switchSummary = "Switch check: " + (statuses.isEmpty ? "no status" : statuses.map { status in
            let renewal = status.renewalInfo.unsafePayloadValue
            let next = renewal.autoRenewPreference?.split(separator: ".").suffix(2).joined(separator: ".") ?? "-"
            return "\(status.state.localizedDescription), renews as \(next)"
        }.joined(separator: "; "))
        var pending: (id: String, date: Date)?
        for status in statuses where status.state == .subscribed {
            guard case .verified(let renewal) = status.renewalInfo,
                  case .verified(let transaction) = status.transaction,
                  transaction.revocationDate == nil,
                  let next = renewal.autoRenewPreference, next != transaction.productID,
                  let expires = transaction.expirationDate, expires > .now else { continue }
            pending = (next, expires)
        }
        pendingProductID = pending?.id
        pendingSwitchDate = pending?.date
    }

    /// Moves the free period's start back to this Apple ID's first download, if that is earlier.
    func adoptAppStoreStart() async {
        AccessStore.adoptAppStoreStart(await appStoreFirstDownload(), item: trialItem)
        state = AccessStore.state(defaults: defaults, item: trialItem)
    }

    private func handle(_ result: VerificationResult<Transaction>) async {
        guard case .verified(let transaction) = result else {
            errorMessage = "The App Store couldn't verify that purchase."
            return
        }
        await transaction.finish()
        await refresh(including: result)
    }
}
