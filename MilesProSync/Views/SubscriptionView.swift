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
                    plan(
                        subscriptions, title: "Individual",
                        blurb: "For one person. The first two months are free.",
                        monthly: (ProductID.individual, "$4.99"), annual: (ProductID.individualAnnual, "$39.99")
                    )
                    plan(
                        subscriptions, title: "Team",
                        blurb: "Per user, for people on a team. Unlimited trips, team reports and approvals.",
                        monthly: (ProductID.team, "$3.99"), annual: (ProductID.teamAnnual, "$39.99")
                    )
                } header: {
                    Text("Plans")
                } footer: {
                    Text("Payment is charged to your Apple ID account at confirmation of purchase. Subscriptions renew each month or year until cancelled at least 24 hours before the end of the current period. Manage or cancel in your Apple ID account settings. Switching between plans is handled by the App Store.")
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
        .navigationTitle("Subscription")
        .navigationBarTitleDisplayMode(.inline)
        .task { await subscriptions?.loadProducts() }
    }

    @ViewBuilder
    private func plan(
        _ subscriptions: SubscriptionManager, title: String, blurb: String,
        monthly: (id: String, fallbackPrice: String), annual: (id: String, fallbackPrice: String)
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            Text(blurb).font(.footnote).foregroundStyle(.secondary)
            option(subscriptions, id: monthly.id, label: "Monthly", fallbackPrice: monthly.fallbackPrice, per: "month")
            option(
                subscriptions, id: annual.id, label: "Yearly", fallbackPrice: annual.fallbackPrice, per: "year",
                savings: savings(subscriptions, monthly: monthly.id, annual: annual.id)
            )
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func option(
        _ subscriptions: SubscriptionManager, id: String, label: String, fallbackPrice: String, per: String,
        savings: String? = nil
    ) -> some View {
        let product = subscriptions.product(id)
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(label): \(product?.displayPrice ?? fallbackPrice)/\(per)")
                if let savings {
                    Text(savings).font(.caption).foregroundStyle(.green)
                }
            }
            Spacer()
            if subscriptions.currentProductID == id, case .subscribed = subscriptions.state {
                Label("Current", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else if let product {
                Button("Subscribe") { Task { await subscriptions.purchase(product) } }
                    .buttonStyle(.borderedProminent)
                    .disabled(subscriptions.isWorking)
            }
        }
    }

    /// "Save 33%" when both prices are loaded from the App Store.
    private func savings(_ subscriptions: SubscriptionManager, monthly: String, annual: String) -> String? {
        guard let month = subscriptions.product(monthly)?.price, let year = subscriptions.product(annual)?.price,
              month > 0 else { return nil }
        let full = month * 12
        guard year < full else { return nil }
        let percent = NSDecimalNumber(decimal: (full - year) / full * 100).intValue
        return percent > 0 ? "Save \(percent)% compared with monthly" : nil
    }

    private func statusText(_ state: AccessState) -> String {
        switch state {
        case .trial(let end):
            "Free trial, ends \(end.formatted(date: .abbreviated, time: .omitted))."
        case .subscribed(let plan):
            "Subscribed\(plan.map { " to \($0.displayName)" } ?? "")."
        case .expired:
            "Your two free months have ended."
        }
    }
}
