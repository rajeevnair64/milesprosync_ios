import AuthenticationServices
import CryptoKit
import Foundation

/// A one-time value tying a Sign in with Apple response to the request that asked for it. Apple
/// embeds the SHA-256 of `raw` in the identity token; the server checks `raw` against it, so an
/// intercepted token can't be replayed.
struct SignInNonce: Equatable {
    let raw: String

    var sha256: String {
        SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func make(length: Int = 32) -> SignInNonce {
        let charset = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-._")
        var bytes = [UInt8](repeating: 0, count: length)
        let status = SecRandomCopyBytes(kSecRandomDefault, length, &bytes)
        precondition(status == errSecSuccess, "Couldn't generate a sign-in nonce")
        return SignInNonce(raw: String(bytes.map { charset[Int($0) % charset.count] }))
    }
}

/// The parts of a Sign in with Apple result the app uses.
struct AppleCredential: Equatable, Sendable {
    /// Stable per app and Apple ID; identifies the account.
    let userID: String
    /// Short-lived JWT, exchanged for a cloud session.
    let identityToken: String?
    /// Apple returns `email` only on the very first sign-in, so fall back to the token's claim.
    let email: String?

    init(userID: String, identityToken: String?, email: String?) {
        self.userID = userID
        self.identityToken = identityToken
        self.email = email ?? identityToken.flatMap(Self.emailClaim)
    }

    init?(authorization: ASAuthorization) {
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else { return nil }
        self.init(
            userID: credential.user,
            identityToken: credential.identityToken.flatMap { String(data: $0, encoding: .utf8) },
            email: credential.email
        )
    }

    /// Reads the `email` claim from a JWT payload. Display only; the token's signature is
    /// verified by the server, never trusted on the device.
    static func emailClaim(from jwt: String) -> String? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object["email"] as? String
    }
}

/// The person using the app on this device. Trips and settings always live under `storageKey`,
/// with or without an Apple ID. Linking an Apple ID is optional and only turns on website sync.
struct DeviceAccount: Codable, Equatable, Sendable {
    /// Names this device's trip store and settings. Never changes once created, so linking or
    /// unlinking an Apple ID never moves trips.
    let storageKey: String
    /// Set while an Apple ID is linked for website sync.
    var appleUserID: String?
    var email: String?

    var isLinked: Bool { appleUserID != nil }

    static func makeLocal() -> DeviceAccount {
        DeviceAccount(storageKey: "device-" + UUID().uuidString, appleUserID: nil, email: nil)
    }
}

extension DeviceAccount {
    /// Accounts saved when sign-in was required have only `appleUserID` and `email`; their store
    /// is keyed by the Apple user ID, so that stays the storage key.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let appleUserID = try container.decodeIfPresent(String.self, forKey: .appleUserID)
        guard let storageKey = try container.decodeIfPresent(String.self, forKey: .storageKey) ?? appleUserID else {
            throw DecodingError.dataCorruptedError(forKey: .storageKey, in: container, debugDescription: "No storage key")
        }
        self.init(
            storageKey: storageKey,
            appleUserID: appleUserID,
            email: try container.decodeIfPresent(String.self, forKey: .email)
        )
    }
}

protocol AccountStore: Sendable {
    func load() -> DeviceAccount?
    func save(_ account: DeviceAccount?)
}

struct KeychainAccountStore: AccountStore {
    private let item = KeychainItem(service: KeychainItem.accountService, account: "appleUser")

    func load() -> DeviceAccount? {
        item.read().flatMap { try? JSONDecoder().decode(DeviceAccount.self, from: $0) }
    }

    func save(_ account: DeviceAccount?) {
        item.write(account.flatMap { try? JSONEncoder().encode($0) })
    }
}
