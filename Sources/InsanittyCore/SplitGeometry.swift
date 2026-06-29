// Layout-oracle constants ported from Fantastty's split system (Splits/SplitView.swift,
// Splits/SplitTree.swift; see docs/SPEC.md §3.3 and docs/research/05-ui-views.md §2.1).
// These exist to prevent a real pane-collapse bug and to keep tmux layouts stable; the
// Linux GtkPaned-based renderer MUST reproduce them. Guarded by SplitLayoutPipelineTests
// upstream — keep those as the porting oracle.

public enum SplitGeometry {
    /// Minimum pane extent along the split axis, in points (~2 cell rows).
    public static let minPaneSize: Double = 34.0

    /// Ratio clamp for keyboard/programmatic resize.
    public static let interactiveRatioRange: ClosedRange<Double> = 0.1...0.9

    /// Ratio clamp when mapping tmux layout strings into the split tree.
    public static let tmuxRatioRange: ClosedRange<Double> = 0.05...0.95

    /// New splits start centered.
    public static let defaultRatio: Double = 0.5

    public static func clampInteractive(_ ratio: Double) -> Double {
        min(max(ratio, interactiveRatioRange.lowerBound), interactiveRatioRange.upperBound)
    }

    public static func clampTmux(_ ratio: Double) -> Double {
        min(max(ratio, tmuxRatioRange.lowerBound), tmuxRatioRange.upperBound)
    }

    /// Split a total extent into (first, second) honoring `minPaneSize` so neither pane
    /// collapses. Mirrors the SplitView pixel-allocation the oracle tests guard.
    public static func allocate(total: Double, ratio: Double) -> (Double, Double) {
        guard total > 2 * minPaneSize else {
            let half = total / 2
            return (half, total - half)
        }
        let first = min(max(total * ratio, minPaneSize), total - minPaneSize)
        return (first, total - first)
    }
}
