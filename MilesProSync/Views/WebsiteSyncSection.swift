import AuthenticationServices
import SwiftUI

/// Settings section for optional website sync. The app records and keeps trips on this iPhone
/// without any account; linking an Apple ID here uploads them so they can be viewed on the
/// website. Setup goes through `WebsiteSyncSetupView`, which lists what is shared first.
struct WebsiteSyncSection: View {
    @Environment(AppSession.self) private var appSession
    @Environment(TripSyncService.self) private var sync
    @Environment(\.colorScheme) private var colorScheme
    @State private var showingSetup = false
    @State private var confirmingTurnOff = false
    @State private var confirmingDeletion = false
    @State private var isDeleting = false
    @State private var errorMessage: String?

    private var isLinked: Bool { appSession.account?.isLinked == true }

    var body: some View {
        Section {
            if !sync.isConfigured {
                Text("Website sync isn't available in this build. Your trips stay on this iPhone.")
                    .foregroundStyle(.secondary)
            } else if isLinked {
                linked
            } else {
                notLinked
            }
        } header: {
            Text("Website Sync (Optional)")
        } footer: {
            if sync.isConfigured {
                Text(isLinked
                    ? "Each trip, including its GPS route, uploads when it finishes and again if you change or delete it."
                    : "Only needed if you want to view your trips on the Miles Pro Sync website. Trips are recorded, kept and exported on this iPhone without it.")
            }
        }
        .sheet(isPresented: $showingSetup) {
            WebsiteSyncSetupView()
        }
    }

    @ViewBuilder
    private var notLinked: some View {
        LabeledContent("Status", value: "Off")
        Button("Set Up Website Access…") { showingSetup = true }
        NavigationLink("What's Shared") { SharedDataView() }
    }

    @ViewBuilder
    private var linked: some View {
        LabeledContent("Signed in with Apple", value: appSession.account?.email ?? "Apple ID")
        if sync.signedInEmail != nil {
            LabeledContent("Waiting to upload", value: "\(sync.pendingCount)")
            LabeledContent("Last synced") {
                if let lastSyncedAt = sync.lastSyncedAt {
                    Text(lastSyncedAt, format: .relative(presentation: .named))
                } else {
                    Text("Not this session")
                }
            }
            errorText
            Button {
                sync.syncNow()
            } label: {
                HStack {
                    Text("Sync Now")
                    if sync.isSyncing {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(sync.isSyncing)
        } else {
            Text("Not connected. Trips are saved on this iPhone and upload once you reconnect.")
                .foregroundStyle(.secondary)
            errorText
            SignInWithAppleButton(.continue, onRequest: appSession.prepare, onCompletion: appSession.complete)
                .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                .frame(height: 44)
        }
        NavigationLink("What's Shared") { SharedDataView() }

        Button("Turn Off Website Sync", role: .destructive) {
            confirmingTurnOff = true
        }
        .confirmationDialog("Turn off website sync?", isPresented: $confirmingTurnOff, titleVisibility: .visible) {
            Button("Turn Off", role: .destructive) { appSession.unlinkApple() }
        } message: {
            Text("New trips stop uploading and you're signed out of the website. Trips keep recording on this iPhone. Trips already uploaded stay with your website account.")
        }

        // Only a connected website account exists on the server to delete.
        if sync.signedInEmail != nil {
            Button("Delete Website Account", role: .destructive) {
                confirmingDeletion = true
            }
            .disabled(isDeleting)
            .confirmationDialog("Delete your website account?", isPresented: $confirmingDeletion, titleVisibility: .visible) {
                Button("Delete Account", role: .destructive) { deleteAccount() }
            } message: {
                Text("Your website login and email address are deleted and website sync turns off. Trips stay on this iPhone. Uploaded trip records are kept for four years from the date of each trip, then erased.")
            }
        }
        if let errorMessage {
            Text(errorMessage)
                .font(.footnote)
                .foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private var errorText: some View {
        if let error = appSession.linkError ?? sync.lastError {
            Text(error)
                .font(.footnote)
                .foregroundStyle(.red)
        }
    }

    private func deleteAccount() {
        isDeleting = true
        errorMessage = nil
        Task {
            do {
                try await appSession.deleteWebsiteAccount()
            } catch {
                errorMessage = error.localizedDescription
            }
            isDeleting = false
        }
    }
}

/// Explains what website sync shares, then offers Sign in with Apple. Closes once linked.
struct WebsiteSyncSetupView: View {
    @Environment(AppSession.self) private var appSession
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Sign in with Apple to create your Miles Pro Sync website account, so you can view your trips on the website. This is optional: without it, trips are recorded and kept only on this iPhone, and you can still export them.")
                }
                SharedDataSections()
                Section {
                    SignInWithAppleButton(.signIn, onRequest: appSession.prepare, onCompletion: appSession.complete)
                        .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                        .frame(height: 50)
                        .listRowInsets(EdgeInsets())
                    if let error = appSession.linkError {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                } footer: {
                    Text("By signing in, you agree to upload the information above. You can turn website sync off at any time in Settings.")
                }
            }
            .navigationTitle("Website Access")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Not Now") { dismiss() }
                }
            }
            .onChange(of: appSession.account?.isLinked) {
                if appSession.account?.isLinked == true { dismiss() }
            }
        }
    }
}
