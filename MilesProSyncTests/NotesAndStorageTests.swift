import Foundation
import Testing
@testable import MilesProSync

struct NotesAndStorageTests {
    @Test func editingNotesMarksTripForUpload() {
        let trip = Trip(
            startDate: .now, endDate: .now, distanceMiles: 1,
            startLatitude: 0, startLongitude: 0, endLatitude: 0, endLongitude: 0
        )
        let before = trip.revision
        trip.setNotes("Client visit")
        #expect(trip.notes == "Client visit")
        #expect(trip.revision == before + 1)

        trip.setNotes("Client visit")
        #expect(trip.revision == before + 1)

        trip.setNotes("   ")
        #expect(trip.notes == nil)
        #expect(trip.revision == before + 2)
    }

    @Test func legacyStoreIsStillAdoptedAfterAFailedFirstAttempt() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        // A directory exists (as after a failed first attempt) but holds no store yet.
        try FileManager.default.createDirectory(
            at: UserStorage.directory(for: "device-a", root: root), withIntermediateDirectories: true
        )
        #expect(!UserStorage.anyStoreExists(root: root))

        try Data().write(to: UserStorage.storeURL(for: "device-a", root: root))
        #expect(UserStorage.anyStoreExists(root: root))
    }
}
