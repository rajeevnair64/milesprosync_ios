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
                        subscriptions.individualProduct, subscriptions: subscriptions,
                        title: "Individual", blurb: "For one person. The first two months are free.",
                        fallbackPrice: "$4.99"
                    )
                    plan(
                        subscriptions.teamProduct, subscriptions: subscriptions,
                        title: "Team", blurb: "Per user, for people on a team. Unlimited trips, team reports and approvals.",
                        fallbackPrice: "$3.99"
                    )
                } header: {
                    Text("Plans")
                } footer: {
                    Text("Payment is charged to your Apple ID account at confirmation of purchase. Subscriptions renew monthly until cancelled at least 24 hours before the end of the current period. Manage or cancel in your Apple ID account settings. Switching between plans is handled by the App Store.")
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
        _ product: Product?, subscriptions: SubscriptionManager, title: String, blurb: String, fallbackPrice: String
    ) -> some View {
        let isCurrent: Bool = {
            guard case .subscribed(let plan) = subscriptions.state else { return false }
            return plan?.displayName == title
        }()
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Text("\(product?.displayPrice ?? fallbackPrice)/month").foregroundStyle(.secondary)
            }
            Text(blurb).font(.footnote).foregroundStyle(.secondary)
            if isCurrent {
                Label("Current plan", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else if let product {
                Button("Subscribe") { Task { await subscriptions.purchase(product) } }
                    .buttonStyle(.borderedProminent)
                    .disabled(subscriptions.isWorking)
            }
        }
        .padding(.vertical, 4)
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
