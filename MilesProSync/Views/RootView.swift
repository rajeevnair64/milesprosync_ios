import SwiftUI

/// The device account's trips, settings and services. No sign-in is needed; website sync is an
/// optional setting.
struct RootView: View {
    @Environment(AppSession.self) private var appSession
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if let session = appSession.current {
                TripListView()
                    .environment(session.tripSync)
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
        .onChange(of: scenePhase) {
            appSession.scenePhaseChanged(to: scenePhase)
        }
    }
}

#Preview {
    RootView()
        .environment(AppSession.preview())
}
