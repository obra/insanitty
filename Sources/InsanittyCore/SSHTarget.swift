import Foundation

/// Parses the `[user@]host[:port]` an attach picker accepts, mirroring Fantastty's host parse:
/// `@` separates the user, the last `:` separates the port (a valid integer, else ignored).
public enum SSHTarget {
    /// Returns the SSH target (`[user@]host`) + optional port, or nil for blank input (local).
    public static func parse(_ s: String) -> (target: String, port: Int?)? {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        if let colon = t.lastIndex(of: ":"), let port = Int(t[t.index(after: colon)...]) {
            return (String(t[..<colon]), port)
        }
        return (t, nil)
    }

    /// The argv for reaching a session over this target in tmux control mode:
    /// `ssh -t [-p port] target tmux -CC attach-session -t <session>`.
    public static func controlArgv(target: String, port: Int?, session: String) -> [String] {
        ["ssh", "-t"] + (port.map { ["-p", String($0)] } ?? []) + [target, "tmux", "-CC", "attach-session", "-t", session]
    }
}
