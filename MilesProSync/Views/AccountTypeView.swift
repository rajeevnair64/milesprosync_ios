import SwiftUI

/// Individual or Teams: one or the other. Shown once at first launch and from Settings → Plan.
/// Paying for a plan decides it, after which it can't be changed here.
struct AccountTypeView: View {
    @Environment(SubscriptionManager.self) private var subscriptions: SubscriptionManager?
    @Environment(\.dismiss) private var dismiss

    private var canChange: Bool {
        subscriptions.map { AccountType.canChange(in: $0.state) } ?? false
    }

    var body: some View {
        List {
            Section {
                option(
                    .individual, systemImage: "person",
                    detail: "Just you. Pay monthly ($4.99), yearly ($39.99), or once for 5 years ($109.99, one person only)."
                )
                option(
                    .team, systemImage: "person.3",
                    detail: "You're part of a team. Your employer pays per user: $3.99 a month or $34.99 a year, and you join with an invite code."
                )
            } header: {
                Text("How will you use Miles Pro Sync?")
            } footer: {
                Text(canChange
                     ? "Two months are free either way. You use it as one or the other, not both."
                     : "Your plan decides this. To switch, let your current plan end first.")
            }
        }
        .brandedBackground()
        .navigationTitle("Plan type")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func option(_ type: AccountType, systemImage: String, detail: String) -> some View {
        Button {
            if subscriptions?.chooseAccountType(type) == true { dismiss() }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: systemImage).font(.title2).frame(width: 32)
                VStack(alignment: .leading, spacing: 4) {
                    Text(type.displayName).font(.headline)
                    Text(detail).font(.footnote).foregroundStyle(.secondary)
                }
                Spacer()
                if subscriptions?.accountType == type {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canChange && subscriptions?.accountType != type)
    }
}

#Preview {
    NavigationStack { AccountTypeView() }
}
