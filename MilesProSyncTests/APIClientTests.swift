import Foundation
import SwiftData
import Testing
@testable import MilesProSync

struct APIClientTests {
    /// Route points only attach to a trip that lives in a model context, as in the app.
    private let context: ModelContext = {
        let container = try! ModelContainer(
            for: Trip.self, RoutePoint.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }()

    private func payload(address: String? = nil, deleted: Bool = false) -> TripPayload {
        let trip = Trip(
            startDate: Date(timeIntervalSince1970: 0), endDate: Date(timeIntervalSince1970: 600),
            distanceMiles: 7.2, startLatitude: 1, startLongitude: 2, endLatitude: 3, endLongitude: 4,
            startAddress: address, classification: .business
        )
        context.insert(trip)
        trip.route = [
            RoutePoint(latitude: 1.001, longitude: 2.001, timestamp: Date(timeIntervalSince1970: 5)),
            RoutePoint(latitude: 1, longitude: 2, timestamp: Date(timeIntervalSince1970: 0), speed: 12.5, horizontalAccuracy: 4),
        ]
        if deleted { trip.markDeleted(at: Date(timeIntervalSince1970: 1_000)) }
        return TripPayload(trip: trip)
    }

    @Test func appleSignInExchangesIdentityTokenForSession() async throws {
        let server = FakeServer()
        await server.enqueue(200, SyncFixtures.tokenResponse(access: "a", refresh: "r"))
        let store = InMemoryTokenStore()
        let client = APIClient(config: SyncFixtures.config, tokenStore: store, transport: server.transport)

        let session = try await client.signInWithApple(identityToken: "apple.jwt.token", nonce: "raw-nonce")

        #expect(session.accessToken == "a")
        #expect(store.load() == session)
        let request = try #require(await server.requests.first)
        #expect(request.url?.absoluteString == "https://miles.example/api/v1/auth/apple")
        #expect(request.httpMethod == "POST")
        #expect(SyncFixtures.body(of: request) as? [String: String] == [
            "id_token": "apple.jwt.token", "nonce": "raw-nonce",
        ])
    }

    @Test func rejectedAppleTokenSurfacesServerMessage() async {
        let server = FakeServer()
        await server.enqueue(400, #"{"message":"Sign in with Apple couldn't be verified. Please try again."}"#)
        let store = InMemoryTokenStore()
        let client = APIClient(config: SyncFixtures.config, tokenStore: store, transport: server.transport)

        await #expect(throws: SyncError.server(status: 400, message: "Sign in with Apple couldn't be verified. Please try again.")) {
            try await client.signInWithApple(identityToken: "t", nonce: "n")
        }
        #expect(store.load() == nil)
    }

    @Test func upsertSendsBatchWithAuth() async throws {
        let server = FakeServer()
        await server.enqueueOK()
        let client = APIClient(config: SyncFixtures.config, tokenStore: InMemoryTokenStore(SyncFixtures.session()), transport: server.transport)

        try await client.upsertTrips([payload(address: "1 Main St"), payload(address: nil)])

        let request = try #require(await server.requests.first)
        #expect(request.url?.absoluteString == "https://miles.example/api/v1/trips")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer access-1")
        #expect(request.value(forHTTPHeaderField: "apikey") == nil) // no credentials besides the user's token

        let rows = try #require(SyncFixtures.body(of: request) as? [[String: Any]])
        #expect(rows.count == 2)
        // Every row carries every key, nulls included, so a cleared value is cleared on the server.
        #expect(Set(rows[0].keys) == Set(rows[1].keys))
        #expect(rows[1]["start_address"] is NSNull)
        #expect(rows[0]["classification"] as? String == "business")
        #expect(rows[0]["distance_miles"] as? Double == 7.2)
        #expect(rows[0]["started_at"] as? String == "1970-01-01T00:00:00Z")
        #expect(rows[0]["user_id"] == nil) // the server takes the account from the access token
        #expect(rows[0]["deleted_at"] is NSNull)
    }

    @Test func upsertIncludesRouteOldestFirstAndDeletion() async throws {
        let server = FakeServer()
        await server.enqueueOK()
        let client = APIClient(config: SyncFixtures.config, tokenStore: InMemoryTokenStore(SyncFixtures.session()), transport: server.transport)

        try await client.upsertTrips([payload(deleted: true)])

        let request = try #require(await server.requests.first)
        let row = try #require((SyncFixtures.body(of: request) as? [[String: Any]])?.first)
        #expect(row["deleted_at"] as? String == "1970-01-01T00:16:40Z")
        let route = try #require(row["route"] as? [[String: Any]])
        #expect(route.count == 2)
        #expect(route[0]["recorded_at"] as? String == "1970-01-01T00:00:00Z")
        #expect(route[0]["latitude"] as? Double == 1)
        #expect(route[0]["speed_mps"] as? Double == 12.5)
        #expect(route[0]["horizontal_accuracy_m"] as? Double == 4)
        #expect(route[1]["speed_mps"] == nil) // unknown speed is omitted inside the route
    }

    @Test func expiringTokenIsRefreshedBeforeUpload() async throws {
        let server = FakeServer()
        await server.enqueue(200, SyncFixtures.tokenResponse(access: "access-2", refresh: "refresh-2"))
        await server.enqueueOK()
        let store = InMemoryTokenStore(SyncFixtures.session(expiresIn: 10))
        let client = APIClient(config: SyncFixtures.config, tokenStore: store, transport: server.transport)

        try await client.upsertTrips([payload()])

        let requests = await server.requests
        #expect(requests.count == 2)
        #expect(requests[0].url?.absoluteString == "https://miles.example/api/v1/auth/refresh")
        #expect(SyncFixtures.body(of: requests[0]) as? [String: String] == ["refresh_token": "refresh-1"])
        #expect(requests[1].value(forHTTPHeaderField: "Authorization") == "Bearer access-2")
        #expect(store.load()?.refreshToken == "refresh-2")
        #expect(store.load()?.email == "driver@example.com")
    }

    @Test func unauthorizedUploadRefreshesOnceAndRetries() async throws {
        let server = FakeServer()
        await server.enqueue(401, #"{"message":"Your session expired. Sign in again."}"#)
        await server.enqueue(200, SyncFixtures.tokenResponse(access: "access-2", refresh: "refresh-2"))
        await server.enqueue(204, "")
        let client = APIClient(config: SyncFixtures.config, tokenStore: InMemoryTokenStore(SyncFixtures.session()), transport: server.transport)

        try await client.upsertTrips([payload()])

        let requests = await server.requests
        #expect(requests.count == 3)
        #expect(requests[2].value(forHTTPHeaderField: "Authorization") == "Bearer access-2")
    }

    @Test func revokedRefreshTokenSignsOut() async {
        let server = FakeServer()
        await server.enqueue(401, #"{"message":"Your session expired. Sign in again."}"#)
        let store = InMemoryTokenStore(SyncFixtures.session(expiresIn: 0))
        let client = APIClient(config: SyncFixtures.config, tokenStore: store, transport: server.transport)

        await #expect(throws: SyncError.sessionExpired) {
            try await client.upsertTrips([payload()])
        }
        #expect(store.load() == nil)
        #expect(await client.session == nil)
    }

    @Test func forbiddenRefreshSignsOut() async {
        let server = FakeServer()
        await server.enqueue(403, #"{"message":"Forbidden"}"#)
        let store = InMemoryTokenStore(SyncFixtures.session(expiresIn: 0))
        let client = APIClient(config: SyncFixtures.config, tokenStore: store, transport: server.transport)

        await #expect(throws: SyncError.sessionExpired) {
            try await client.upsertTrips([payload()])
        }
        #expect(store.load() == nil)
    }

    @Test(arguments: [404, 413, 502])
    func aProxyOrServerErrorOnRefreshKeepsSession(status: Int) async {
        let server = FakeServer()
        await server.enqueue(status, #"{"message":"Something else went wrong"}"#)
        let store = InMemoryTokenStore(SyncFixtures.session(expiresIn: 0))
        let client = APIClient(config: SyncFixtures.config, tokenStore: store, transport: server.transport)

        await #expect(throws: SyncError.server(status: status, message: "Something else went wrong")) {
            try await client.upsertTrips([payload()])
        }
        #expect(store.load() != nil)
    }

    @Test func rateLimitedRefreshKeepsSession() async {
        let server = FakeServer()
        await server.enqueue(429, #"{"message":"Too many requests right now."}"#)
        let store = InMemoryTokenStore(SyncFixtures.session(expiresIn: 0))
        let client = APIClient(config: SyncFixtures.config, tokenStore: store, transport: server.transport)

        await #expect(throws: SyncError.server(status: 429, message: "Too many requests right now.")) {
            try await client.upsertTrips([payload()])
        }
        #expect(store.load() != nil)
    }

    @Test func rateLimitedUploadKeepsSessionAndSurfacesMessage() async {
        let server = FakeServer()
        await server.enqueue(429, #"{"message":"Too many requests right now."}"#)
        let store = InMemoryTokenStore(SyncFixtures.session())
        let client = APIClient(config: SyncFixtures.config, tokenStore: store, transport: server.transport)

        await #expect(throws: SyncError.server(status: 429, message: "Too many requests right now.")) {
            try await client.upsertTrips([payload()])
        }
        #expect(store.load() != nil)
    }

    @Test func uploadWithoutSessionFails() async {
        let client = APIClient(config: SyncFixtures.config, tokenStore: InMemoryTokenStore(), transport: FakeServer().transport)
        await #expect(throws: SyncError.notSignedIn) {
            try await client.upsertTrips([payload()])
        }
    }
}

