import Foundation

/// Renders a remote pane keyframe as an ANSI byte stream that paints the grid when written into a
/// terminal — the native Swift replacement for the demo's Python renderer. The bytes are injected
/// into a Ghostty surface (`insanitty_surface_inject_output`).
public enum RemoteGridRenderer {
    public static func ansi(for keyframe: PaneKeyframe) -> String {
        var out = "\u{1b}[2J\u{1b}[H"  // clear screen + home
        for row in keyframe.rows.sorted(by: { $0.index < $1.index }) {
            out += "\u{1b}[\(row.index + 1);1H\u{1b}[0m"  // move to row (1-based), reset style
            var current = CellStyle.normal
            for cell in row.cells {
                if !stylesEqual(cell.style, current) {
                    out += sgr(for: cell.style)
                    current = cell.style
                }
                out += cell.text.isEmpty ? " " : cell.text
            }
            out += "\u{1b}[0m"
        }
        out += "\u{1b}[\(keyframe.cursor.row + 1);\(keyframe.cursor.column + 1)H"  // cursor
        out += keyframe.cursor.visible ? "\u{1b}[?25h" : "\u{1b}[?25l"
        out += decscusr(for: keyframe.cursor.shape)  // cursor shape (block/bar/underline)
        return out
    }

    /// A clear-screen banner shown when the helper reports a pane it can't render
    /// (`unsupportedPaneState`) with a blank/diagnostic fallback — so the user sees *why* a pane is
    /// blank instead of an empty rectangle. Reason/fallback come straight from the helper.
    public static func unsupportedBanner(reason: String, fallback: String) -> String {
        "\u{1b}[2J\u{1b}[H\u{1b}[0m\u{1b}[33m⚠ remote pane unavailable\u{1b}[0m\r\n"
            + "  reason: \(reason)\r\n  fallback: \(fallback)\r\n"
    }

    /// DECSCUSR (`ESC[ <n> SP q`) for the cursor shape — steady block/underline/bar.
    static func decscusr(for shape: CursorShape) -> String {
        switch shape {
        case .block: return "\u{1b}[2 q"
        case .underline: return "\u{1b}[4 q"
        case .bar: return "\u{1b}[6 q"
        }
    }

    /// The SGR (`ESC[…m`) sequence for a cell style — a reset followed by the active attributes.
    static func sgr(for style: CellStyle) -> String {
        var codes = ["0"]
        if style.bold { codes.append("1") }
        if style.faint { codes.append("2") }
        if style.italic { codes.append("3") }
        if style.underline != .none { codes.append("4") }
        if style.blink { codes.append("5") }
        if style.inverse { codes.append("7") }
        if style.invisible { codes.append("8") }
        if style.strikethrough { codes.append("9") }
        codes += colorCodes(style.foreground, fg: true)
        codes += colorCodes(style.background, fg: false)
        return "\u{1b}[\(codes.joined(separator: ";"))m"
    }

    static func colorCodes(_ color: Color, fg: Bool) -> [String] {
        switch color {
        case .default: return [fg ? "39" : "49"]
        case .indexed(let n): return [fg ? "38" : "48", "5", "\(n)"]
        case .rgb(let r, let g, let b): return [fg ? "38" : "48", "2", "\(r)", "\(g)", "\(b)"]
        }
    }

    static func stylesEqual(_ a: CellStyle, _ b: CellStyle) -> Bool {
        a.foreground == b.foreground && a.background == b.background && a.bold == b.bold
            && a.faint == b.faint && a.italic == b.italic && a.blink == b.blink
            && a.inverse == b.inverse && a.invisible == b.invisible
            && a.strikethrough == b.strikethrough && a.underline == b.underline
    }
}
