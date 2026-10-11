import Foundation
import Observation
import StoreKit

/// Apple in-app purchase for the two subscriptions (StoreKit 2). Purchases are verified on the
/// device by StoreKit; the Team transaction is also sent to the website, which verifies Apple's
/// signature again before unlocking team features.
@Observable
@MainActor
final class SubscriptionManager {
    private(set) var products: [Product] = []
    private(set) var state: AccessState
    private(set) var isWorking = false
    private(set) var errorMessage: String?
    /// The signed Team transaction currently in force, for the website (nil without a Team plan).
    private(set) var teamTransaction: String?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var updatesTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        state = AccessStore.state(defaults: defaults)
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

    func loadProducts() async {
        guard products.isEmpty else { return }
        do {
            products = try await Product.products(for: ProductID.all)
                .sorted { $0.price > $1.price }
        } catch {
            errorMessage = "Couldn't load subscription options. Check your connection and try again."
        }
    }

    func purchase(_ product: Product) async {
        isWorking = true
        errorMessage = nil
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
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result,
                  ProductID.all.contains(transaction.productID),
                  transaction.revocationDate == nil,
                  let expires = transaction.expirationDate, expires > .now else { continue }
            if best == nil || expires > (best?.transaction.expirationDate ?? .distantPast) {
                best = (transaction, result.jwsRepresentation)
            }
        }
        let plan = best.flatMap { Plan(productID: $0.transaction.productID) }
        AccessStore.saveSubscription(
            until: best?.transaction.expirationDate, plan: plan, productID: best?.transaction.productID,
            defaults: defaults
        )
        teamTransaction = plan == .team ? best?.jws : nil
        state = AccessStore.state(defaults: defaults)
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
