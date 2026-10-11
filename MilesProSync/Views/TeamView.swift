import SwiftUI

/// Join a team, see its rate, and submit monthly mileage reports. Only business trips are shared
/// with a team, and only while you're on it.
struct TeamView: View {
    @Environment(AppSession.self) private var appSession
    @Environment(SubscriptionManager.self) private var subscriptions: SubscriptionManager?
    @State private var service = TeamService()
    @State private var code = ""
    @State private var confirmingLeave = false

    private var client: APIClient? { appSession.current?.apiClient }

    var body: some View {
        List {
            if client == nil || appSession.account?.isLinked != true {
                Section {
                    Text("Teams use Website Sync so your employer can see your business trips. Turn on Website Sync in Settings first.")
                } header: {
                    Text("Website Sync needed")
                }
            } else {
                content
            }
        }
        .navigationTitle("Team")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: subscriptions?.teamTransaction) { await refresh() }
        .refreshable { await refresh() }
        .confirmationDialog("Leave this team?", isPresented: $confirmingLeave, titleVisibility: .visible) {
            Button("Leave Team", role: .destructive) { perform { await service.leave(client: $0) } }
        } message: {
            Text("The team stops seeing your trips right away. Your trips stay on this iPhone.")
        }
    }

    @ViewBuilder
    private var content: some View {
        let status = service.status
        Section {
            Label("Only trips you classify as Business are shared, and only while you're on the team. Personal and unclassified trips are never sent to your team.", systemImage: "lock.shield")
                .font(.footnote)
        }

        if let message = service.errorMessage {
            Section { Text(message).foregroundStyle(.red) }
        }

        if status?.subscription.active != true {
            Section {
                Text("Team plans are $3.99 per user per month or $39.99 per user per year, with unlimited trips.")
                NavigationLink("Choose a Plan") { SubscriptionView() }
            } header: {
                Text("Subscription")
            }
        }

        if let team = status?.team {
            Section("Your team") {
                LabeledContent("Team", value: team.name)
                LabeledContent("Your role", value: team.roleName)
                LabeledContent("Rate", value: "\(team.rate.symbol)\(team.rate.perMile)/mi")
            }
            Section {
                ForEach(TeamService.recentMonths(), id: \.self) { month in
                    reportRow(month: month, report: status?.reports.first { $0.month == month })
                }
            } header: {
                Text("Monthly reports")
            } footer: {
                Text("Submit a month when your trips are classified. A manager approves it or sends it back with a comment.")
            }
            Section {
                Button("Leave Team", role: .destructive) { confirmingLeave = true }
            }
        } else if status != nil {
            Section {
                TextField("Invite code", text: $code)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                Button("Join Team") { perform { await service.join(code: code, client: $0) } }
                    .disabled(code.trimmingCharacters(in: .whitespaces).isEmpty || service.isWorking)
            } header: {
                Text("Join a team")
            } footer: {
                Text("Ask your team's admin for an invite code. Admins create teams on the Miles Pro Sync website.")
            }
        } else if service.isWorking {
            Section { ProgressView() }
        }
    }

    private func reportRow(month: String, report: TeamStatus.Report?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(Self.title(for: month))
                Spacer()
                if let report {
                    Text(report.status.capitalized).foregroundStyle(color(for: report.status))
                } else {
                    Button("Submit") { perform { await service.submit(month: month, client: $0) } }
                        .disabled(service.isWorking)
                }
            }
            if let report {
                if let comment = report.comment {
                    Text(comment).font(.footnote).foregroundStyle(.secondary)
                }
                if let miles = report.miles, let amount = report.amount {
                    Text("\(miles) mi · \(report.symbol)\(amount)").font(.footnote).foregroundStyle(.secondary)
                }
                if report.status == "rejected" {
                    Button("Resubmit") { perform { await service.submit(month: month, client: $0) } }
                        .disabled(service.isWorking)
                }
            }
        }
    }

    private func color(for status: String) -> Color {
        switch status {
        case "approved": .green
        case "rejected": .red
        default: .secondary
        }
    }

    private static func title(for month: String) -> String {
        let parser = DateFormatter()
        parser.dateFormat = "yyyy-MM"
        parser.locale = Locale(identifier: "en_US_POSIX")
        guard let date = parser.date(from: month) else { return month }
        return date.formatted(.dateTime.month(.wide).year())
    }

    private func refresh() async {
        guard let client, appSession.account?.isLinked == true else { return }
        await service.refresh(client: client, transaction: subscriptions?.teamTransaction)
    }

    private func perform(_ action: @escaping (APIClient) async -> Void) {
        guard let client else { return }
        Task { await action(client) }
    }
}
