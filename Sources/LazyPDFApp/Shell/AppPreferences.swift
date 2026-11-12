import Foundation

// Follows windows/LazyPDF.App/Services/AppPreferences.cs.

/// Light, dark, or whatever the system is set to. The first case is the default.
public enum AppAppearance: String, Codable, Sendable {
    case system
    case light
    case dark
}

/// What the app remembers about its own window.
public struct AppPreferences: Codable, Equatable {
    public var appearance = AppAppearance.system

    /// The side panel left open; empty when the rail is collapsed.
    public var sidePanel = "pages"

    /// Which inspector sections the user left open or closed: a tool's own key, open. No entry is the default.
    public var inspectorSections: [String: Bool] = [:]

    /// The viewer's page tint and arrangement, kept for the next launch.
    public var tint = PageTint.none
    public var columns = 1
    public var cover = false
    public var continuous = true

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case appearance, sidePanel, inspectorSections, tint, columns, cover, continuous
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        appearance = c.decodeLenient(forKey: .appearance, default: appearance)
        sidePanel = c.decodeLenient(forKey: .sidePanel, default: sidePanel)
        inspectorSections = c.decodeLenient(forKey: .inspectorSections, default: inspectorSections)
        tint = c.decodeLenient(forKey: .tint, default: tint)
        columns = c.decodeLenient(forKey: .columns, default: columns)
        cover = c.decodeLenient(forKey: .cover, default: cover)
        continuous = c.decodeLenient(forKey: .continuous, default: continuous)
    }
}

/// preferences.json in the settings folder, read and written by the rules of Lazy Scan's settings files.
public enum AppPreferencesStore {
    private static func file(_ directory: URL) -> URL {
        directory.appendingPathComponent("preferences.json")
    }

    public static func load(_ directory: URL) -> AppPreferences {
        StoreFiles.load(AppPreferences.self, from: file(directory)) ?? AppPreferences()
    }

    /// Reads the file again, applies `change` and saves, so each part of the app changes only its own preference.
    public static func update(_ directory: URL, _ change: (inout AppPreferences) -> Void) {
        var preferences = load(directory)
        change(&preferences)
        StoreFiles.write(preferences, to: file(directory))
    }
}
