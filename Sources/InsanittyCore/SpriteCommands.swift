import Foundation

/// The Fly.io `sprite` CLI contract Fantastty shells out to (`SpriteManager`). Pure command/argv
/// construction so it's testable without the CLI installed.
public enum SpriteCommands {
    /// Candidate `sprite` CLI locations, in priority order (mirrors Fantastty's search list).
    public static func candidatePaths(home: String) -> [String] {
        ["\(home)/.local/bin/sprite", "/usr/local/bin/sprite", "/opt/homebrew/bin/sprite", "\(home)/.fly/bin/sprite"]
    }

    /// The first existing candidate, or nil if the CLI isn't installed.
    public static func resolvePath(home: String, exists: (String) -> Bool) -> String? {
        candidatePaths(home: home).first(where: exists)
    }

    public static let listArgv = ["list"]
    public static func createArgv(name: String?) -> [String] {
        if let name = name, !name.isEmpty { return ["create", name] }
        return ["create"]
    }
    public static func destroyArgv(name: String) -> [String] { ["destroy", "-s", name, "-f"] }

    /// The command run inside the workspace's tmux pane to attach to a sprite's console.
    public static func consoleCommand(spritePath: String, name: String) -> String {
        "\(spritePath) console -s \"\(name)\""
    }
}
