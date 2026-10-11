import Foundation
import SwiftData

/// Trip records are kept for four years from the date of the trip (see PRIVACY.md and the purge
/// job, `manage.py purge_expired_trips` on the website). On the device this erases deleted trips,
/// the ones the user can no longer see, once they pass that age; trips still in the list stay
/// until the user deletes them.
enum TripRetention {
    static let years = 4

    static func cutoff(now: Date = .now, calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: .year, value: -years, to: now) ?? now
    }

    /// Permanently removes expired deleted trips (and their route points). Returns how many.
    @discardableResult
    static func purgeExpiredDeletedTrips(in container: ModelContainer, now: Date = .now) throws -> Int {
        let cutoff = cutoff(now: now)
        let context = ModelContext(container)
        let expired = try context.fetch(FetchDescriptor<Trip>(
            predicate: #Predicate { $0.deletedAt != nil && $0.endDate < cutoff }
        ))
        for trip in expired {
            // Deleted explicitly: SwiftData's cascade rule doesn't reliably remove them here, and
            // leftover route points would keep location data past the retention period.
            for point in trip.route {
                context.delete(point)
            }
            context.delete(trip)
        }
        try context.save()
        return expired.count
    }
}
