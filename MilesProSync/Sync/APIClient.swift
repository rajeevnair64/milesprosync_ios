import Foundation

/// The Miles Pro Sync website, whose API (website/trips/api.py) the app syncs with. From Info.plist
/// (`SyncAPIURL`, filled from the SYNC_API_URL build setting). The app holds no database
/// credentials: it signs in with Apple and the server limits every request to that account's trips.
struct APIConfig: Equatable, Sendable {
    let baseURL: URL

    /// nil when the build has no server configured, which turns cloud sync off.
    static func fromBundle(_ bundle: Bundle = .main) -> APIConfig? {
        guard let urlString = bundle.object(forInfoDictionaryKey: "SyncAPIURL") as? String,
              let url = URL(string: urlString), url.scheme == "https", url.host() != nil else {
            return nil
        }
        return APIConfig(baseURL: url)
    }
}

struct AuthSession: Codable, Equatable, Sendable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
    var userID: String
    var email: String?
}

protocol TokenStore: Sendable {
    func load() -> AuthSession?
    func save(_ session: AuthSession?)
}

enum SyncError: LocalizedError, Equatable {
    case notSignedIn
    case sessionExpired
    case server(status: Int, message: String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .notSignedIn: "Sign in to sync trips."
        case .sessionExpired: "Your session expired. Sign in again."
        case .server(_, let message): message
        case .invalidResponse: "Unexpected response from the server."
        }
    }
}

