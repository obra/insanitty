import Foundation

/// A parsed tmux window layout: the tree of panes within one window. tmux encodes layouts as
/// `WxH,X,Y` cells where `{...}` is a left-right (horizontal) split and `[...]` is a top-bottom
/// (vertical) split; a leaf cell ends in `,<paneID>`. insanitty maps this onto its GtkPaned tree.
public indirect enum TmuxLayoutNode: Equatable {
    case leaf(pane: Int)
    case horizontal([TmuxLayoutNode])  // `{}` — children laid out left to right
    case vertical([TmuxLayoutNode])    // `[]` — children laid out top to bottom

    /// All pane IDs in this subtree, left-to-right / top-to-bottom.
    public func allPanes() -> [Int] {
        switch self {
        case .leaf(let p): return [p]
        case .horizontal(let kids), .vertical(let kids): return kids.flatMap { $0.allPanes() }
        }
    }
}

/// Recursive-descent parser for tmux `#{window_layout}` strings.
public enum TmuxLayoutParser {
    public static func parse(_ layout: String) -> TmuxLayoutNode? {
        var chars = Array(layout)
        // A full window layout is prefixed with a hex checksum: `<csum>,<cell>`. Strip it.
        if let comma = chars.firstIndex(of: ","), comma > 0,
           chars[0..<comma].allSatisfy({ $0.isHexDigit }) {
            chars.removeSubrange(0...comma)
        }
        var pos = 0
        guard let node = parseCell(chars, &pos), pos == chars.count else { return nil }
        return node
    }

    private static func parseCell(_ c: [Character], _ pos: inout Int) -> TmuxLayoutNode? {
        // WxH,X,Y
        guard skipNumber(c, &pos) != nil, expect(c, &pos, "x"),
              skipNumber(c, &pos) != nil, expect(c, &pos, ","),
              skipNumber(c, &pos) != nil, expect(c, &pos, ","),
              skipNumber(c, &pos) != nil, pos < c.count else { return nil }
        switch c[pos] {
        case "{":
            pos += 1
            guard let kids = parseList(c, &pos), expect(c, &pos, "}") else { return nil }
            return .horizontal(kids)
        case "[":
            pos += 1
            guard let kids = parseList(c, &pos), expect(c, &pos, "]") else { return nil }
            return .vertical(kids)
        case ",":
            pos += 1
            guard let pane = skipNumber(c, &pos) else { return nil }
            return .leaf(pane: pane)
        default:
            return nil
        }
    }

    private static func parseList(_ c: [Character], _ pos: inout Int) -> [TmuxLayoutNode]? {
        guard let first = parseCell(c, &pos) else { return nil }
        var nodes = [first]
        while pos < c.count, c[pos] == "," {
            pos += 1
            guard let next = parseCell(c, &pos) else { return nil }
            nodes.append(next)
        }
        return nodes
    }

    private static func skipNumber(_ c: [Character], _ pos: inout Int) -> Int? {
        let start = pos
        while pos < c.count, c[pos].isNumber { pos += 1 }
        guard pos > start else { return nil }
        return Int(String(c[start..<pos]))
    }

    private static func expect(_ c: [Character], _ pos: inout Int, _ ch: Character) -> Bool {
        guard pos < c.count, c[pos] == ch else { return false }
        pos += 1
        return true
    }
}
