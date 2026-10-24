import StoreKit
import SwiftUI

/// The plans, the free period, and what happens after it. Purchases are Apple in-app purchases.
struct SubscriptionView: View {
    @Environment(SubscriptionManager.self) private var subscriptions: SubscriptionManager?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        // A Teams account buys per-user plans only, so it is never shown the individual ones.
        if subscriptions?.accountType == .team {
            TeamPlansView()
        } else {
            individualPlans
        }
    }

    private var individualPlans: some View {
        List {
            if let subscriptions {
                Section("Your plan") {
                    Text(statusText(subscriptions.state))
                    PendingSwitchNote()
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

                if case .subscribed = subscriptions.state {
                    Section {
                        NavigationLink("Switch to a team plan") { SwitchPlanView(target: .team) }
                    } footer: {
                        Text("For people on a team. You can switch back later.")
                    }
                } else if case .purchased = subscriptions.state {
                    Section {
                        Text("Your pay-once plan can't be switched to a team plan. It runs for its five years.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
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
                    // TODO(remove after debugging): diagnostic text, see SubscriptionManager.entitlementSummary.
                    Text(subscriptions.entitlementSummary + " " + subscriptions.switchSummary).font(.caption2).foregroundStyle(.secondary)
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
    /// Set on the switch screen, after the person has read what switching means.
    var confirmedSwitch = false

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
                } else if let subscriptions {
                    // Shown even before the App Store prices have loaded: tapping loads them
                    // (retrying a failed load) and then buys.
                    Button(buyLabel) {
                        Task {
                            if subscriptions.product(id) == nil { await subscriptions.loadProducts() }
                            if let product = subscriptions.product(id) {
                                await subscriptions.purchase(product, confirmedSwitch: confirmedSwitch)
                            }
                        }
                    }
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
            if let subscriptions, case .subscribed = subscriptions.state {
                Section {
                    PendingSwitchNote()
                    NavigationLink("Switch to an individual plan") { SwitchPlanView(target: .individual) }
                }
            }
            if let subscriptions, case .expired = subscriptions.state {
                Section {
                    Text("Your plan has ended. Your trips stay on this iPhone and can be exported, but new drives aren't recorded until you subscribe.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
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
            if let subscriptions {
                if let message = subscriptions.errorMessage {
                    Section { Text(message).foregroundStyle(.red) }
                }
                Section {
                    Button("Restore Purchases") { Task { await subscriptions.restore() } }
                        .disabled(subscriptions.isWorking)
                    // TODO(remove after debugging): diagnostic text, see SubscriptionManager.entitlementSummary.
                    Text(subscriptions.entitlementSummary + " " + subscriptions.switchSummary).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .brandedBackground()
        .navigationTitle("Team plans")
        .navigationBarTitleDisplayMode(.inline)
        .task { await subscriptions?.loadProducts() }
    }
}

/// "Switching to Team yearly on Nov 3." when the App Store has scheduled a plan change.
private struct PendingSwitchNote: View {
    @Environment(SubscriptionManager.self) private var subscriptions: SubscriptionManager?

    var body: some View {
        if let subscriptions, let id = subscriptions.pendingProductID, let date = subscriptions.pendingSwitchDate {
            let name = subscriptions.product(id)?.displayName ?? "your new plan"
            Text("Switching to \(name) on \(date.formatted(date: .abbreviated, time: .omitted)). Until then your current plan stays active.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

/// Moves a subscriber between Individual and Teams. The warning comes first; the plans can be
/// bought only after it is acknowledged. The App Store, not the app, bills and refunds.
struct SwitchPlanView: View {
    let target: AccountType
    @Environment(SubscriptionManager.self) private var subscriptions: SubscriptionManager?
    @Environment(\.dismiss) private var dismiss
    @State private var acknowledged = false
    @State private var showingManage = false
    @State private var startingType: AccountType?
    @State private var startingPending: String?

    var body: some View {
        List {
            Section {
                Text("You're switching to \(target == .team ? "a team" : "an individual") plan.")
                    .font(.headline)
                Text("Your current subscription is replaced by the new plan, and the App Store decides when: sometimes right away, sometimes at your next renewal. Apple handles the billing and any credit or refund for the time left on your current plan, and Miles Pro Sync can't refund it. Review the details Apple shows before you confirm.")
                if target == .individual {
                    Text("Leaving Teams doesn't remove you from your team. Leave it in Settings → Team if you no longer want to share your Business trips.")
                }
                Toggle("I understand", isOn: $acknowledged)
            } header: {
                Text("Before you switch")
            }

            Section {
                switch target {
                case .team:
                    PlanRow(
                        id: ProductID.teamAnnual, title: "Team yearly", fallbackPrice: "$34.99", per: "/user/year",
                        confirmedSwitch: true
                    )
                    PlanRow(id: ProductID.team, title: "Team monthly", fallbackPrice: "$3.99", per: "/user/month", confirmedSwitch: true)
                case .individual:
                    PlanRow(
                        id: ProductID.individualAnnual, title: "Yearly", fallbackPrice: "$39.99", per: "/year",
                        confirmedSwitch: true
                    )
                    PlanRow(id: ProductID.individual, title: "Monthly", fallbackPrice: "$4.99", per: "/month", confirmedSwitch: true)
                }
            } header: {
                Text("Choose a plan")
            }
            .disabled(!acknowledged)

            if let message = subscriptions?.errorMessage {
                Section { Text(message).foregroundStyle(.red) }
            }

            Section {
                Button("Manage Subscriptions") { showingManage = true }
                Link("Report a Problem or Request a Refund", destination: URL(string: "https://reportaproblem.apple.com")!)
            } footer: {
                Text("Cancel or review your subscription with Apple. Refund requests are decided by Apple.")
            }
        }
        .brandedBackground()
        .navigationTitle("Switch plan")
        .navigationBarTitleDisplayMode(.inline)
        .manageSubscriptionsSheet(isPresented: $showingManage)
        .task {
            await subscriptions?.loadProducts()
            startingType = subscriptions?.accountType
            startingPending = subscriptions?.pendingProductID
        }
        // The switch took effect, or was scheduled for the next renewal.
        .onChange(of: subscriptions?.accountType) { _, new in
            if let startingType, new != startingType { dismiss() }
        }
        .onChange(of: subscriptions?.pendingProductID) { _, new in
            if new != nil, new != startingPending { dismiss() }
        }
    }
}