extension APIClientTests {
    @Test func deleteAccountCallsServerAndSignsOut() async throws {
        let server = FakeServer()
        await server.enqueue(204, "")
        let store = InMemoryTokenStore(SyncFixtures.session())
        let client = APIClient(config: SyncFixtures.config, tokenStore: store, transport: server.transport)

        try await client.deleteAccount()

        let request = try #require(await server.requests.first)
        #expect(request.url?.absoluteString == "https://miles.example/api/v1/account")
        #expect(request.httpMethod == "DELETE")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer access-1")
        #expect(store.load() == nil)
    }

    @Test func failedAccountDeletionKeepsSession() async {
        let server = FakeServer()
        await server.enqueue(500, #"{"message":"boom"}"#)
        let store = InMemoryTokenStore(SyncFixtures.session())
        let client = APIClient(config: SyncFixtures.config, tokenStore: store, transport: server.transport)

        await #expect(throws: SyncError.server(status: 500, message: "boom")) {
            try await client.deleteAccount()
        }
        #expect(store.load() != nil)
    }
}

extension APIClientTests {
    @Test func signOutForgetsSessionAndRevokesRefreshToken() async throws {
        let server = FakeServer()
        await server.enqueue(204, "")
        let store = InMemoryTokenStore(SyncFixtures.session())
        let client = APIClient(config: SyncFixtures.config, tokenStore: store, transport: server.transport)

        await client.signOut()

        #expect(store.load() == nil)
        let request = try #require(await server.requests.first)
        #expect(request.url?.absoluteString == "https://miles.example/api/v1/auth/sign-out")
        #expect(SyncFixtures.body(of: request) as? [String: String] == ["refresh_token": "refresh-1"])
    }

    @Test func signOutOfflineStillForgetsSession() async {
        let store = InMemoryTokenStore(SyncFixtures.session())
        let client = APIClient(config: SyncFixtures.config, tokenStore: store) { _ in throw URLError(.notConnectedToInternet) }

        await client.signOut()

        #expect(store.load() == nil)
    }

    @Test func configRequiresAnHTTPSAddress() {
        #expect(APIConfig.fromBundle(Bundle(for: BundleMarker.self)) == nil) // test bundle has no SyncAPIURL
    }
}

private final class BundleMarker {}
