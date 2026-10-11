import Foundation
import SwiftData
import Testing
@testable import MilesProSync

final class InMemoryAccountStore: AccountStore, @unchecked Sendable {
    private let lock = NSLock()
    private var account: DeviceAccount?

    init(_ account: DeviceAccount? = nil) {
        self.account = account
    }

    func load() -> DeviceAccount? { lock.withLock { account } }
    func save(_ account: DeviceAccount?) { lock.withLock { self.account = account } }
}

struct AppleSignInTests {
    @Test func nonceHashIsHexSHA256OfRawValue() {
        // Standard SHA-256 test vector.
        #expect(SignInNonce(raw: "abc").sha256 == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        let a = SignInNonce.make(), b = SignInNonce.make()
        #expect(a.raw.count == 32)
        #expect(a != b)
    }

    @Test func emailFallsBackToIdentityTokenClaim() {
        // header.payload.signature with payload {"email":"driver@privaterelay.appleid.com","sub":"001"}
        let payload = Data(#"{"email":"driver@privaterelay.appleid.com","sub":"001"}"#.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
        let credential = AppleCredential(userID: "001", identityToken: "eyJhbGciOiJSUzI1NiJ9.\(payload).sig", email: nil)
        #expect(credential.email == "driver@privaterelay.appleid.com")

        let explicit = AppleCredential(userID: "001", identityToken: "x.y.z", email: "me@example.com")
        #expect(explicit.email == "me@example.com")
        #expect(AppleCredential.emailClaim(from: "not-a-jwt") == nil)
    }
}

@MainActor
struct DeviceAccountTests {
    private let root: URL
    /// Stands in for UserDefaults.standard, so tests never touch the host app's real settings.
    private let legacyDefaults = UserDefaults(suiteName: "tests.legacy.\(UUID().uuidString)")!
    /// Per-run prefix: account settings suites are global, so IDs must not repeat across runs.
    private let run = UUID().uuidString

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "DeviceAccount-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    private func appSession(_ store: InMemoryAccountStore) -> AppSession {
        AppSession(
            accountStore: store, apiConfig: nil, storageRoot: root,
            legacyDefaults: legacyDefaults, startsServices: false
        )
    }

    private func id(_ name: String) -> String { "\(name)-\(run)" }

    private func link(_ session: AppSession, as name: String) {
        session.linkApple(with: AppleCredential(userID: id(name), identityToken: nil, email: "\(name)@example.com"), nonce: nil)
    }

