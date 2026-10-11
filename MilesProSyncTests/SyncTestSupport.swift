import Foundation
@testable import MilesProSync

final class InMemoryTokenStore: TokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var session: AuthSession?

    init(_ session: AuthSession? = nil) {
        self.session = session
    }

    func load() -> AuthSession? {
        lock.withLock { session }
    }

    func save(_ session: AuthSession?) {
        lock.withLock { self.session = session }
    }
}

/// Scripted stand-in for the sync server: records every request and answers each with the next queued
/// response (or 200 `{}` once the queue is empty).
actor FakeServer {
    struct Response {
        var status: Int
        var body: String
    }

    private(set) var requests: [URLRequest] = []
    private var queued: [Response] = []
    /// Runs before responding to each request, e.g. to simulate an edit during an upload.
    private var onRequest: (@Sendable (URLRequest) async -> Void)?

    func enqueue(_ status: Int, _ body: String = "{}") {
        queued.append(Response(status: status, body: body))
    }

    func setOnRequest(_ handler: @escaping @Sendable (URLRequest) async -> Void) {
        onRequest = handler
    }

    func handle(_ request: URLRequest) async -> (Data, URLResponse) {
        requests.append(request)
        await onRequest?(request)
        let response = queued.isEmpty ? Response(status: 200, body: "{}") : queued.removeFirst()
        let http = HTTPURLResponse(url: request.url!, statusCode: response.status, httpVersion: nil, headerFields: nil)!
        return (Data(response.body.utf8), http)
    }

    nonisolated var transport: APIClient.Transport {
        { request in await self.handle(request) }
    }
}

enum SyncFixtures {
    static let config = APIConfig(baseURL: URL(string: "https://miles.example")!)

    static func session(expiresIn: TimeInterval = 3600, userID: String = "user-1") -> AuthSession {
        AuthSession(
            accessToken: "access-1",
            refreshToken: "refresh-1",
            expiresAt: Date().addingTimeInterval(expiresIn),
            userID: userID,
            email: "driver@example.com"
        )
    }

    static func tokenResponse(access: String, refresh: String, userID: String = "user-1") -> String {
        """
        {"access_token":"\(access)","token_type":"bearer","expires_in":3600,"refresh_token":"\(refresh)",
         "user":{"id":"\(userID)","email":"driver@example.com"}}
        """
    }

    static func body(of request: URLRequest) -> Any? {
        request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) }
    }
}
