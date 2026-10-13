import StoreKit
import SwiftUI

/// The plans, the free period, and what happens after it. Purchases are Apple in-app purchases.
struct SubscriptionView: View {
    @Environment(SubscriptionManager.self) private var subscriptions: SubscriptionManager?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            if let subscriptions {
                Section("Your plan") {
                    Text(statusText(subscriptions.state))
                    if case .expired = subscriptions.state {
                        Text("Your trips stay on this iPhone and can be exported, but new drives aren't recorded until you subscribe.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    PlanRow(
                        id: ProductID.individualAnnual, title: "Yearly", fallbackPrice: "$39.99", per: "/year",
                        badge: "Best value",
                        detail: perMonth(subscriptions, id: ProductID.individualAnnual, fallback: "$3.33")
                            + " " + savings(subscriptions, monthly: ProductID.individual, annual: ProductID.individualAnnual)
                    )
                    PlanRow(id: ProductID.individual, title: "Monthly", fallbackPrice: "$4.99", per: "/month")
                    PlanRow(
                        id: ProductID.fiveYear, title: "Pay once", fallbackPrice: "$109.99", per: " for 5 years",
                        detail: PremiumFeature.upgradeIsOffered()
                            ? "For one person, not for teams. No renewals. Includes 5 years of recording, website sync and updates. Features added later may be offered as a one-time upgrade, or are included with a subscription."
                            : "For one person, not for teams. No renewals. Includes 5 years of recording, website sync and updates.",
                        buyLabel: "Buy"
                    )
                } header: {
                    Text("Choose a plan")
                } footer: {
                    Text("The first day is free. Subscriptions are charged to your Apple ID at confirmation of purchase and renew each month or year until cancelled at least 24 hours before the end of the current period. Manage or cancel in your Apple ID account settings. The pay-once purchase is charged once, lasts five years from the purchase date, and is restored with Restore Purchases. Switching between subscriptions is handled by the App Store.")
                }

                if case .purchased = subscriptions.state, !subscriptions.lockedFeatures.isEmpty {
                    Section("Upgrade") {
                        Text("New since you bought: \(subscriptions.lockedFeatures.map(\.name).formatted()).")
                        if let upgrade = subscriptions.product(ProductID.fiveYearUpgrade) {
                            Button("Upgrade for \(upgrade.displayPrice)") { Task { await subscriptions.purchase(upgrade) } }
                                .buttonStyle(.borderedProminent)
                                .disabled(subscriptions.isWorking)
                        }
                    }
                }

                if let message = subscriptions.errorMessage {
                    Section { Text(message).foregroundStyle(.red) }
                }

                Section {
                    Button("Restore Purchases") { Task { await subscriptions.restore() } }
                        .disabled(subscriptions.isWorking)
                    Link("Terms of Use", destination: URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!)
                    NavigationLink("Privacy Policy") { PrivacyPolicyView() }
                }
            } else {
                Text("Subscriptions aren't available right now.")
            }
        }
        .brandedBackground()
        .navigationTitle("Subscription")
        .navigationBarTitleDisplayMode(.inline)
        .task { await subscriptions?.loadProducts() }
    }

}

/// "About $3.33 a month." from the loaded yearly price.
@MainActor
private func perMonth(_ subscriptions: SubscriptionManager, id: String, fallback: String) -> String {
    guard let product = subscriptions.product(id) else { return "About \(fallback) a month." }
    let monthly = (product.price / 12).formatted(product.priceFormatStyle)
    return "About \(monthly) a month."
}

/// "Save 33% compared with monthly." when both prices are loaded from the App Store.
@MainActor
private func savings(_ subscriptions: SubscriptionManager, monthly: String, annual: String) -> String {
    guard let month = subscriptions.product(monthly)?.price, let year = subscriptions.product(annual)?.price,
          month > 0 else { return "" }
    let full = month * 12
    guard year < full else { return "" }
    let percent = NSDecimalNumber(decimal: (full - year) / full * 100).intValue
    return percent > 0 ? "Save \(percent)% compared with monthly." : ""
}

extension SubscriptionView {
    private func statusText(_ state: AccessState) -> String {
        switch state {
        case .trial(let end):
            "Free trial, ends \(end.formatted(date: .abbreviated, time: .omitted))."
        case .subscribed(let plan):
            "Subscribed\(plan.map { " to \($0.displayName)" } ?? "")."
        case .purchased(_, let end):
            "Pay-once plan, active until \(end.formatted(date: .abbreviated, time: .omitted))."
        case .expired:
            "Your plan has ended."
        }
    }
}

/// One purchasable option: its price, a short description, and a Subscribe/Buy button (or a
/// "Current" mark when it is the plan in force).
private struct PlanRow: View {
    @Environment(SubscriptionManager.self) private var subscriptions: SubscriptionManager?
    let id: String
    let title: String
    let fallbackPrice: String
    let per: String
    var badge: String?
    var detail: String?
    var buyLabel = "Subscribe"

    var body: some View {
        let product = subscriptions?.product(id)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(title).font(.headline)
                        if let badge {
                            Text(badge)
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.green.opacity(0.2), in: Capsule())
                                .foregroundStyle(.green)
                        }
                    }
                    Text("\(product?.displayPrice ?? fallbackPrice)\(per)")
                }
                Spacer()
                if isCurrent {
                    Label("Current", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else if let product, let subscriptions {
                    Button(buyLabel) { Task { await subscriptions.purchase(product) } }
                        .buttonStyle(.borderedProminent)
                        .disabled(subscriptions.isWorking)
                }
            }
            if let detail, !detail.isEmpty {
                Text(detail).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var isCurrent: Bool {
        guard let subscriptions else { return false }
        if id == ProductID.fiveYear, case .purchased = subscriptions.state { return true }
        if case .subscribed = subscriptions.state { return subscriptions.currentProductID == id }
        return false
    }
}

/// The per-user team plans: all a Teams account is offered.
struct TeamPlansView: View {
    @Environment(SubscriptionManager.self) private var subscriptions: SubscriptionManager?

    var body: some View {
        List {
            Section {
                PlanRow(
                    id: ProductID.teamAnnual, title: "Team yearly", fallbackPrice: "$34.99", per: "/user/year",
                    badge: "Best value",
                    detail: subscriptions.map { savings($0, monthly: ProductID.team, annual: ProductID.teamAnnual) }
                )
                PlanRow(id: ProductID.team, title: "Team monthly", fallbackPrice: "$3.99", per: "/user/month")
            } header: {
                Text("Per user")
            } footer: {
                Text("For people on a team. Unlimited trips, team reports and approvals. Only your Business trips are ever shared with a team. Subscriptions renew each month or year until cancelled at least 24 hours before the end of the current period; manage or cancel in your Apple ID account settings.")
            }
        }
        .brandedBackground()
        .navigationTitle("Team plans")
        .navigationBarTitleDisplayMode(.inline)
        .task { await subscriptions?.loadProducts() }
    }
}
