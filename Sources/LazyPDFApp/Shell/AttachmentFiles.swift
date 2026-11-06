import Foundation

// Follows windows/LazyPDF.App/Services/AttachmentFiles.cs: names for the copies made of files carried inside a PDF, and
// which of them could start a program.

public enum AttachmentFiles {
    private static let programs: Set<String> = [
        "exe", "com", "bat", "cmd", "msi", "msp", "ps1", "vbs", "vbe", "js", "jse", "wsf", "wsh", "scr",
        "lnk", "url", "hta", "jar", "reg", "dll", "cpl", "msc", "pif", "chm", "application", "appref-ms",
        "jnlp", "diagcab", "settingcontent-ms",
        "app", "command", "sh", "pkg", "dmg", "workflow", "action", "terminal", "scpt", "scptd", "webloc", "inetloc", "ipa",
    ]

    private static let refused: Set<Character> = ["<", ">", ":", "\"", "/", "\\", "|", "?", "*"]

    /// The file name only, with characters a file system may refuse replaced. Trailing dots and spaces are dropped (Windows
    /// drops them when it writes a file), so the name checked is the name written.
    public static func safeName(_ name: String) -> String {
        let leaf = name.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
        let clean = String(leaf.map { refused.contains($0) || ($0.asciiValue ?? 32) < 32 ? "_" : $0 })
        return String(clean.reversed().drop(while: { $0 == "." || $0 == " " }).reversed())
    }

    public static func couldRun(_ safeName: String) -> Bool {
        guard let dot = safeName.lastIndex(of: ".") else { return false }
        return programs.contains(safeName[safeName.index(after: dot)...].lowercased())
    }
}
