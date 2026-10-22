import Foundation
import OSLog

private let log = Logger(subsystem: "com.a7med7x7.peeko", category: "github")

public protocol HTTPClient: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionHTTPClient: HTTPClient {
    private let session: URLSession

    public init() {
        // No URLCache: it can answer our If-None-Match itself and hide the 304.
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 15
        session = URLSession(configuration: config)
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}

public struct GitHubEvent: Decodable, Equatable, Sendable {
    public var type: String
    public var createdAt: Date

    enum CodingKeys: String, CodingKey {
        case type
        case createdAt = "created_at"
    }
}

/// Fetches a user's public events at most once per `pollInterval`, reusing the ETag so unchanged
/// replies come back as a body-less 304. Unauthenticated 304s still count against the 60/hour limit;
/// the 10-minute poll keeps us at 6/hour. With a token for that user's own account, it asks for all
/// their events instead, so pushes to private repos count too.
public actor GitHubEventsClient {
    public static let pollInterval: TimeInterval = 600

    private struct Entry {
        var etag: String?
        var events: [GitHubEvent]?
        var fetchedAt: Date
    }

    private let http: any HTTPClient
    private var token: String?
    private var entries: [String: Entry] = [:]
    private var problems: [String: String] = [:]
    public private(set) var requestCount = 0

    public init(http: any HTTPClient) {
        self.http = http
    }

    /// Blank clears it. A change drops cached replies, since the endpoint and ETags differ.
    public func setToken(_ token: String?) {
        let trimmed = token?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let next = trimmed.isEmpty ? nil : trimmed
        guard next != self.token else { return }
        self.token = next
        entries = [:]
        problems = [:]
    }

    /// nil until the first successful fetch for this user.
    public func events(for username: String, now: Date) async -> [GitHubEvent]? {
        let key = username.lowercased()
        var entry = entries[key] ?? Entry(fetchedAt: .distantPast)
        if now.timeIntervalSince(entry.fetchedAt) < Self.pollInterval { return entry.events }
        guard let request = Self.request(for: username, etag: entry.etag, token: token) else { return nil }

        // Claim the slot before awaiting so concurrent callers reuse the cache instead of refetching.
        entry.fetchedAt = now
        entries[key] = entry
        requestCount += 1

        do {
            let (data, response) = try await http.send(request)
            let remaining = response.value(forHTTPHeaderField: "X-RateLimit-Remaining") ?? "?"
            if response.statusCode == 200 {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let events = try decoder.decode([GitHubEvent].self, from: data)
                entries[key]?.events = events
                entries[key]?.etag = response.value(forHTTPHeaderField: "ETag")
                log.info("\(username, privacy: .public): 200, \(events.count) events, rate limit left \(remaining, privacy: .public)")
                problems[key] = nil
            } else {
                // 304 keeps the cached events; anything else is retried at the next poll.
                log.info("\(username, privacy: .public): \(response.statusCode), rate limit left \(remaining, privacy: .public)")
                problems[key] = Self.problem(forStatus: response.statusCode)
            }
        } catch {
            // Offline, blocked by a firewall, or a bad payload: keep what we had and retry at the next poll.
            log.error("\(username, privacy: .public): request failed: \(error.localizedDescription, privacy: .public)")
            problems[key] = error is DecodingError
                ? "GitHub sent something unexpected"
                : "can't reach GitHub · offline or a firewall?"
        }
        return entries[key]?.events
    }

    /// What went wrong with the last request for this user, in words for the UI. nil when fine.
    public func problem(for username: String) -> String? {
        problems[username.lowercased()]
    }

    static func problem(forStatus status: Int) -> String? {
        switch status {
        case 200, 304: nil
        case 401: "GitHub didn't accept your token"
        case 404: "GitHub doesn't know that username"
        case 403, 429: "GitHub's rate limit · trying again soon"
        default: "GitHub answered \(status) · trying again soon"
        }
    }

    static func request(for username: String, etag: String?, token: String? = nil) -> URLRequest? {
        // Authenticated as that user, /events also lists their private events; /events/public never does.
        let path = token == nil ? "events/public" : "events"
        guard isValidUsername(username),
              let url = URL(string: "https://api.github.com/users/\(username)/\(path)?per_page=100")
        else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Peeko-App", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        return request
    }

    public static func isValidUsername(_ name: String) -> Bool {
        name.range(of: "^[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})$", options: .regularExpression) != nil
    }
}

public struct GitHubPushVerifier: Verifier {
    public let definition: TaskDefinition
    let username: String
    let client: GitHubEventsClient
    let calendar: Calendar

    public init(definition: TaskDefinition, username: String, client: GitHubEventsClient, calendar: Calendar) {
        self.definition = definition
        self.username = username
        self.client = client
        self.calendar = calendar
    }

    public func evaluate(context: VerifierContext) async -> TaskStatus {
        if let existing = context.record.statuses[definition.id], existing.isDone {
            return existing
        }
        guard !username.isEmpty,
              let events = await client.events(for: username, now: context.now)
        else { return .pending }

        // created_at is UTC; compare against today in the user's calendar, never by string.
        let firstPushToday = events
            .filter { $0.type == "PushEvent" && calendar.isDate($0.createdAt, inSameDayAs: context.now) }
            .map(\.createdAt)
            .min()
        return firstPushToday.map { .done(at: $0) } ?? .pending
    }
}
