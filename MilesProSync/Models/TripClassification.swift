import Foundation

enum TripClassification: String, Codable, CaseIterable, Identifiable {
    case unclassified
    case business
    case personal

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .unclassified: "Unclassified"
        case .business: "Business"
        case .personal: "Personal"
        }
    }
}
