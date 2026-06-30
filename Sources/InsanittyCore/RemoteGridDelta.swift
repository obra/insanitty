import Foundation

/// A change to a single row in a pane, as carried by a `paneDelta` (QUIC datagram). Mirrors the
/// helper's `RowUpdate` / `RowUpdateBody` tagged union (`fullRow._0` cells, `fullRowText._0` text,
/// or `span`).
public struct RowUpdate: Decodable, Sendable {
    public let rowIndex: Int
    public let rowVersion: UInt64
    public let update: RowUpdateBody
}

/// A column-range splice within a row (helper's `rowUpdateSpan`).
public struct RowSpan: Decodable, Sendable {
    public let baseRowVersion: UInt64
    public let startColumn: Int
    public let cells: [GridCell]
    public let clearToColumn: Int?
}

public enum RowUpdateBody: Decodable, Sendable {
    case fullRow([GridCell])
    case span(RowSpan)

    enum CodingKeys: String, CodingKey { case fullRow, fullRowText, span }
    enum Wrapped: String, CodingKey { case value = "_0" }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if c.contains(.fullRow) {
            let w = try c.nestedContainer(keyedBy: Wrapped.self, forKey: .fullRow)
            self = .fullRow(try w.decode([GridCell].self, forKey: .value))
        } else if c.contains(.fullRowText) {
            let w = try c.nestedContainer(keyedBy: Wrapped.self, forKey: .fullRowText)
            let text = try w.decode(String.self, forKey: .value)
            self = .fullRow(text.unicodeScalars.map { GridCell(text: String($0), width: 1, style: .normal) })
        } else {
            self = .span(try c.decode(RowSpan.self, forKey: .span))
        }
    }
}

/// Applies `paneDelta` row updates to a keyframe, producing the updated keyframe. Pure, so the
/// app can fold streamed datagram deltas onto the last keyframe and re-render.
public enum RemoteGridDelta {
    public static func apply(_ delta: PaneDelta, to keyframe: PaneKeyframe) -> PaneKeyframe {
        var byIndex = Dictionary(keyframe.rows.map { ($0.index, $0) }, uniquingKeysWith: { $1 })
        for u in delta.rowUpdates {
            let existing = byIndex[u.rowIndex]?.cells ?? []
            let cells: [GridCell]
            switch u.update {
            case .fullRow(let c): cells = c
            case .span(let s): cells = splice(existing, start: s.startColumn, insert: s.cells, clearTo: s.clearToColumn)
            }
            byIndex[u.rowIndex] = GridRow(index: u.rowIndex, rowVersion: u.rowVersion, cells: cells)
        }
        let rows = byIndex.values.sorted { $0.index < $1.index }
        return PaneKeyframe(workspaceID: keyframe.workspaceID, paneID: keyframe.paneID,
                            paneGeneration: keyframe.paneGeneration, keyframeID: keyframe.keyframeID,
                            gridSize: keyframe.gridSize, rows: rows, cursor: delta.cursor ?? keyframe.cursor,
                            activeScreen: keyframe.activeScreen,
                            datagramsEnabledAfterKeyframe: keyframe.datagramsEnabledAfterKeyframe)
    }

    /// Overwrite `existing` cells with `insert` starting at `start` (padding blanks as needed), then
    /// blank everything from `start+insert.count` up to `clearTo` (exclusive) if given.
    static func splice(_ existing: [GridCell], start: Int, insert: [GridCell], clearTo: Int?) -> [GridCell] {
        let blank = GridCell(text: " ", width: 1, style: .normal)
        var cells = existing
        while cells.count < start { cells.append(blank) }
        for (i, cell) in insert.enumerated() {
            let idx = start + i
            if idx < cells.count { cells[idx] = cell } else { cells.append(cell) }
        }
        if let clearTo = clearTo {
            var idx = start + insert.count
            while idx < clearTo {
                if idx < cells.count { cells[idx] = blank } else { cells.append(blank) }
                idx += 1
            }
        }
        return cells
    }
}
