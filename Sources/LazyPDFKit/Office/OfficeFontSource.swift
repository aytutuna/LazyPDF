import Foundation

// Twin of windows/LazyPDF.Core/Office/OfficeFontSource.cs: the converter's font lookup. The font a document names if
// it is installed, else the bundled font with the same metrics, else the bundled default.

public final class OfficeFontSource: FontSource {
    public static let defaultFamily = "Carlito"

    // Office name (lower case) to the bundled family that has the same advance widths.
    private static let compatible: [String: String] = [
        "calibri": "Carlito",
        "cambria": "Caladea",
        "arial": "Liberation Sans",
        "helvetica": "Liberation Sans",
        "times new roman": "Liberation Serif",
        "times": "Liberation Serif",
        "courier new": "Liberation Mono",
        "courier": "Liberation Mono",
    ]

    private let installed: FontSource?
    private let bundled: FontSource?

    private struct LoadedKey: Hashable {
        let family: String
        let style: Int
    }

    private var loaded: [LoadedKey: FontFile] = [:]

    public init(installed: FontSource?, bundled: FontSource?) {
        self.installed = installed
        self.bundled = bundled
    }

    /// The installed source's shaper, if it has one; its files are the ones it can shape.
    public var shaper: Shaper? { installed as? Shaper }

    public func find(_ family: String, _ style: FontStyles) -> FontFile? {
        if let file = installed?.find(family, style) { return file }
        guard let bundled else { return nil }
        // A document that names a bundled family itself (Carlito) gets it as it is.
        let name = Self.compatible[Self.fold(family)] ?? family
        return findBundled(bundled, name, style) ?? findBundled(bundled, Self.defaultFamily, style)
    }

    // Names the bundled source does not know all end up at the default; handing back the same file keeps a document
    // with thousands of made-up names from reading and parsing the default font once per name.
    private func findBundled(_ bundled: FontSource, _ family: String, _ style: FontStyles) -> FontFile? {
        let key = LoadedKey(family: family, style: style.rawValue)
        if let known = loaded[key] { return known }
        let file = bundled.find(family, style)
        if let file { loaded[key] = file }
        return file
    }

    // Only A-Z fold, so the C# twin matches without depending on Foundation's case tables.
    private static func fold(_ name: String) -> String {
        String(String.UnicodeScalarView(name.unicodeScalars.map { ("A"..."Z").contains($0) ? Unicode.Scalar($0.value + 32)! : $0 }))
    }
}
