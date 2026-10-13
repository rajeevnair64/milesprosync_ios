import SwiftUI

/// The device account's trips, settings and services. No sign-in is needed; website sync is an
/// optional setting.
struct RootView: View {
    @Environment(AppSession.self) private var appSession
    @Environment(\.scenePhase) private var scenePhase
    @Environment(SubscriptionManager.self) private var subscriptions: SubscriptionManager?
    @State private var choosingAccountType = false
    @State private var showingOnboarding = false

    var body: some View {
        Group {
            if let session = appSession.current {
                TripListView()
                    .environment(session.tripSync)
                    .environment(session.settingsSync)
                    .modelContainer(session.container)
                    // Every @AppStorage setting below reads and writes this account's own suite.
                    .defaultAppStorage(session.defaults)
                    .id(session.id)
            } else {
                ContentUnavailableView(
                    "Couldn't Open Your Trips",
                    systemImage: "exclamationmark.triangle",
                    description: Text(appSession.launchError ?? "")
                )
            }
        }
        .tint(AppTheme.blue)
        .onChange(of: scenePhase) {
            appSession.scenePhaseChanged(to: scenePhase)
        }
        // Once, until a choice is made: Individual or Teams. Dismissing it leaves the choice to
        // Settings → Plan.
        .task {
            // Onboarding comes first; the plan choice follows when it is dismissed.
            guard let session = appSession.current,
                  !Onboarding.isNeeded(status: session.driveDetection.authorizationStatus, defaults: session.defaults)
            else { return }
            promptForAccountType()
        }
        .onChange(of: showingOnboarding) {
            if !showingOnboarding { promptForAccountType() }
        }
        .task(id: appSession.current?.id) {
            guard let session = appSession.current else { return }
            showingOnboarding = Onboarding.isNeeded(
                status: session.driveDetection.authorizationStatus, defaults: session.defaults
            )
        }
        .fullScreenCover(isPresented: $showingOnboarding) {
            if let session = appSession.current {
                OnboardingView(
                    status: session.driveDetection.authorizationStatus,
                    requestLocation: {
                        Onboarding.markComplete(defaults: session.defaults)
                        session.driveDetection.start()
                    },
                    finish: { showingOnboarding = false }
                )
            }
        }
        .sheet(isPresented: $choosingAccountType) {
            NavigationStack {
                AccountTypeView()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Later") { choosingAccountType = false }
                        }
                    }
            }
        }
    }
}

extension RootView {
    private func promptForAccountType() {
        let defaults = UserDefaults.standard
        guard subscriptions?.accountType == nil, !defaults.bool(forKey: AccessStore.accountTypePromptedKey) else { return }
        defaults.set(true, forKey: AccessStore.accountTypePromptedKey)
        choosingAccountType = true
    }
}

#Preview {
    RootView()
        .environment(AppSession.preview())
}
