import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Editing/EditKit.cs: the same helpers. The C# font source reads arial.ttf from the
// Windows fonts folder; EditArialSource here hands out EditFont, built from the synthetic TrueType file of the font
// tests, with a glyph for the ASCII letters and the Turkish ones and none for anything else (中 stays missing, as in
// Arial's case for rarer scripts). EditKit.Pig has no twin: PdfPig reads the file back in C#.

/// A TrueType font with the printable ASCII letters, a no-break space and Ç ç Ğ ğ İ ı Ö ö Ş ş Ü ü é: the synthetic
/// font's tables with one glyph per code point, 600 units wide (a space 250).
enum EditFont {
    static let codePoints: [Int] = Array(0x20...0x7E) + [0xA0, 0xC7, 0xD6, 0xDC, 0xE7, 0xE9, 0xF6, 0xFC, 0x11E, 0x11F, 0x130, 0x131, 0x15E, 0x15F, 0x663]

    static let bytes: [UInt8] = (try? build()) ?? []

    private static func u16(_ value: Int) -> [UInt8] { [UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)] }

    private static func u32(_ value: Int) -> [UInt8] { u16(value >> 16) + u16(value & 0xFFFF) }

    private static func build() throws -> [UInt8] {
        var tables = Sfnt.tables(try SyntheticFonts.ttf())
        let glyf = Sfnt.data(tables, "glyf")
        let oldLoca = FontSpan(Sfnt.data(tables, "loca"))
        let square = Array(glyf[(oldLoca.u16(2) * 2)..<(oldLoca.u16(4) * 2)])
        let count = codePoints.count + 1
        var glyphs: [UInt8] = []
        var loca: [UInt8] = []
        var hmtx: [UInt8] = []
        for gid in 0..<count {
            loca += u16(glyphs.count / 2)
            let blank = gid > 0 && (codePoints[gid - 1] == 0x20 || codePoints[gid - 1] == 0xA0)
            if !blank { glyphs += square }
            hmtx += u16(blank ? 250 : 600) + u16(10)
        }
        loca += u16(glyphs.count / 2)
        var groups: [UInt8] = []
        for (i, cp) in codePoints.enumerated() { groups += u32(cp) + u32(cp) + u32(i + 1) }
        let subtable = u16(12) + u16(0) + u32(16 + groups.count) + u32(0) + u32(codePoints.count) + groups
        let cmap = u16(0) + u16(1) + u16(3) + u16(10) + u32(12) + subtable
        var hhea = Sfnt.data(tables, "hhea")
        FontBytes.putU16(&hhea, 34, count)
        var maxp = Sfnt.data(tables, "maxp")
        FontBytes.putU16(&maxp, 4, count)
        tables = Sfnt.replacing(tables, "glyf", glyphs)
        tables = Sfnt.replacing(tables, "loca", loca)
        tables = Sfnt.replacing(tables, "hmtx", hmtx)
        tables = Sfnt.replacing(tables, "hhea", hhea)
        tables = Sfnt.replacing(tables, "maxp", maxp)
        tables = Sfnt.replacing(tables, "cmap", cmap)
        tables = Sfnt.replacing(tables, "post", u32(0x0003_0000) + [UInt8](repeating: 0, count: 28))
        return Sfnt.build([tables])
    }
}

final class EditArialSource: FontSource {
    func find(_ family: String, _ style: FontStyles) -> FontFile? { FontFile(EditFont.bytes) }
}

/// A glyph as the interpreter places it, for comparing a page before and after an edit.
struct EditGlyphAt: Equatable {
    let text: String
    let x: Double
    let y: Double
    let size: Double
}

/// A glyph with the state it is drawn in.
struct EditShown: Equatable {
    let text: String
    let x: Double
    let y: Double
    let size: Double
    let color: RgbColor
    let tc: Double
    let tw: Double
}

func editRound(_ value: Double, _ digits: Int) -> Double {
    let scale = pow(10.0, Double(digits))
    return (value * scale).rounded(.toNearestOrEven) / scale
}

enum EditKit {
    static let helvetica = "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding>>"
    static let times = "<</Type /Font /Subtype /Type1 /BaseFont /Times-Roman /Encoding /WinAnsiEncoding>>"

