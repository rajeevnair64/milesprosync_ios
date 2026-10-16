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
        guard products.isEmpty else { return }
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

    func purchase(_ product: Product) async {
        errorMessage = nil
        // One or the other: a person on Teams buys per-user plans only, an individual the rest.
        // Buying before choosing chooses.
        if let message = accountType?.refusal(forPurchasing: product.id) {
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
    func refresh() async {
        var best: (transaction: Transaction, jws: String)?
        var purchasedAt: Date?
        var upgradedAt: Date?
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result, transaction.revocationDate == nil else { continue }
            switch transaction.productID {
            case ProductID.fiveYear:
                // originalPurchaseDate is the same on every device and after a restore. The
                // five years are counted from it by AccessPolicy.
                purchasedAt = transaction.originalPurchaseDate
            case ProductID.fiveYearUpgrade:
                upgradedAt = transaction.originalPurchaseDate
            case let id where ProductID.all.contains(id):
                guard let expires = transaction.expirationDate, expires > .now else { continue }
                if best == nil || expires > (best?.transaction.expirationDate ?? .distantPast) {
                    best = (transaction, result.jwsRepresentation)
                }
            default:
                continue
            }
        }
        let plan = best.flatMap { Plan(productID: $0.transaction.productID) }
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
        await refresh()
    }
}
