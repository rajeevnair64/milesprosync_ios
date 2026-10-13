import CoreLocation
import SwiftUI

/// Step-by-step help for turning location back on, with a shortcut to the app's Settings page.
struct LocationAccessView: View {
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(spacing: 12) {
                        Image(systemName: "location.fill")
                            .font(.system(size: 44))
                            .foregroundStyle(AppTheme.blue)
                        Text("Keep location on so your drives are recorded")
                            .font(.headline)
                            .multilineTextAlignment(.center)
                        Text("Miles Pro Sync uses your location in the background to notice when you start and stop driving. Without it, no trips are logged.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
                Section("How to turn it on") {
                    step(1, "Tap Open Settings below.")
                    step(2, "Tap Location.")
                    step(3, "Choose Always.")
                    step(4, "Leave Precise Location on.")
                }
                Section {
                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            openURL(url)
                        }
                    } label: {
                        Label("Open Settings", systemImage: "gearshape")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .listRowBackground(Color.clear)
                } footer: {
                    Text("Also make sure Location Services is on under Settings, Privacy & Security.")
                }
            }
            .navigationTitle("Location Access")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(spacing: 12) {
            Text("\(number)")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(AppTheme.blue, in: Circle())
            Text(text)
        }
    }
}
