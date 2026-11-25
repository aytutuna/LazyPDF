import Foundation

// Follows windows/LazyPDF.App/Services/AppInfo.cs: what the About screen shows.

public enum AppInfo {
    public static let site = "https://alazy.app/pdf/"
    public static let privacyPage = "https://alazy.app/pdf/privacy.html"
    public static let supportAddress = "support@alazy.app"
    public static let noticesFile = "THIRD-PARTY-NOTICES.txt"
    public static let copyright = "Copyright (c) 2026 Aytu Tuna"
    public static let licence = "PolyForm Noncommercial 1.0.0"

    /// The version of the app's bundle.
    public static var version: String { bundleVersion(Bundle.main.infoDictionary) }

    static func bundleVersion(_ info: [String: Any]?) -> String {
        info?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    /// The notices text; nil when the file is not there. It is read from the bundle's resources unless `directory` says
    /// where to look.
    public static func notices(in directory: URL? = nil) -> String? {
        let file = directory?.appendingPathComponent(noticesFile)
            ?? Bundle.main.url(forResource: "THIRD-PARTY-NOTICES", withExtension: "txt")
        return file.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    }
}