    /// A one page file, 600 by 800, with Helvetica as /F1 and Times as /F2; extra objects start at 7.
    static func file(_ content: String, _ pageKeys: String = "", more: ((TestPdf) -> Void)? = nil,
                     resources: String = "/Font <</F1 5 0 R /F2 6 0 R>>") -> [UInt8] {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R>>")
        pdf.obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 600 800]>>")
        pdf.obj(3, "<</Type /Page /Parent 2 0 R /Contents 4 0 R /Resources <<\(resources)>> \(pageKeys)>>")
        pdf.stream(4, "", content)
        pdf.obj(5, helvetica)
        pdf.obj(6, times)
        more?(pdf)
        return pdf.finish()
    }

    static func session(_ content: String, _ pageKeys: String = "", more: ((TestPdf) -> Void)? = nil,
                        resources: String = "/Font <</F1 5 0 R /F2 6 0 R>>") throws -> PdfEditSession {
        try PdfEditSession.open(file(content, pageKeys, more: more, resources: resources))
    }

    /// The page text as the engine reads it, with the whole file reopened first.
    static func text(_ session: PdfEditSession, _ page: Int = 0) throws -> String {
        let document = try PdfDocument.open(session.current)
        return TextPage.create(document, document.pages[page]).text
    }

    static func glyphs(_ session: PdfEditSession, _ page: Int = 0) throws -> [EditGlyphAt] {
        let document = try PdfDocument.open(session.current)
        let probe = Collect()
        ContentInterpreter(document).run(document.pages[page], probe)
        return probe.found
    }

    static func shown(_ session: PdfEditSession, _ page: Int = 0) throws -> [EditShown] {
        let document = try PdfDocument.open(session.current)
        let probe = Observe()
        ContentInterpreter(document).run(document.pages[page], probe)
        return probe.found
    }

    /// The glyphs of a word, found in the order they are drawn.
    static func of(_ shown: [EditShown], _ word: String, file: StaticString = #filePath, line: UInt = #line) -> [EditShown] {
        let all = shown.map { $0.text }.joined()
        guard let found = all.range(of: word, options: .literal) else {
            XCTFail(word, file: file, line: line)
            return []
        }
        let at = all.distance(from: all.startIndex, to: found.lowerBound)
        return Array(shown[at..<min(at + word.count, shown.count)])
    }

    static func find(_ session: PdfEditSession, _ word: String, _ page: Int = 0) throws -> LazyPDFKit.TextRange {
        let text = TextPage.create(session.document, session.document.pages[page])
        let match = try TextSearch.find(text, word, TextSearchOptions(matchCase: true)).first
        return try XCTUnwrap(match).range
    }

    static func latin(_ session: PdfEditSession, _ page: Int = 0) -> String {
        Latin1.string(session.document.pages[page].contents())
    }

    /// The files the corpus tests run over: the list LAZYPDF_CORPUS names (one path per line) or, without it, the
    /// plain files of Tests/Fixtures so that the test is never empty. The C# tests do nothing without the variable.
    static func corpusFiles() -> [String] {
        if let list = ProcessInfo.processInfo.environment["LAZYPDF_CORPUS"], !list.isEmpty,
           let text = try? String(contentsOfFile: list, encoding: .utf8) {
            return text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        let fixtures = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
        var found: [String] = []
        for folder in ["Documents", "Documents/annotations", "Pages"] {
            let url = fixtures.appendingPathComponent(folder)
            let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
            found += names.filter { $0.hasSuffix(".pdf") }.sorted().map { url.appendingPathComponent($0).path }
        }
        return found
    }

    private final class Observe: ContentVisitor {
        var found: [EditShown] = []

        override func showGlyph(_ context: ContentContext, _ glyph: GlyphInfo) {
            let s = context.state
            found.append(EditShown(text: glyph.unicode ?? "", x: editRound(glyph.matrix.e, 2), y: editRound(glyph.matrix.f, 2), size: editRound(glyph.matrix.d, 2),
                                   color: s.fillColor.rgb, tc: s.charSpacing, tw: s.wordSpacing))
        }
    }

    private final class Collect: ContentVisitor {
        var found: [EditGlyphAt] = []

        override func showGlyph(_ context: ContentContext, _ glyph: GlyphInfo) {
            found.append(EditGlyphAt(text: glyph.unicode ?? "", x: editRound(glyph.matrix.e, 3), y: editRound(glyph.matrix.f, 3), size: editRound(glyph.matrix.d, 3)))
        }
    }
}

/// Assert.Single: the one element of a list.
func assertSingle<T>(_ items: [T], file: StaticString = #filePath, line: UInt = #line) throws -> T {
    XCTAssertEqual(items.count, 1, "expected exactly one element", file: file, line: line)
    return try XCTUnwrap(items.first, file: file, line: line)
}
