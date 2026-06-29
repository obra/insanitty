import Foundation

/// The user's preferred app appearance, persisted in settings.json and applied to the libadwaita
/// chrome (and Ghostty surfaces). Mirrors Fantastty's `AppearanceMode`.
public enum AppearanceMode: String, Codable, CaseIterable, Equatable {
    case system
    case light
    case dark

    /// Display name for the settings picker.
    public var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
}

/// User preferences, persisted to XDG state (`settings.json`). Keys mirror Fantastty's SettingsView.
public struct Settings: Codable, Equatable {
    public var appearance: AppearanceMode
    public var tabsInSidebar: Bool
    public var persistentSessions: Bool
    public var remotePredictiveEcho: Bool

    public init(appearance: AppearanceMode = .system,
                tabsInSidebar: Bool = false,
                persistentSessions: Bool = false,
                remotePredictiveEcho: Bool = true) {
        self.appearance = appearance
        self.tabsInSidebar = tabsInSidebar
        self.persistentSessions = persistentSessions
        self.remotePredictiveEcho = remotePredictiveEcho
    }

    enum CodingKeys: String, CodingKey {
        case appearance, tabsInSidebar, persistentSessions, remotePredictiveEcho
    }

    /// Tolerant decode: any missing key falls back to its default, so older/newer settings files
    /// (and partial writes) load without error.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings()
        appearance = try c.decodeIfPresent(AppearanceMode.self, forKey: .appearance) ?? d.appearance
        tabsInSidebar = try c.decodeIfPresent(Bool.self, forKey: .tabsInSidebar) ?? d.tabsInSidebar
        persistentSessions = try c.decodeIfPresent(Bool.self, forKey: .persistentSessions) ?? d.persistentSessions
        remotePredictiveEcho = try c.decodeIfPresent(Bool.self, forKey: .remotePredictiveEcho) ?? d.remotePredictiveEcho
    }
}

/// Loads and saves `Settings` to disk (XDG state), mirroring `LayoutStore`.
public enum SettingsStore {
    /// `$XDG_STATE_HOME/insanitty/settings.json` (default `~/.local/state/insanitty/settings.json`).
    public static func defaultURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: String = NSHomeDirectory()
    ) -> URL {
        let base = environment["XDG_STATE_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? "\(home)/.local/state"
        return URL(fileURLWithPath: base).appendingPathComponent("insanitty/settings.json")
    }

    /// Returns the decoded settings, or defaults if the file is missing or unreadable.
    public static func load(from url: URL) -> Settings {
        guard let data = try? Data(contentsOf: url),
              let s = try? JSONDecoder().decode(Settings.self, from: data) else { return Settings() }
        return s
    }

    /// Atomically writes the settings, creating the parent directory as needed.
    public static func save(_ settings: Settings, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(settings).write(to: url, options: .atomic)
    }
}
