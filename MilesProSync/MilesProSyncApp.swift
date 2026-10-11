import SwiftUI

@main
struct MilesProSyncApp: App {
    @State private var appSession: AppSession
    @State private var subscriptions = SubscriptionManager()

    init() {
        KeychainItem.clearAllIfFreshInstall()
        // Created here rather than lazily from a view: when iOS relaunches the app in the
        // background mid-trip, the device account must resume recording before launch finishes.
        let appSession = AppSession(accountStore: KeychainAccountStore(), apiConfig: APIConfig.fromBundle())
        AppSession.registerBackgroundRetry(for: appSession)
        _appSession = State(initialValue: appSession)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appSession)
                .environment(subscriptions)
        }
    }
}
