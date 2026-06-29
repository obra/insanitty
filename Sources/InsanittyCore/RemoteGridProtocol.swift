import Foundation

// Ported from Fantastty's `RemoteGridProtocol.swift` (see docs/SPEC.md §4.3 and
// docs/research/07-remote-engine-client.md). This is the wire contract the remote-engine
// helper streams over QUIC. Swift's synthesized enum Codable produces the same
// `{"<case>":{"_0":<payload>}}` shape the Go helper hand-mirrors, so these decode the real
// helper output directly (verified by RemoteGridProtocolTests against a live payload).

public enum RemoteWorkspaceMessage: Decodable, Sendable {
    case workspaceSnapshot(WorkspaceSnapshot)
    case paneKeyframe(PaneKeyframe)
    case paneDelta(PaneDelta)
    case unsupportedPaneState(UnsupportedPaneState)
}

public struct WorkspaceSnapshot: Decodable, Sendable {
    public let workspaceID: String
    public let layoutGeneration: UInt64
    public let windows: [WorkspaceWindow]
    public let panes: [WorkspacePane]
}

public struct WorkspaceWindow: Decodable, Sendable {
    public let windowID: Int
    public let title: String
    public let index: Int?
    public let isActive: Bool
    public let layout: String?
}

public struct WorkspacePane: Decodable, Sendable {
    public let paneID: Int
    public let windowID: Int
    public let isActive: Bool
    public let frame: PaneFrame
}

public struct PaneFrame: Decodable, Sendable {
    public let x: Int
    public let y: Int
    public let columns: Int
    public let rows: Int
}

public struct GridSize: Decodable, Sendable {
    public let columns: Int
    public let rows: Int
}

public struct PaneKeyframe: Decodable, Sendable {
    public let workspaceID: String
    public let paneID: Int
    public let paneGeneration: UInt64
    public let keyframeID: UInt64
    public let gridSize: GridSize
    public let rows: [GridRow]
    public let cursor: CursorState
    public let activeScreen: ActiveScreen
    public let datagramsEnabledAfterKeyframe: Bool
}

public struct PaneDelta: Decodable, Sendable {
    public let workspaceID: String
    public let paneID: Int
    public let paneGeneration: UInt64
    public let baseKeyframeID: UInt64
    public let deltaSequence: UInt64
    public let cursor: CursorState?
}

public struct UnsupportedPaneState: Decodable, Sendable {
    public let workspaceID: String
    public let paneID: Int
    public let paneGeneration: UInt64
    public let reason: String
    public let fallback: String
}

/// A row, in either the full (`cells`) or compact (`text`) encoding. The helper emits compact
/// when every cell is a width-1 normal-style cell; we normalize both to `cells`.
public struct GridRow: Decodable, Sendable {
    public let index: Int
    public let rowVersion: UInt64
    public let cells: [GridCell]

    enum CodingKeys: String, CodingKey { case index, rowVersion, cells, text }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        index = try c.decode(Int.self, forKey: .index)
        rowVersion = try c.decode(UInt64.self, forKey: .rowVersion)
        if let cs = try c.decodeIfPresent([GridCell].self, forKey: .cells) {
            cells = cs
        } else {
            let text = try c.decode(String.self, forKey: .text)
            cells = text.unicodeScalars.map { GridCell(text: String($0), width: 1, style: .normal) }
        }
    }
}

public struct GridCell: Decodable, Sendable {
    public let text: String
    public let width: Int
    public let style: CellStyle
    public init(text: String, width: Int, style: CellStyle) {
        self.text = text; self.width = width; self.style = style
    }
}

public struct CellStyle: Decodable, Sendable {
    public let foreground: Color
    public let background: Color
    public let underlineColor: Color
    public let bold: Bool
    public let faint: Bool
    public let italic: Bool
    public let blink: Bool
    public let inverse: Bool
    public let invisible: Bool
    public let strikethrough: Bool
    public let underline: Underline

    public static let normal = CellStyle(
        foreground: .default, background: .default, underlineColor: .default,
        bold: false, faint: false, italic: false, blink: false,
        inverse: false, invisible: false, strikethrough: false, underline: .none)

    public init(foreground: Color, background: Color, underlineColor: Color, bold: Bool,
                faint: Bool, italic: Bool, blink: Bool, inverse: Bool, invisible: Bool,
                strikethrough: Bool, underline: Underline) {
        self.foreground = foreground; self.background = background
        self.underlineColor = underlineColor; self.bold = bold; self.faint = faint
        self.italic = italic; self.blink = blink; self.inverse = inverse
        self.invisible = invisible; self.strikethrough = strikethrough; self.underline = underline
    }
}

public enum Color: Decodable, Sendable, Equatable {
    case `default`
    case indexed(UInt8)
    case rgb(red: UInt8, green: UInt8, blue: UInt8)
}

public enum Underline: String, Decodable, Sendable {
    case none, single, double, curly, dotted, dashed
}

public enum ActiveScreen: String, Decodable, Sendable {
    case primary, alternate
}

public enum CursorShape: String, Decodable, Sendable {
    case block, bar, underline
}

public struct CursorState: Decodable, Sendable {
    public let row: Int
    public let column: Int
    public let visible: Bool
    public let shape: CursorShape
    public let cursorVersion: UInt64
}

public enum RemoteGridProtocol {
    /// Decode one newline-delimited JSON message (the helper's reliable-stream framing).
    public static func decode(line: String) throws -> RemoteWorkspaceMessage {
        try JSONDecoder().decode(RemoteWorkspaceMessage.self, from: Data(line.utf8))
    }
}
