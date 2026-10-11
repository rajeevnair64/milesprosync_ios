import Foundation

/// The user's list of trip purposes ("Client visit", "Supplies", ...), stored on the device as one
/// newline-separated string so it can be an `@AppStorage` value.
enum TripPurposes {
    static let key = "settings.tripPurposes"
    static let defaults = ["Client visit", "Meeting", "Supplies", "Delivery", "Other"]

    static func parse(_ stored: String) -> [String] {
        stored.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    static func encode(_ purposes: [String]) -> String {
        purposes.joined(separator: "\n")
    }

    /// Purposes with `adding` appended unless blank or already present (ignoring case).
    static func adding(_ purpose: String, to purposes: [String]) -> [String] {
        let trimmed = purpose.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !purposes.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) else { return purposes }
        return purposes + [trimmed]
    }
}
