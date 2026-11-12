import Foundation
import LazyPDFKit

// Follows windows/LazyPDF.App/Services/BundledFontSource.cs: the fonts shipped in the app bundle (Carlito, Caladea,
// Liberation), found by family name and style. The Xcode projects copy them flat into the bundle's resources.

public final class BundledFontSource: FontSource {
    private let folder: URL?

    public init(folder: URL? = Bundle.main.resourceURL) {
        self.folder = folder
    }

    public func find(_ family: String, _ style: FontStyles) -> FontFile? {
        let face: String
        switch style {
        case [.bold, .italic]: face = "BoldItalic"
        case .bold: face = "Bold"
        case .italic: face = "Italic"
        default: face = "Regular"
        }
        let name = "\(family.replacingOccurrences(of: " ", with: ""))-\(face).ttf"
        guard let url = folder?.appendingPathComponent(name), let data = try? Data(contentsOf: url) else { return nil }
        return FontFile([UInt8](data))
    }
}
