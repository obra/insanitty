import Foundation

/// A Linear issue's display fields (subset of Fantastty's `LinearIssue`).
public struct LinearIssue: Equatable, Sendable {
    public let identifier: String
    public let title: String
    public let stateName: String
    public let assigneeName: String?
    public let priorityLabel: String?
    public init(identifier: String, title: String, stateName: String, assigneeName: String?, priorityLabel: String?) {
        self.identifier = identifier; self.title = title; self.stateName = stateName
        self.assigneeName = assigneeName; self.priorityLabel = priorityLabel
    }
}

/// Linear GraphQL contract (endpoint, queries, request body, response parsing) — pure, so it's
/// testable without a key. Mirrors Fantastty's `LinearService` queries.
public enum LinearGraphQL {
    public static let endpoint = "https://api.linear.app/graphql"

    public static func issueQuery(identifier: String) -> String {
        "{ issue(id: \"\(identifier)\") { identifier title state { name } assignee { name } priorityLabel children { nodes { identifier title state { name } } } } }"
    }
    public static func projectQuery(id: String) -> String {
        "{ project(id: \"\(id)\") { name progress targetDate issues(first: 20) { nodes { identifier title state { name } } } } }"
    }
    public static func query(for resource: LinearResource) -> String {
        switch resource {
        case .issue(let id): return issueQuery(identifier: id)
        case .project(let id): return projectQuery(id: id)
        }
    }

    /// The JSON POST body `{"query": …}`.
    public static func requestBody(_ query: String) -> Data {
        (try? JSONSerialization.data(withJSONObject: ["query": query])) ?? Data()
    }

    /// Parse a GraphQL response for an issue query into a `LinearIssue`.
    public static func parseIssue(_ data: Data) -> LinearIssue? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let d = json["data"] as? [String: Any], let issue = d["issue"] as? [String: Any],
              let id = issue["identifier"] as? String, let title = issue["title"] as? String else { return nil }
        let state = (issue["state"] as? [String: Any])?["name"] as? String ?? ""
        let assignee = (issue["assignee"] as? [String: Any])?["name"] as? String
        return LinearIssue(identifier: id, title: title, stateName: state,
                           assigneeName: assignee, priorityLabel: issue["priorityLabel"] as? String)
    }
}

/// Persists the Linear API token. A 0600 file under XDG state (the desktop keyring/libsecret is a
/// drop-in upgrade where a secret service is running); mirrors Fantastty storing it in the keychain.
public enum LinearTokenStore {
    public static func defaultURL(
        environment: [String: String] = ProcessInfo.processInfo.environment, home: String = NSHomeDirectory()
    ) -> URL {
        let base = environment["XDG_STATE_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? "\(home)/.local/state"
        return URL(fileURLWithPath: base).appendingPathComponent("insanitty/linear-token")
    }
    public static func load(from url: URL) -> String? {
        guard let s = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
    public static func save(_ token: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try token.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    public static func clear(at url: URL) { try? FileManager.default.removeItem(at: url) }
}
