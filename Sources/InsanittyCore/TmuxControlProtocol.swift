import Foundation

/// A parsed `tmux -CC` control-mode notification. tmux emits one `%`-prefixed line per event on
/// the control client's stdout; this is the typed form the app acts on. Only the notifications
/// insanitty renders are modelled; anything else becomes `.other`.
public enum TmuxControlEvent: Equatable {
    /// `%output %<pane> <octal-escaped bytes>` — terminal output for a pane.
    case output(pane: Int, bytes: [UInt8])
    /// `%window-add @<window>`
    case windowAdd(window: Int)
    /// `%window-close @<window>`
    case windowClose(window: Int)
    /// `%window-renamed @<window> <name>`
    case windowRenamed(window: Int, name: String)
    /// `%layout-change @<window> <layout> ...`
    case layoutChange(window: Int, layout: String)
    /// `%window-pane-changed @<window> %<pane>` — the active pane of a window changed.
    case windowPaneChanged(window: Int, pane: Int)
    /// `%session-window-changed $<session> @<window>` — the session's active window changed.
    case sessionWindowChanged(window: Int)
    /// `%begin <ts> <num> <flags>` — start of a command-response block.
    case begin(number: Int)
    /// `%end <ts> <num> <flags>` — successful end of a command-response block.
    case end(number: Int)
    /// `%error <ts> <num> <flags>` — failed end of a command-response block.
    case error(number: Int)
    /// `%exit [reason]` — the control client is detaching/exiting.
    case exit(reason: String?)
    /// A recognised-but-unmodelled `%notification`, or a payload line inside a `%begin…%end` block.
    case other(String)
}

/// Parses `tmux -CC` control-mode lines into `TmuxControlEvent`s. Stateless: one line in, one
/// event out (matching tmux's line-oriented control protocol).
public enum TmuxControlParser {
    public static func parse(line rawLine: String) -> TmuxControlEvent {
        // tmux terminates control lines with CRLF; tolerate a trailing CR.
        let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
        guard line.hasPrefix("%") else { return .other(line) }

        // Split into the "%verb" and the remainder (preserving spaces in the remainder).
        let firstSpace = line.firstIndex(of: " ")
        let verb = firstSpace.map { String(line[line.startIndex..<$0]) } ?? line
        let rest = firstSpace.map { String(line[line.index(after: $0)...]) } ?? ""

        switch verb {
        case "%output":
            // %output %<pane> <data...>  (data is octal-escaped, may contain spaces)
            guard let (pane, data) = splitPaneAndData(rest) else { return .other(line) }
            return .output(pane: pane, bytes: decodeOctalEscapes(data))
        case "%window-add":
            return atID(rest).map { .windowAdd(window: $0) } ?? .other(line)
        case "%window-close", "%unlinked-window-close":
            return atID(rest).map { .windowClose(window: $0) } ?? .other(line)
        case "%window-renamed":
            let (head, tail) = firstToken(rest)
            return atID(head).map { .windowRenamed(window: $0, name: tail) } ?? .other(line)
        case "%layout-change":
            let (head, tail) = firstToken(rest)
            // The layout is the first token of the tail (visible-layout + flags follow).
            let layout = firstToken(tail).0
            return atID(head).map { .layoutChange(window: $0, layout: layout) } ?? .other(line)
        case "%window-pane-changed":
            let (head, tail) = firstToken(rest)
            guard let w = atID(head), let p = percentID(firstToken(tail).0) else { return .other(line) }
            return .windowPaneChanged(window: w, pane: p)
        case "%session-window-changed":
            // %session-window-changed $<session> @<window>
            let (_, tail) = firstToken(rest)
            return atID(firstToken(tail).0).map { .sessionWindowChanged(window: $0) } ?? .other(line)
        case "%begin":
            return blockNumber(rest).map { .begin(number: $0) } ?? .other(line)
        case "%end":
            return blockNumber(rest).map { .end(number: $0) } ?? .other(line)
        case "%error":
            return blockNumber(rest).map { .error(number: $0) } ?? .other(line)
        case "%exit":
            return .exit(reason: rest.isEmpty ? nil : rest)
        default:
            return .other(line)
        }
    }

    /// `%output %<pane> <data>` → (pane, rawData). The pane token is `%N`; data is the rest.
    private static func splitPaneAndData(_ rest: String) -> (Int, String)? {
        let (head, tail) = firstToken(rest)
        guard let pane = percentID(head) else { return nil }
        return (pane, tail)
    }

    /// First space-delimited token and the untouched remainder after the single separating space.
    private static func firstToken(_ s: String) -> (String, String) {
        guard let sp = s.firstIndex(of: " ") else { return (s, "") }
        return (String(s[s.startIndex..<sp]), String(s[s.index(after: sp)...]))
    }

    /// `@<n>` → n
    private static func atID(_ token: String) -> Int? {
        token.hasPrefix("@") ? Int(token.dropFirst()) : nil
    }

    /// `%<n>` → n
    private static func percentID(_ token: String) -> Int? {
        token.hasPrefix("%") ? Int(token.dropFirst()) : nil
    }

    /// The middle field (`<num>`) of a `%begin/%end/%error <ts> <num> <flags>` line.
    private static func blockNumber(_ rest: String) -> Int? {
        let parts = rest.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        return parts.count >= 2 ? Int(parts[1]) : nil
    }

    /// Decodes tmux's `\ooo` octal escapes (used in `%output` data) to raw bytes. Non-escape
    /// bytes pass through; a backslash not followed by three octal digits is kept literally.
    public static func decodeOctalEscapes(_ s: String) -> [UInt8] {
        let src = Array(s.utf8)
        var out: [UInt8] = []
        out.reserveCapacity(src.count)
        var i = 0
        func isOctal(_ b: UInt8) -> Bool { b >= 0x30 && b <= 0x37 }
        while i < src.count {
            // A backslash followed by exactly three octal digits is one escaped byte.
            if src[i] == 0x5C, i + 3 <= src.count - 1,
               isOctal(src[i+1]), isOctal(src[i+2]), isOctal(src[i+3]) {
                let value = (Int(src[i+1] - 0x30) << 6) | (Int(src[i+2] - 0x30) << 3) | Int(src[i+3] - 0x30)
                out.append(UInt8(value & 0xFF))
                i += 4
                continue
            }
            out.append(src[i])
            i += 1
        }
        return out
    }
}
