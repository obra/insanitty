import Foundation

// Ported from Fantastty's `LinearService.parseLinearURL` (LinearService.swift:74). Recognizes
// Linear issue/project URLs so the workspace's ticket URL can show live Linear detail. Pure
// (regex) logic; the GraphQL fetch + Keychain→libsecret token live in the app layer.

public enum LinearResource: Equatable, Sendable {
    case issue(identifier: String)
    case project(id: String)
}

public enum LinearURL {
    public static func parse(_ urlString: String) -> LinearResource? {
        if let id = firstGroup(in: urlString, pattern: #"linear\.app/[^/]+/issue/([A-Z]+-\d+)"#) {
            return .issue(identifier: id)
        }
        if let id = firstGroup(in: urlString, pattern: #"linear\.app/[^/]+/project/([^/?#]+)"#) {
            return .project(id: id)
        }
        return nil
    }

    private static func firstGroup(in s: String, pattern: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: s) else { return nil }
        return String(s[r])
    }
}
