import Foundation

extension Trip {
    /// Whether `other` can be joined to this trip: both finished, neither deleted, on the same day.
    func canMerge(with other: Trip, calendar: Calendar = .current) -> Bool {
        guard self !== other, !isInProgress, !other.isInProgress, !isDeleted, !other.isDeleted else { return false }
        return calendar.isDate(startDate, inSameDayAs: other.startDate)
    }

    /// Joins two trips split by a gap in recording into the earlier one, which then runs from the
    /// earlier start to the later end with both distances and both routes. The later trip is
    /// deleted (and syncs as deleted). The distance driven in the gap between them isn't counted.
    @discardableResult
    static func merge(_ first: Trip, _ second: Trip) -> Trip {
        let (earlier, later) = first.startDate <= second.startDate ? (first, second) : (second, first)
        earlier.endDate = max(earlier.endDate, later.endDate)
        earlier.endLatitude = later.endLatitude
        earlier.endLongitude = later.endLongitude
        earlier.endAddress = later.endAddress
        earlier.distanceMiles += later.distanceMiles
        for point in later.route { point.trip = earlier }
        if earlier.classification == .unclassified, later.classification != .unclassified {
            earlier.classification = later.classification
        }
        if earlier.notes == nil { earlier.notes = later.notes }
        if earlier.purpose == nil { earlier.purpose = later.purpose }
        earlier.revision += 1
        later.markDeleted()
        return earlier
    }
}