    private func addTrip(to session: AppSession) throws {
        let context = ModelContext(try #require(session.current).container)
        context.insert(Trip(
            startDate: .now, endDate: .now, distanceMiles: 5,
            startLatitude: 0, startLongitude: 0, endLatitude: 0, endLongitude: 0
        ))
        try context.save()
    }

    private func tripCount(_ session: AppSession) throws -> Int {
        try ModelContext(try #require(session.current).container).fetchCount(FetchDescriptor<Trip>())
    }

    @Test func recordsWithoutSigningIn() {
        let store = InMemoryAccountStore()
        let session = appSession(store)
        #expect(session.current != nil)
        #expect(session.account?.isLinked == false)
        #expect(store.load() == session.account)
    }

    @Test func deviceAccountIsRestoredAtLaunch() throws {
        let store = InMemoryAccountStore()
        let first = appSession(store)
        try addTrip(to: first)
        let relaunched = appSession(store)
        #expect(relaunched.account?.storageKey == first.account?.storageKey)
        #expect(try tripCount(relaunched) == 1)
    }

    @Test func linkingAndUnlinkingKeepTripsAndRecording() throws {
        let store = InMemoryAccountStore()
        let session = appSession(store)
        let storageKey = session.account?.storageKey
        try addTrip(to: session)

        link(session, as: "apple-a")
        #expect(session.account?.appleUserID == id("apple-a"))
        #expect(store.load()?.email == "apple-a@example.com")
        #expect(session.account?.storageKey == storageKey)
        #expect(try tripCount(session) == 1)

        session.unlinkApple()
        #expect(session.current != nil)
        #expect(store.load()?.isLinked == false)
        #expect(store.load()?.email == nil)
        #expect(session.account?.storageKey == storageKey)
        #expect(try tripCount(session) == 1)
    }

    @Test func differentAppleIDCannotLinkOverCurrentOne() {
        let session = appSession(InMemoryAccountStore())
        link(session, as: "apple-a")
        link(session, as: "apple-b")
        #expect(session.account?.appleUserID == id("apple-a"))
        #expect(session.linkError != nil)
    }

    @Test func accountSavedWhenSignInWasRequiredKeepsItsStore() throws {
        let legacy = Data(#"{"appleUserID":"001.abc","email":"me@example.com"}"#.utf8)
        let account = try JSONDecoder().decode(DeviceAccount.self, from: legacy)
        #expect(account == DeviceAccount(storageKey: "001.abc", appleUserID: "001.abc", email: "me@example.com"))
    }

    @Test func linkingBringsBackTripsOfAnAppleIDThatSignedOutBeforeSignInWasOptional() throws {
        // Signed in and recorded a trip while sign-in was required, then signed out.
        let old = appSession(InMemoryAccountStore(DeviceAccount(storageKey: id("apple-a"), appleUserID: id("apple-a"), email: nil)))
        try addTrip(to: old)

        let session = appSession(InMemoryAccountStore())
        #expect(try tripCount(session) == 0)
        link(session, as: "apple-a")
        #expect(session.account?.storageKey == id("apple-a"))
        #expect(try tripCount(session) == 1)
    }

    @Test func linkingKeepsDeviceTripsOverAnOlderAppleIDStore() throws {
        let old = appSession(InMemoryAccountStore(DeviceAccount(storageKey: id("apple-a"), appleUserID: id("apple-a"), email: nil)))
        try addTrip(to: old)

        let session = appSession(InMemoryAccountStore())
        let storageKey = session.account?.storageKey
        try addTrip(to: session)
        link(session, as: "apple-a")
        #expect(session.account?.storageKey == storageKey)
    }

    @Test func firstAccountAdoptsTripsRecordedBeforeSignInExisted() throws {
        // A store at SwiftData's pre-sign-in default location, with one trip, and a setting in
        // the old app-wide defaults. In the app that store is left over from an earlier launch,
        // so nothing has it open. SwiftData keeps an in-process store open for the rest of the
        // test, so build it at a scratch path and copy the files (database, -shm, -wal) into
        // place: the copy was never opened by this process, just like the real leftover.
        let legacyURL = UserStorage.legacyStoreURL(root: root)
        let scratchURL = root.appending(path: "scratch.store")
        let scratch = try ModelContainer(
            for: Trip.self, RoutePoint.self,
            configurations: ModelConfiguration(url: scratchURL)
        )
        let scratchContext = ModelContext(scratch)
        scratchContext.insert(Trip(
            startDate: .now, endDate: .now, distanceMiles: 3,
            startLatitude: 0, startLongitude: 0, endLatitude: 0, endLongitude: 0
        ))
        try scratchContext.save()
        for suffix in ["", "-shm", "-wal"] {
            let source = URL(filePath: scratchURL.path() + suffix)
            guard FileManager.default.fileExists(atPath: source.path()) else { continue }
            try FileManager.default.copyItem(at: source, to: URL(filePath: legacyURL.path() + suffix))
        }
        legacyDefaults.set(0.67, forKey: AppSettings.Key.mileageRate)

        let session = appSession(InMemoryAccountStore())
        #expect(try tripCount(session) == 1)
        #expect(!FileManager.default.fileExists(atPath: legacyURL.path()))
        #expect(session.current?.defaults.double(forKey: AppSettings.Key.mileageRate) == 0.67)
        #expect(legacyDefaults.object(forKey: AppSettings.Key.mileageRate) == nil)

        // A lost Keychain account (e.g. restored to a new iPhone) finds the same device store again.
        #expect(try tripCount(appSession(InMemoryAccountStore())) == 1)
    }

    @Test func lostAccountRecoversTheDeviceStoreAndItsTrips() throws {
        let first = appSession(InMemoryAccountStore())
        try addTrip(to: first)
        let recovered = appSession(InMemoryAccountStore())
        #expect(recovered.account?.storageKey == first.account?.storageKey)
        #expect(try tripCount(recovered) == 1)
    }

    @Test func storageNamesDoNotContainTheAppleUserID() {
        let name = UserStorage.folderName(for: "001234.abcdef.5678")
        #expect(name.hasPrefix("user-"))
        #expect(!name.contains("001234"))
        #expect(name == UserStorage.folderName(for: "001234.abcdef.5678"))
        #expect(name != UserStorage.folderName(for: "other"))
    }
}
