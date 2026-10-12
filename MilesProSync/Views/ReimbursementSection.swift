import SwiftUI

/// How trips are paid: the taxation rate (the default, which updates itself each year), a per-mile
/// rate of your own, or FAVR (a fixed monthly amount plus a per-mile rate). Your own figures are
/// stored as typed and are never changed by an app update or a new taxation rate.
struct ReimbursementSection: View {
    @Environment(SettingsSyncService.self) private var settingsSync: SettingsSyncService?
    @AppStorage(AppSettings.Key.countryCode) private var countryCode = AppSettings.defaultCountryCode
    @AppStorage(AppSettings.Key.rateMode) private var modeRaw = AppSettings.RateMode.irs.rawValue
    @AppStorage(AppSettings.Key.mileageRate) private var mileageRate = AppSettings.defaultMileageRate
    @AppStorage(AppSettings.Key.favrFixedMonthly) private var favrFixed = 0.0
    @AppStorage(AppSettings.Key.favrPerMile) private var favrPerMile = 0.0
    @AppStorage(AppSettings.Key.favrMinMonthlyMiles) private var favrMinMiles = 0.0

    /// Edited as text and saved on every keystroke: a value-formatted TextField only commits on
    /// Return or focus loss, and the decimal keypad has no Return key.
    @State private var rateText = ""
    @State private var fixedText = ""
    @State private var variableText = ""
    @State private var minText = ""

    private var mode: AppSettings.RateMode {
        AppSettings.RateMode(rawValue: modeRaw) ?? .irs
    }

    private var symbol: String {
        AppSettings.currencySymbol(for: AppSettings.normalizedCountryCode(countryCode))
    }

    var body: some View {
        Section {
            Picker("Method", selection: $modeRaw) {
                ForEach(AppSettings.RateMode.allCases) { mode in
                    Text(mode.displayName).tag(mode.rawValue)
                }
            }
            .pickerStyle(.segmented)

            switch mode {
            case .irs:
                LabeledContent("\(Calendar.current.component(.year, from: .now)) taxation rate",
                               value: "\(symbol)\(AppSettings.formatRate(IRSRates.rate(on: .now)))/mi")
            case .custom:
                field("Rate (\(symbol)/mi)", text: $rateText, placeholder: "Rate")
            case .favr:
                field("Fixed per month (\(symbol))", text: $fixedText, placeholder: "0.00")
                field("Per mile (\(symbol)/mi)", text: $variableText, placeholder: "0.000")
                field("Minimum business miles", text: $minText, placeholder: "0")
            }

            if let status = settingsSync?.status, status != .idle {
                SyncStatusRow(status: status)
            }
        } header: {
            Text("Reimbursement")
        } footer: {
            footer
        }
        .onAppear(perform: load)
        .onChange(of: modeRaw) { load() }
        .onChange(of: rateText) { if let value = AppSettings.parseRate(rateText), value != mileageRate { mileageRate = value } }
        .onChange(of: fixedText) { if let value = AppSettings.parseRate(fixedText), value != favrFixed { favrFixed = value } }
        .onChange(of: variableText) { if let value = AppSettings.parseRate(variableText), value != favrPerMile { favrPerMile = value } }
        .onChange(of: minText) { if let value = AppSettings.parseRate(minText), value != favrMinMiles { favrMinMiles = value } }
    }

    @ViewBuilder
    private var footer: some View {
        switch mode {
        case .irs:
            Text("Each trip is paid at the taxation standard business mileage rate for the year it was made, and a new year's rate is picked up automatically.")
        case .custom:
            Text(isValid(rateText)
                ? "Your rate is kept exactly as entered. It never changes unless you change it."
                : "Enter a number of 0 or more. Exports keep using \(AppSettings.formatRate(mileageRate)) until then.")
        case .favr:
            Text("FAVR pays a fixed amount each month plus a per-mile rate. Enter the figures your employer gave you. The fixed amount is paid for each month with at least the minimum business miles (0 means every month). They are kept exactly as entered.")
        }
    }

    private func field(_ title: String, text: Binding<String>, placeholder: String) -> some View {
        LabeledContent(title) {
            TextField(placeholder, text: text)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .foregroundStyle(isValid(text.wrappedValue) ? Color.primary : Color.red)
        }
    }

    private func isValid(_ text: String) -> Bool {
        AppSettings.parseRate(text) != nil
    }

    private func load() {
        rateText = AppSettings.formatRate(mileageRate)
        fixedText = AppSettings.formatRate(favrFixed)
        variableText = AppSettings.formatRate(favrPerMile)
        minText = favrMinMiles == 0 ? "0" : String(favrMinMiles)
    }
}

/// Whether a change made here has reached the account: saving, saved (with the time) or retrying.
private struct SyncStatusRow: View {
    let status: SettingsSyncService.Status

    var body: some View {
        HStack(spacing: 8) {
            switch status {
            case .idle:
                EmptyView()
            case .pending, .syncing:
                ProgressView()
                Text("Saving to your account…")
            case .synced(let date):
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Saved to your account at \(date.formatted(date: .omitted, time: .shortened))")
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("Couldn't save yet. It will retry automatically.")
            }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }
}
