import Foundation
import LazyPDFKit

// Follows windows/LazyPDF.App/Services/BundledFontSource.cs: the fonts shipped in the app bundle (Carlito, Caladea,
// Liberation), found by family name and style. The Xcode projects copy them flat into the bundle's resources.

public final class BundledFontSource: FontSource {
    private let bundle: Bundle

    public init(bundle: Bundle = .main) {
        self.bundle = bundle
    }

    public func find(_ family: String, _ style: FontStyles) -> FontFile? {
        let face = style.contains(.bold) ? (style.contains(.italic) ? "BoldItalic" : "Bold") : (style.contains(.italic) ? "Italic" : "Regular")
        let name = "\(family.replacingOccurrences(of: " ", with: ""))-\(face)"
        guard let url = bundle.url(forResource: name, withExtension: "ttf"), let data = try? Data(contentsOf: url) else { return nil }
        return FontFile([UInt8](data))
    }
}
