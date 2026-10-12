import SwiftUI

/// Semantic colors adapt to light and dark appearances; labels also convey every status.
enum AppTheme {
    static let blue = Color("AccentColor")
    static let teal = Color("BrandTeal")
    static let coral = Color("BrandCoral")
    static let gold = Color("BrandGold")
    static let ink = Color("BrandInk")
    static let canvas = Color("Canvas")
    // Fixed dark stops retain contrast with the summary's white text in both appearances.
    static let summaryGradient = LinearGradient(
        colors: [Color(red: 0.14, green: 0.30, blue: 0.73), Color(red: 0.04, green: 0.34, blue: 0.42)],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )
}

extension View {
    func brandedBackground() -> some View {
        scrollContentBackground(.hidden)
            .background(AppTheme.canvas)
            .tint(AppTheme.blue)
    }
}

extension TripClassification {
    var accentColor: Color {
        switch self {
        case .business: AppTheme.blue
        case .personal: AppTheme.teal
        case .unclassified: AppTheme.gold
        }
    }
}

struct RecordingBadge: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Label {
            Text("Recording")
        } icon: {
            Image(systemName: "record.circle.fill")
                .symbolEffect(.pulse, options: .repeating, isActive: !reduceMotion)
        }
        .font(.caption.bold())
        .foregroundStyle(AppTheme.teal)
    }
}
