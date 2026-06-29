import Foundation

// Ported from Fantastty's remote-engine bootstrap-line parser
// (`RemoteEngineBootstrapLine.parse`, RemoteEngineClient.swift:21; see docs/SPEC.md §4.3
// and docs/research/07-remote-engine-client.md §3.3). The Go helper prints exactly one
// line of QUIC attach material on stdout after `launch-or-resume`:
//
//   FANTASTTY_REMOTE port=<n> session=<64hex> key=<64hex> expires=<RFC3339> \
//     helper_pid=<n> version=<v> arch=<a> quic_addr=<host:port|[v6]:port> \
//     quic_cert_sha256=<64hex> quic_alpn=fantastty-remote-engine-v1
//
// Parsing rules (faithful to the macOS client): the leading token must be
// `FANTASTTY_REMOTE`; the rest are `key=value`; `session`/`key`/`quic_cert_sha256` must be
// 64-char lowercase hex; host:port comes from `quic_addr` (the `port=` field is ignored);
// unknown fields are tolerated. The client later rewrites `host` to its own advertise host.

public struct RemoteBootstrapLine: Equatable, Sendable {
    public let host: String
    public let port: UInt16
    public let session: String
    public let key: String
    public let certSHA256: String
    public let alpn: String
    public let version: String?
    public let arch: String?
    public let helperPID: Int?
    public let expires: Date?

    public enum ParseError: Error, Equatable {
        case missingPrefix
        case missingField(String)
        case malformedHex(String)
        case malformedAddr(String)
    }

    public static func parse(_ line: String) throws -> RemoteBootstrapLine {
        let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard let first = tokens.first, first == "FANTASTTY_REMOTE" else {
            throw ParseError.missingPrefix
        }
        var fields: [String: String] = [:]
        for tok in tokens.dropFirst() {
            guard let eq = tok.firstIndex(of: "=") else { continue }
            fields[String(tok[..<eq])] = String(tok[tok.index(after: eq)...])
        }

        func required(_ k: String) throws -> String {
            guard let v = fields[k], !v.isEmpty else { throw ParseError.missingField(k) }
            return v
        }
        func hex64(_ k: String) throws -> String {
            let v = try required(k)
            guard isHex64(v) else { throw ParseError.malformedHex(k) }
            return v
        }

        let session = try hex64("session")
        let key = try hex64("key")
        let cert = try hex64("quic_cert_sha256")
        let (host, port) = try parseAddr(try required("quic_addr"))

        return RemoteBootstrapLine(
            host: host,
            port: port,
            session: session,
            key: key,
            certSHA256: cert,
            alpn: fields["quic_alpn"] ?? "fantastty-remote-engine-v1",
            version: fields["version"],
            arch: fields["arch"],
            helperPID: fields["helper_pid"].flatMap(Int.init),
            expires: fields["expires"].flatMap(Self.parseRFC3339)
        )
    }

    static func isHex64(_ s: String) -> Bool {
        s.count == 64 && s.allSatisfy { $0.isHexDigit && ($0.isNumber || $0.isLowercase) }
    }

    /// `host:port`, including bracketed IPv6 `[::1]:443`.
    static func parseAddr(_ addr: String) throws -> (String, UInt16) {
        if addr.hasPrefix("[") {
            guard let close = addr.firstIndex(of: "]"),
                  addr[addr.index(after: close)...].first == ":",
                  let port = UInt16(addr[addr.index(close, offsetBy: 2)...]) else {
                throw ParseError.malformedAddr(addr)
            }
            return (String(addr[addr.index(after: addr.startIndex)..<close]), port)
        }
        guard let colon = addr.lastIndex(of: ":"),
              let port = UInt16(addr[addr.index(after: colon)...]),
              colon != addr.startIndex else {
            throw ParseError.malformedAddr(addr)
        }
        return (String(addr[..<colon]), port)
    }

    static func parseRFC3339(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s)
    }
}
