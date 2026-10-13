import CoreLocation
import SwiftUI

enum Onboarding {
    static let completeKey = "onboardingComplete"

    static func isComplete(defaults: UserDefaults) -> Bool {
        defaults.bool(forKey: completeKey)
    }

    static func markComplete(defaults: UserDefaults) {
        defaults.set(true, forKey: completeKey)
    }

    /// Only people who haven't been asked for location yet need it; everyone else has already
    /// made the choice.
    static func isNeeded(status: CLAuthorizationStatus, defaults: UserDefaults) -> Bool {
        status == .notDetermined && !isComplete(defaults: defaults)
    }
}

/// First launch: explain automatic tracking, then ask for location, one step at a time. Website
/// sync and plans are left for later, in Settings.
struct OnboardingView: View {
    let status: CLAuthorizationStatus
    let requestLocation: () -> Void
    let finish: () -> Void

    @State private var step = 0

    var body: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 0)
            switch step {
            case 0: intro
            case 1: permission
            default: done
            }
            Spacer(minLength: 0)
            Button(action: advance) {
                Text(buttonTitle).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(24)
        .background(AppTheme.canvas)
        .interactiveDismissDisabled()
        .animation(.default, value: step)
        .onChange(of: status) {
            // Moves on once the person has answered the system prompt.
            if step == 1, status != .notDetermined { step = 2 }
        }
    }

    private var buttonTitle: String {
        switch step {
        case 0: "Continue"
        case 1: "Allow Location"
        default: "Start Using Miles Pro Sync"
        }
    }

    private func advance() {
        switch step {
        case 0: step = 1
        case 1: requestLocation()
        default: finish()
        }
    }

    private var intro: some View {
        page(
            image: "car.side.fill",
            title: "Your drives log themselves",
            text: "Miles Pro Sync notices when you start and stop driving and records the trip, route and distance. There's nothing to press."
        )
    }

    private var permission: some View {
        page(
            image: "location.fill",
            title: "Allow location",
            text: "To record drives in the background, choose Allow While Using App now, then Always when iOS asks. Your location is used only to log trips."
        )
    }

    private var done: some View {
        let always = status == .authorizedAlways
        return page(
            image: always ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
            title: always ? "You're all set" : "One more thing",
            text: always
                ? "Your next drive will be recorded automatically. You can link a website account any time in Settings."
                : "Trips are recorded reliably only when location is set to Always. You can change it in Settings, Privacy & Security, Location Services."
        )
    }

    private func page(image: String, title: String, text: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: image)
                .font(.system(size: 56))
                .foregroundStyle(AppTheme.blue)
            Text(title)
                .font(.title2.bold())
                .multilineTextAlignment(.center)
            Text(text)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }
}
