import SwiftData
import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(AppSettings.Key.countryCode) private var countryCode = AppSettings.defaultCountryCode
    @State private var showingWebsiteSetup = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Country", value: AppSettings.countryName(for: AppSettings.defaultCountryCode))
                } header: {
                    Text("Region")
                } footer: {
                    Text("Miles Pro Sync is set up for the United States for now. More countries are coming.")
                }
                ReimbursementSection()
                Section {
                    NavigationLink("Subscription") {
                        SubscriptionView()
                    }
                    NavigationLink("Team") {
                        TeamView()
                    }
                } header: {
                    Text("Plan")
                } footer: {
                    Text("Two months free, then $39.99 per year, $4.99 per month, or $109.99 once for 5 years (one person only). Teams: $3.99 per user per month or $34.99 per year.")
                }
                Section {
                    NavigationLink("Auto-Classification") {
                        AutoClassificationView()
                    }
                    NavigationLink("Trip Purposes") {
                        PurposesView()
                    }
                } header: {
                    Text("Trips")
                } footer: {
                    Text("Classify drives automatically by place or work hours, and manage the purposes you can tag trips with.")
                }
                WebsiteSyncSection(showingSetup: $showingWebsiteSetup)
                Section("About") {
                    NavigationLink("Privacy Policy") {
                        PrivacyPolicyView()
                    }
                    LabeledContent("Version", value: AppSettings.versionText())
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showingWebsiteSetup) {
                WebsiteSyncSetupView()
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                // An earlier version let any country be chosen; only the United States is set up now.
                countryCode = AppSettings.normalizedCountryCode(countryCode)
            }
        }
    }
}

#Preview {
    let container = try! ModelContainer(for: Trip.self, RoutePoint.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    return SettingsView()
        .environment(TripSyncService(container: container, client: nil))
        .environment(AppSession.preview())
}
