import Foundation
import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Editing/EditShapedFontTests.cs.

final class EditShapedFontTests: XCTestCase {
    // Joined letters take the initial and final forms; a letter alone keeps the cmap glyph, as a real shaper's isolated form would differ from both.
    private final class JoiningFonts: FontSource, Shaper {
        static let font: [UInt8] = (try? ShapingGolden.font()) ?? []
        static let count = TrueTypeFont.tryParse(font)!.glyphCount

        func find(_ family: String, _ style: FontStyles) -> FontFile? { FontFile(Self.font) }

        func shape(_ text: String, _ font: FontFile, rightToLeft: Bool, language: String?) -> [ShapedGlyph]? {
            let units = Array(text.utf16)
            if units.count < 2 || units.contains(where: { $0 != 0x0628 }) {
                return CmapShaper().shape(text, font, rightToLeft: rightToLeft, language: language)
            }
            var glyphs = units.indices.map {
                ShapedGlyph(glyph: $0 == units.count - 1 ? Self.count - 1 : Self.count - 2, advance: 600, xOffset: 0, yOffset: 0, cluster: $0)
            }
            if rightToLeft { glyphs.reverse() }
            return glyphs
        }
    }

    func test_joinedArabicTypedIntoEditTextHasNoNotdefCodes() throws {
        let session = try EditKit.session("BT /F1 12 Tf 50 700 Td (Hello world) Tj ET")
        let fonts = JoiningFonts()
        let result = try PageEditor(session, 0, fonts).replaceText(try EditKit.find(session, "world"), "\u{628}\u{628}")
        XCTAssertTrue(result.done, result.problem ?? "")
        let content = EditKit.latin(session)
        let pattern = try NSRegularExpression(pattern: "<([0-9A-Fa-f]+)>")
        let shown = pattern.matches(in: content, range: NSRange(content.startIndex..., in: content))
            .map { String(content[Range($0.range(at: 1), in: content)!]) }
        XCTAssertFalse(shown.isEmpty)
        for hex in shown {
            var i = hex.startIndex
            while i < hex.endIndex {
                let end = hex.index(i, offsetBy: 4, limitedBy: hex.endIndex) ?? hex.endIndex
                XCTAssertNotEqual(String(hex[i..<end]), "0000")
                i = end
            }
        }
    }
}
