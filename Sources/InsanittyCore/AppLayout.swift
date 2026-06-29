import Foundation

/// One workspace's persisted layout: the tmux session index it reattaches (`tmux new-session
/// -A -s insanitty-ws-<index>`), its display name, and any browser-tab URLs. Terminal tabs are
/// backed by tmux (reattached by index), so they aren't enumerated here.
public struct WorkspaceLayout: Codable, Equatable {
    public var index: Int
    public var name: String
    public var browserURLs: [String]
    public init(index: Int, name: String, browserURLs: [String] = []) {
        self.index = index
        self.name = name
        self.browserURLs = browserURLs
    }
}

/// The persisted app layout: which workspaces exist (in sidebar order) and which is selected.
/// The "remote (QUIC)" demo workspace is not persisted — it's recreated each launch.
public struct AppLayout: Codable, Equatable {
    public var workspaces: [WorkspaceLayout]
    public var selected: Int
    public init(workspaces: [WorkspaceLayout], selected: Int = 0) {
        self.workspaces = workspaces
        self.selected = selected
    }
}

/// Loads and saves `AppLayout` to disk (XDG state).
public enum LayoutStore {
    /// `$XDG_STATE_HOME/insanitty/layout.json` (default `~/.local/state/insanitty/layout.json`).
    /// Session layout is "state that persists between restarts", which XDG places under STATE.
    public static func defaultURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: String = NSHomeDirectory()
    ) -> URL {
        let base = environment["XDG_STATE_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? "\(home)/.local/state"
        return URL(fileURLWithPath: base).appendingPathComponent("insanitty/layout.json")
    }

    /// Returns the decoded layout, or nil if the file is missing or unreadable.
    public static func load(from url: URL) -> AppLayout? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(AppLayout.self, from: data)
    }

    /// Atomically writes the layout, creating the parent directory as needed.
    public static func save(_ layout: AppLayout, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(layout).write(to: url, options: .atomic)
    }
}
