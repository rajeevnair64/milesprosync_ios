import SwiftData
import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(AppSettings.Key.countryCode) private var countryCode = AppSettings.defaultCountryCode
    @AppStorage(AppSettings.Key.mileageRate) private var mileageRate = AppSettings.defaultMileageRate
    /// Edited as text and saved on every keystroke: a value-formatted TextField only commits on
    /// Return or focus loss, and the decimal keypad has no Return key.
    @State private var rateText = ""

    private var isUS: Bool { countryCode == "US" }

    private var isRateValid: Bool {
        AppSettings.parseRate(rateText) != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Region") {
                    Picker("Country", selection: $countryCode) {
                        ForEach(AppSettings.countries) { country in
                            Text(country.name).tag(country.code)
                        }
                    }
                    .pickerStyle(.navigationLink)
                }
                Section {
                    LabeledContent("Rate (\(AppSettings.currencySymbol(for: countryCode))/mi)") {
                        TextField("Rate", text: $rateText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .foregroundStyle(isRateValid ? Color.primary : Color.red)
                    }
                    Button(isUS ? "Reset to IRS Rate" : "Reset to Default Rate") {
                        mileageRate = AppSettings.defaultMileageRate
                        rateText = AppSettings.formatRate(mileageRate)
                    }
                    .disabled(mileageRate == AppSettings.defaultMileageRate && isRateValid)
                } header: {
                    Text("Reimbursement")
                } footer: {
                    if isRateValid {
                        Text(isUS
                            ? "Defaults to the 2026 IRS standard business mileage rate of $0.725 per mile."
                            : "Defaults to the US IRS rate of 0.725 per mile. Enter your own country's rate.")
                    } else {
                        Text("Enter a number of 0 or more. Exports keep using \(AppSettings.formatRate(mileageRate)) until then.")
                            .foregroundStyle(.red)
                    }
                }
                WebsiteSyncSection()
                Section("About") {
                    NavigationLink("Privacy Policy") {
                        PrivacyPolicyView()
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear { rateText = AppSettings.formatRate(mileageRate) }
            .onChange(of: rateText) {
                // Showing the stored rate (rounded to 3 decimals) must not write the rounded value back.
                guard rateText != AppSettings.formatRate(mileageRate) else { return }
                if let rate = AppSettings.parseRate(rateText) {
                    mileageRate = rate
                }
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
