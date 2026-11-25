import Foundation

/// The addresses that start Lazy PDF, as on Windows (windows/LazyPDF.App/Services/LazyPdfAddress.cs): `lazypdf:` alone brings
/// the window forward and `lazypdf://open?file=%2FUsers%2Fa%2Fa.pdf` opens that file (repeat `file` for more). A sandboxed
/// build can read such a file only when the system handed it over too, so senders on the Mac and iOS open the file through
/// LaunchServices or the share sheet and use the address for the rest.
public enum LazyPdfAddress {
    public static let scheme = "lazypdf"

    public static func isAddress(_ text: String) -> Bool {
        let trimmed = text.drop { $0.isWhitespace }
        return trimmed.lowercased().hasPrefix(scheme + ":")
    }

    /// The full local paths an address names; none for one that names no file. Paths starting with `//` are skipped, as the
    /// network paths are on Windows.
    public static func parse(_ address: String) -> [URL] {
        guard let query = address.firstIndex(of: "?") else { return [] }
        var files: [URL] = []
        for pair in address[address.index(after: query)...].split(separator: "&") {
            guard let equals = pair.firstIndex(of: "="), pair[..<equals] == "file" else { continue }
            let raw = pair[pair.index(after: equals)...].replacingOccurrences(of: "+", with: " ")
            guard let path = raw.removingPercentEncoding, path.hasPrefix("/"), !path.hasPrefix("//") else { continue }
            files.append(URL(fileURLWithPath: path))
        }
        return files
    }
}
