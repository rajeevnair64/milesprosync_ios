import Foundation
import Observation

struct TeamStatus: Decodable, Equatable {
    struct Subscription: Decodable, Equatable {
        let active: Bool
        let price: String?
    }

    struct Rate: Decodable, Equatable {
        let perMile: String
        let symbol: String
    }

    struct Team: Decodable, Equatable {
        let id: String
        let name: String
        let role: String
        let rate: Rate

        var roleName: String { role.capitalized }
    }

    struct Report: Decodable, Equatable, Identifiable {
        let month: String
        let status: String
        let comment: String?
        let tripCount: Int?
        let miles: String?
        let amount: String?
        let symbol: String

        var id: String { month }
    }

    let subscription: Subscription
    let team: Team?
    let reports: [Report]

    static func decode(_ data: Data) -> TeamStatus? {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try? decoder.decode(TeamStatus.self, from: data)
    }
}

extension APIClient {
    func teamStatus() async throws -> TeamStatus {
        try decodeTeam(await authorized("GET", path: "team"))
    }

    /// Sends the signed Team transaction so the website can unlock team features.
    func sendSubscription(signedTransaction: String) async throws {
        _ = try await authorized("POST", path: "subscription", body: ["signed_transaction": signedTransaction])
    }

    func joinTeam(code: String) async throws -> TeamStatus {
        try decodeTeam(await authorized("POST", path: "team/join", body: ["code": code]))
    }

    func leaveTeam() async throws -> TeamStatus {
        try decodeTeam(await authorized("POST", path: "team/leave", body: [String: String]()))
    }

    func submitReport(month: String) async throws -> TeamStatus {
        try decodeTeam(await authorized("POST", path: "team/reports", body: ["month": month]))
    }

    private func decodeTeam(_ data: Data) throws -> TeamStatus {
        guard let status = TeamStatus.decode(data) else { throw SyncError.invalidResponse }
        return status
    }
}

/// Drives the Team screen: what the website says about the person's subscription, team and
/// reports, and the actions (join, leave, submit a month).
@Observable
@MainActor
final class TeamService {
    private(set) var status: TeamStatus?
    private(set) var isWorking = false
    private(set) var errorMessage: String?

    /// Refreshes from the website. `transaction` is the signed Team transaction, if the person has
    /// one, so the website learns about a new or renewed subscription.
    func refresh(client: APIClient, transaction: String?) async {
        await run {
            if let transaction { try await client.sendSubscription(signedTransaction: transaction) }
            return try await client.teamStatus()
        }
    }

    func join(code: String, client: APIClient) async {
        await run { try await client.joinTeam(code: code) }
    }

    func leave(client: APIClient) async {
        await run { try await client.leaveTeam() }
    }

    func submit(month: String, client: APIClient) async {
        await run { try await client.submitReport(month: month) }
    }

    /// The current month and the two before it, as "yyyy-MM".
    nonisolated static func recentMonths(now: Date = .now, calendar: Calendar = .current) -> [String] {
        (0..<3).compactMap { offset in
            calendar.date(byAdding: .month, value: -offset, to: now).map { date in
                let comps = calendar.dateComponents([.year, .month], from: date)
                return String(format: "%04d-%02d", comps.year ?? 0, comps.month ?? 0)
            }
        }
    }

    private func run(_ operation: () async throws -> TeamStatus) async {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            status = try await operation()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
