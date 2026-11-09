import Foundation

// Follows windows/LazyPDF.App/Tools/Create/TextFiles.cs.

public enum TextFiles {
    /// The most a text box takes before typing in it stalls.
    public static let mostBytes = 1 << 20

    /// UTF-8, or the encoding a byte order mark names; anything else is read in the code page the language of the system uses,
    /// Windows-1254 for Turkish.
    public static func decode(_ bytes: [UInt8], language: String? = nil) -> String {
        let data = Data(bytes)
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { return String(decoding: bytes.dropFirst(3), as: UTF8.self) }
        if bytes.starts(with: [0xFF, 0xFE]) { return String(data: data.dropFirst(2), encoding: .utf16LittleEndian) ?? "" }
        if bytes.starts(with: [0xFE, 0xFF]) { return String(data: data.dropFirst(2), encoding: .utf16BigEndian) ?? "" }
        if let text = String(data: data, encoding: .utf8) { return text }
        return String(data: data, encoding: legacy(language ?? Locale.preferredLanguages.first ?? "en")) ?? String(decoding: bytes, as: UTF8.self)
    }

    private static func legacy(_ language: String) -> String.Encoding {
        switch language.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? "en" {
        case "tr": return .windowsCP1254
        case "ru", "uk", "bg", "sr", "be": return .windowsCP1251
        case "el": return .windowsCP1253
        case "ar", "fa", "ur": return .windowsCP1256
        case "ja": return .shiftJIS
        default: return .windowsCP1252
        }
    }
}
