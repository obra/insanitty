// Ported from Fantastty `SessionManager.generateWorkspaceName()`
// (inspo/fantastty/Fantastty/Models/SessionManager.swift:403). Platform-neutral.

/// Generates friendly `adjective-noun` workspace names (e.g. `bold-falcon`).
/// 20 × 20 = 400 combinations, matching Fantastty's lists exactly.
public enum WorkspaceName {
    public static let adjectives = [
        "swift", "bold", "calm", "keen", "warm", "bright", "quick",
        "fresh", "sharp", "steady", "clear", "deep", "light", "golden",
        "silver", "amber", "coral", "jade", "sage", "iron",
    ]
    public static let nouns = [
        "falcon", "harbor", "maple", "spark", "wave", "cedar", "ridge",
        "brook", "mesa", "dusk", "pine", "reef", "cove", "peak", "vale",
        "moss", "flint", "glade", "drift", "helm",
    ]

    /// Deterministic generation (injectable RNG) — used by tests and reproducible flows.
    public static func generate<R: RandomNumberGenerator>(using rng: inout R) -> String {
        let a = adjectives.randomElement(using: &rng)!
        let n = nouns.randomElement(using: &rng)!
        return "\(a)-\(n)"
    }

    /// Convenience using the system RNG (matches Fantastty's `randomElement()`).
    public static func generate() -> String {
        var rng = SystemRandomNumberGenerator()
        return generate(using: &rng)
    }

    /// Whether `name` is a well-formed `adjective-noun` from our vocabulary.
    public static func isWellFormed(_ name: String) -> Bool {
        let parts = name.split(separator: "-", maxSplits: 1)
        guard parts.count == 2 else { return false }
        return adjectives.contains(String(parts[0])) && nouns.contains(String(parts[1]))
    }
}
