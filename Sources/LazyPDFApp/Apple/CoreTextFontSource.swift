#if canImport(CoreText)
import CoreText
import Foundation
import LazyPDFKit

// Follows windows/LazyPDF.App/Services/SystemFontSource.cs: the fonts installed on the system, as files the engine can
// embed. A face inside a .ttc collection is picked by its PostScript name. It is the shaper for those files too, so the
// writers that receive it draw Arabic and Hebrew shaped.

public final class CoreTextFontSource: FontSource, Shaper {
    private let shaper = CoreTextShaper()

    // The names a PDF or a person uses for fonts the system has under another. The name itself is tried second, since
    // Helvetica is installed on the Mac and Arial is not on every device.
    private static let aliases = ["helvetica": "Arial", "times": "Times New Roman", "courier": "Courier New", "symbol": "Symbol"]

    public init() {}

    public func shape(_ text: String, _ font: FontFile, rightToLeft: Bool, language: String?) -> [ShapedGlyph]? {
        shaper.shape(text, font, rightToLeft: rightToLeft, language: language)
    }

    public func find(_ family: String, _ style: FontStyles) -> FontFile? {
        var wanted = [family]
        if let alias = Self.aliases[family.lowercased()] { wanted.insert(alias, at: 0) }
        let installed = CTFontManagerCopyAvailableFontFamilyNames() as? [String] ?? []
        for name in wanted {
            guard let installedName = installed.first(where: { $0.caseInsensitiveCompare(name) == .orderedSame }),
                  let file = Self.file(installedName, style) else { continue }
            return file
        }
        return nil
    }

    private static func file(_ family: String, _ style: FontStyles) -> FontFile? {
        var traits: CTFontSymbolicTraits = []
        if style.contains(.bold) { traits.insert(.traitBold) }
        if style.contains(.italic) { traits.insert(.traitItalic) }
        let attributes: [CFString: Any] = [
            kCTFontFamilyNameAttribute: family,
            kCTFontTraitsAttribute: [kCTFontSymbolicTrait: traits.rawValue],
        ]
        let query = CTFontDescriptorCreateWithAttributes(attributes as CFDictionary)
        guard let match = CTFontDescriptorCreateMatchingFontDescriptor(query, NSSet(object: kCTFontFamilyNameAttribute) as CFSet),
              let url = CTFontDescriptorCopyAttribute(match, kCTFontURLAttribute) as? URL,
              let data = try? Data(contentsOf: url) else { return nil }
        let bytes = [UInt8](data)
        return FontFile(bytes, bytes.starts(with: Array("ttcf".utf8)) ? faceIndex(match, url) : 0)
    }

    // The faces of a collection come out of CoreText in the file's order.
    private static func faceIndex(_ face: CTFontDescriptor, _ url: URL) -> Int {
        guard let name = CTFontDescriptorCopyAttribute(face, kCTFontNameAttribute) as? String,
              let faces = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor] else { return 0 }
        return faces.firstIndex { (CTFontDescriptorCopyAttribute($0, kCTFontNameAttribute) as? String) == name } ?? 0
    }
}
#endif