/// Client for the website's sync API: Sign in with Apple token exchange, trip upserts and account
/// deletion. Holds the session and refreshes the access token before it expires.
actor APIClient {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    let config: APIConfig
    private let tokenStore: any TokenStore
    private let transport: Transport
    private(set) var session: AuthSession?
    /// The refresh currently in flight. Concurrent callers share it: a refresh token is single-use,
    /// so a second request with the same token would be rejected and end the session.
    private var refreshTask: Task<AuthSession, Error>?
    /// Bumped whenever the session is replaced or cleared. A refresh that finds it changed while
    /// its request was in flight (the user signed out) must not write its result back.
    private var sessionGeneration = 0

    /// Refresh this long before expiry so a request never goes out with a token that lapses in flight.
    private let refreshLeeway: TimeInterval = 60

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    init(
        config: APIConfig,
        tokenStore: any TokenStore,
        transport: @escaping Transport = { try await URLSession.shared.data(for: $0) }
    ) {
        self.config = config
        self.tokenStore = tokenStore
        self.transport = transport
        self.session = tokenStore.load()
    }

    // MARK: - Auth

    /// Exchanges an Apple identity token for a session, creating the cloud account on first use.
    /// `nonce` is the raw value whose SHA-256 was sent in the Apple request; the server checks it
    /// against the token so an intercepted token can't be replayed.
    func signInWithApple(identityToken: String, nonce: String) async throws -> AuthSession {
        let data = try await send(jsonRequest(
            "POST", path: "auth/apple",
            body: ["id_token": identityToken, "nonce": nonce]
        ))
        guard let session = decodeSession(data) else { throw SyncError.invalidResponse }
        store(session)
        return session
    }

    /// Forgets the session on this device and, if the server can be reached, revokes its refresh
    /// token there. Offline, the token just goes unused.
    func signOut() async {
        guard let refreshToken = session?.refreshToken else { return }
        store(nil)
        _ = try? await send(jsonRequest("POST", path: "auth/sign-out", body: ["refresh_token": refreshToken]))
    }

    /// Deletes the signed-in user's account on the server (its login and email address), then
    /// forgets the session. Trips are kept server-side until the four-year retention purge.
    func deleteAccount() async throws {
        do {
            try await callDeleteAccount(accessToken: validSession().accessToken)
        } catch SyncError.server(status: 401, _) {
            guard let session else { throw SyncError.notSignedIn }
            let token = try await refresh(session).accessToken
            do {
                try await callDeleteAccount(accessToken: token)
            } catch SyncError.server(status: 401, _) {
                store(nil)
                throw SyncError.sessionExpired
            }
        }
        store(nil)
    }

    private func callDeleteAccount(accessToken: String) async throws {
        var request = URLRequest(url: endpoint("account"))
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        _ = try await send(request)
    }

    // MARK: - Trips

    func upsertTrips(_ trips: [TripPayload]) async throws {
        guard !trips.isEmpty else { return }
        let body = try Self.encoder.encode(trips)
        do {
            try await upsert(body, accessToken: validSession().accessToken)
        } catch SyncError.server(status: 401, _) {
            // Token revoked or device clock skewed — refresh once and retry.
            guard let session else { throw SyncError.notSignedIn }
            let token = try await refresh(session).accessToken
            do {
                try await upsert(body, accessToken: token)
            } catch SyncError.server(status: 401, _) {
                // A freshly issued token was rejected too (e.g. the account is gone): only a
                // new sign-in can recover.
                store(nil)
                throw SyncError.sessionExpired
            }
        }
    }

    private func upsert(_ body: Data, accessToken: String) async throws {
        var request = URLRequest(url: endpoint("trips"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        _ = try await send(request)
    }

    // MARK: - Session

    private func validSession() async throws -> AuthSession {
        guard let session else { throw SyncError.notSignedIn }
        if session.expiresAt.timeIntervalSinceNow > refreshLeeway { return session }
        return try await refresh(session)
    }

    private func refresh(_ current: AuthSession) async throws -> AuthSession {
        if let refreshTask { return try await refreshTask.value }
        let task = Task { try await performRefresh(current) }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value
    }

    private func performRefresh(_ current: AuthSession) async throws -> AuthSession {
        let generation = sessionGeneration
        let data: Data
        do {
            data = try await send(jsonRequest(
                "POST", path: "auth/refresh",
                body: ["refresh_token": current.refreshToken]
            ))
        } catch SyncError.server(let status, _) where (400..<500).contains(status) && status != 429 && status != 408 {
            // Refresh token revoked or already used — only a fresh sign-in can recover. (429 is only
            // the server's request limit and 408 a timeout: stay signed in and try again later.)
            if generation == sessionGeneration { store(nil) }
            throw SyncError.sessionExpired
        }
        // Signed out (or replaced) while the request was in flight: don't resurrect the session.
        guard generation == sessionGeneration else { throw SyncError.notSignedIn }
        guard var refreshed = decodeSession(data) else { throw SyncError.invalidResponse }
        refreshed.email = refreshed.email ?? current.email
        store(refreshed)
        return refreshed
    }

    private func store(_ session: AuthSession?) {
        sessionGeneration += 1
        self.session = session
        tokenStore.save(session)
    }

    private struct TokenResponse: Decodable {
        let accessToken: String
        let refreshToken: String
        let expiresIn: Double
        let user: User

        struct User: Decodable {
            let id: String
            let email: String?
        }
    }

    private func decodeSession(_ data: Data) -> AuthSession? {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let response = try? decoder.decode(TokenResponse.self, from: data) else { return nil }
        return AuthSession(
            accessToken: response.accessToken,
            refreshToken: response.refreshToken,
            expiresAt: Date().addingTimeInterval(response.expiresIn),
            userID: response.user.id,
            email: response.user.email
        )
    }

    // MARK: - HTTP

    private func endpoint(_ path: String) -> URL {
        config.baseURL.appending(path: "api/v1/\(path)")
    }

    private func jsonRequest(_ method: String, path: String, body: [String: String]) throws -> URLRequest {
        var request = URLRequest(url: endpoint(path))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await transport(request)
        guard let http = response as? HTTPURLResponse else { throw SyncError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let message = Self.errorMessage(from: data)
                ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode).capitalized
            throw SyncError.server(status: http.statusCode, message: message)
        }
        return data
    }

    /// The server answers errors with {"message": "..."}.
    private static func errorMessage(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["message"] as? String
    }
}

/// Keeps an account's cloud session in the Keychain, one item per account.
struct KeychainTokenStore: TokenStore {
    private let item: KeychainItem

    /// `userKey` is `UserStorage.folderName(for:)` of the account's storage key.
    init(userKey: String) {
        item = KeychainItem(service: KeychainItem.cloudSessionService, account: userKey)
    }

    func load() -> AuthSession? {
        item.read().flatMap { try? JSONDecoder().decode(AuthSession.self, from: $0) }
    }

    func save(_ session: AuthSession?) {
        item.write(session.flatMap { try? JSONEncoder().encode($0) })
    }
}
