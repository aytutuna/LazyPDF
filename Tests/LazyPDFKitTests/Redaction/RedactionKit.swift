import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Redaction/RedactionKit.cs and RedactionFiles.cs: the helpers of the redaction tests.
// Left out: `Pig`, which reads a page with PdfPig, and the second opening of `Reopen` in PdfPig; there is no PdfPig here, so
// a file is opened in the engine alone.

/// A glyph as the content draws it: the text and where its origin is, in user space.
struct DrawnGlyph {
    let text: String
    let x: Double
    let y: Double
}

final class FakeCodec: ImageCodec {
    private let image: PdfRgbaImage?

    init(_ image: PdfRgbaImage?) {
        self.image = image
    }

    func decode(_ data: [UInt8], _ codec: String) -> PdfRgbaImage? { image }
    func decodeFile(_ file: [UInt8]) -> [PdfRgbaImage]? { nil }
    func encodeJpeg(_ image: PdfRgbaImage, _ quality: Int) -> [UInt8] { [] }
}

/// Draws every page as a gradient at the size the page has, so a test can tell where the marks were filled.
final class RedactFakeRenderer: PageRenderer {
    private let document: PdfDocument
    var drawn: [Int] = []
    var dpis: [Double] = []

    init(_ document: PdfDocument) {
        self.document = document
    }

    func render(_ pageIndex: Int, _ dpi: Double) -> PdfRgbaImage? {
        drawn.append(pageIndex)
        dpis.append(dpi)
        let geometry = PageGeometry(document.pages[pageIndex])
        let width = Int((geometry.width * dpi / 72).rounded(.up)), height = Int((geometry.height * dpi / 72).rounded(.up))
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                (rgba[i], rgba[i + 1], rgba[i + 2], rgba[i + 3]) = (UInt8(100 + x * 100 / width), UInt8(100 + y * 100 / height), 200, 255)
            }
        }
        return PdfRgbaImage(width, height, rgba)
    }
}

enum RedactionKit {
    /// The options that let a page the redaction cannot follow become a picture, drawn small to keep the tests quick.
    static func drawing(_ document: PdfDocument, _ options: RedactionOptions? = nil) -> RedactionOptions {
        var drawing = options ?? RedactionOptions()
        drawing.renderer = RedactFakeRenderer(document)
        drawing.flattenDpi = 24
        return drawing
    }

    static func apply(_ document: PdfDocument, _ marks: [RedactionMark], _ options: RedactionOptions? = nil) throws -> RedactionResult {
        try PdfRedactor(document).apply(marks, drawing(document, options))
    }

    @discardableResult
    static func assertFlattened(_ document: PdfDocument, _ area: PdfRect, _ words: String...) throws -> RedactionResult {
        try checkFlattened(document, [RedactionMark.fromRect(0, area)], words)
    }

    @discardableResult
    static func assertFlattened(_ document: PdfDocument, _ marks: [RedactionMark], _ words: String...) throws -> RedactionResult {
        try checkFlattened(document, marks, words)
    }

    /// The page of the first mark cannot be followed to its end: the call refuses without a renderer, and with one the page
    /// becomes a picture and none of the words is left in the file.
    @discardableResult
    static func checkFlattened(_ document: PdfDocument, _ marks: [RedactionMark], _ words: [String]) throws -> RedactionResult {
        let page = marks[0].page
        XCTAssertThrowsError(try PdfRedactor(document).apply(marks)) { error in
            XCTAssertEqual((error as? InvalidOperationException)?.message, RedactionText.needsPicture(page))
        }
        let result = try apply(document, marks)
        XCTAssertTrue(result.report.flattened.contains(page))
        XCTAssertTrue(result.verification.isClean, result.verification.problems.joined(separator: "; "))
        for word in words { XCTAssertFalse(holds(result.bytes, word), word) }
        let output = try reopen(result.bytes)
        XCTAssertFalse(try latin(output, page).contains("Tj"))
        XCTAssertTrue(try latin(output, page).contains(" Do"))
        return result
    }

    static let marker = "ZQXMARKER"
    static let helvetica = ContentTestPdf.helvetica

    /// A 600 by 800 page with Helvetica as /F1 and the extra resource entries and objects (numbered from 6) given.
    static func page(_ content: String, _ resources: String = "", _ objects: [String] = []) throws -> PdfDocument {
        try ContentTestPdf.page(content, "/Font <</F1 5 0 R>> \(resources)", [helvetica] + objects)
    }

    static func page(_ content: String, _ resources: String, _ more: (TestPdf) -> Void) throws -> PdfDocument {
        try ContentTestPdf.page(content, "/Font <</F1 5 0 R>> \(resources)") { pdf in
            pdf.obj(5, helvetica)
            more(pdf)
        }
    }

    static func glyphs(_ document: PdfDocument, _ page: Int = 0) -> [DrawnGlyph] {
        let collector = GlyphCollector()
        ContentInterpreter(document).run(document.pages[page], collector)
        return collector.found
    }

    static func text(_ glyphs: [DrawnGlyph]) -> String { glyphs.map { $0.text }.joined() }

    static func text(_ document: PdfDocument, _ page: Int = 0) -> String { text(glyphs(document, page)) }

    private final class GlyphCollector: ContentVisitor {
        var found: [DrawnGlyph] = []

        override func showGlyph(_ context: ContentContext, _ glyph: GlyphInfo) {
            found.append(DrawnGlyph(text: glyph.unicode ?? "", x: glyph.matrix.e, y: glyph.matrix.f))
        }
    }

    /// The mark over a search hit of the page.
    static func markOf(_ document: PdfDocument, _ page: Int, _ word: String, _ fill: [Double]? = nil, _ overlay: String? = nil) throws -> RedactionMark {
        let text = TextPage.create(document, document.pages[page])
        let hit = try TextSearch.find(text, word).first
        XCTAssertTrue(hit != nil, "'\(word)' is not on page \(page)")
        guard let hit else { throw ArgumentException("'\(word)' is not on page \(page)") }
        return RedactionMark.fromMatch(hit, fill, overlay)
    }

    static func images(_ document: PdfDocument, _ page: Int = 0) -> [ImageInfo] {
        let collector = ImageCollector()
        ContentInterpreter(document).run(document.pages[page], collector)
        return collector.found
    }

    private final class ImageCollector: ContentVisitor {
        var found: [ImageInfo] = []

        override func paintImage(_ context: ContentContext, _ image: ImageInfo) {
            found.append(image)
        }
    }

    static func marksOf(_ document: PdfDocument, _ page: Int, _ word: String) throws -> [RedactionMark] {
        let marks = try TextSearch.find(TextPage.create(document, document.pages[page]), word).map { RedactionMark.fromMatch($0) }
        XCTAssertTrue(!marks.isEmpty, "'\(word)' is not on page \(page)")
        return marks
    }

    static func open(_ result: RedactionResult) throws -> PdfDocument {
        XCTAssertTrue(result.verification.isClean, result.verification.problems.joined(separator: "; "))
        return try reopen(result.bytes)
    }

    /// Opens the bytes in the engine.
    static func reopen(_ bytes: [UInt8], _ password: String? = nil) throws -> PdfDocument {
        try PdfDocument.open(bytes, password: password)
    }

    /// The file as Latin-1 text with every stream decoded and appended: what a search of "raw bytes and every stream" sees.
    static func everything(_ bytes: [UInt8], _ password: String? = nil) throws -> String {
        var all = Latin1.string(bytes)
        let document = try PdfDocument.open(bytes, password: password)
        for number in document.objectNumbers {
            guard let stream = document.get(number) as? PdfStream else { continue }
            all += "\n"
            do {
                all += Latin1.string(try document.data(stream))
            } catch is PdfReadException {
                all += Latin1.string(document.rawData(stream))
            }
        }
        return all
    }

    /// The text in any form it can take in a file: plain, UTF-16, or either as hex digits.
    static func holds(_ bytes: [UInt8], _ text: String, _ password: String? = nil) -> Bool {
        let all: String
        do {
            all = try everything(bytes, password)
        } catch {
            // The C# opens the file and throws; a file that does not open must not read as free of the text.
            XCTFail("The output does not open: (error)")
            return false
        }
        let wide = Array(text.utf16).flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] }
        let forms = [text, Latin1.string(wide), hex(text), wide.map { String(format: "%02X", $0) }.joined()]
        let haystack = upper(all)
        return forms.contains { haystack.contains(upper($0)) }
    }

    // OrdinalIgnoreCase on the units of a string.
    private static func upper(_ text: String) -> [UInt16] {
        text.utf16.map { unit in
            guard let scalar = Unicode.Scalar(unit) else { return unit }
            let mapped = scalar.properties.uppercaseMapping.utf16
            return mapped.count == 1 ? (mapped.first ?? unit) : unit
        }
    }

    static func latin(_ document: PdfDocument, _ page: Int = 0) throws -> String { Latin1.string(document.pages[page].contents()) }

    static func hex(_ text: String) -> String { Latin1.bytes(text).map { String(format: "%02X", $0) }.joined() }
}

private extension Array where Element == UInt16 {
    func contains(_ needle: [UInt16]) -> Bool {
        if needle.isEmpty { return true }
        if count < needle.count { return false }
        for start in 0...(count - needle.count) where self[start] == needle[0] {
            if self[start..<start + needle.count].elementsEqual(needle) { return true }
        }
        return false
    }
}

/// Small files for the redaction tests: a catalog (1), a page tree (2), Helvetica (5), pages from 30, and whatever the test adds below 30.
enum RedactionFiles {
    static let picture = "q 100 0 0 100 100 100 cm /Im1 Do Q"
    static let word = "BT /F1 12 Tf 100 100 Td (ZQXSECRET) Tj ET"
    static let over = PdfRect(90, 90, 300, 120)

    static func open(_ content: String, _ resources: String = "", _ more: ((TestPdf) -> Void)? = nil, fonts: String = "", pageExtra: String = "",
                     catalogExtra: String = "", pagesExtra: String = "") throws -> PdfDocument {
        try open([content], resources, more, fonts: fonts, pageExtras: [pageExtra], catalogExtra: catalogExtra, pagesExtra: pagesExtra)
    }

    static func open(_ contents: [String], _ resources: String = "", _ more: ((TestPdf) -> Void)? = nil, fonts: String = "", pageExtras: [String]? = nil,
                     catalogExtra: String = "", pagesExtra: String = "") throws -> PdfDocument {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R \(catalogExtra)>>")
        let kids = contents.indices.map { "\(30 + 2 * $0) 0 R" }.joined(separator: " ")
        pdf.obj(2, "<</Type /Pages /Kids [\(kids)] /Count \(contents.count) /MediaBox [0 0 600 800] \(pagesExtra)>>")
        pdf.obj(5, ContentTestPdf.helvetica)
        for i in contents.indices {
            let extra = pageExtras.map { i < $0.count ? $0[i] : "" } ?? ""
            pdf.obj(30 + 2 * i, "<</Type /Page /Parent 2 0 R /Contents \(31 + 2 * i) 0 R /Resources <</Font <</F1 5 0 R \(fonts)>> \(resources)>> \(extra)>>")
            pdf.stream(31 + 2 * i, "", contents[i])
        }
        more?(pdf)
        return try PdfDocument.open(pdf.finish())
    }

    static func image(_ pdf: TestPdf, _ number: Int, _ entries: String = "", _ data: String = "ZQXPIXELS") {
        pdf.stream(number, "/Type /XObject /Subtype /Image /Width 3 /Height 3 /ColorSpace /DeviceGray /BitsPerComponent 8 \(entries)", data)
    }

    static func apply(_ document: PdfDocument, _ marks: RedactionMark...) throws -> RedactionResult { try RedactionKit.apply(document, marks) }

    /// The output passes its own check and holds none of the words.
    static func gone(_ result: RedactionResult, _ words: String...) {
        XCTAssertTrue(result.verification.isClean, result.verification.problems.joined(separator: "; "))
        for word in words { XCTAssertFalse(RedactionKit.holds(result.bytes, word), word) }
    }
}

extension RedactionKit {
    /// A gzip file of the data: one member, deflate between the header and the CRC-32 and length.
    static func gzip(_ data: [UInt8]) -> [UInt8] {
        let zlib = Deflate.zlib(data, .smallestSize)
        let crc = ExportZip.crc32(data)
        var packed: [UInt8] = [0x1F, 0x8B, 8, 0, 0, 0, 0, 0, 0, 0xFF]
        packed += zlib[2..<(zlib.count - 4)]
        packed += [UInt8(crc & 0xFF), UInt8((crc >> 8) & 0xFF), UInt8((crc >> 16) & 0xFF), UInt8(crc >> 24)]
        packed += [UInt8(data.count & 0xFF), UInt8((data.count >> 8) & 0xFF), UInt8((data.count >> 16) & 0xFF), UInt8((data.count >> 24) & 0xFF)]
        return packed
    }
}

/// Hands the redaction the fixture font that has the letters of the Turkish overlay, as Arial has them in the C# tests.
final class RedactionArialSource: FontSource {
    static let turkish = ["Idotaccent", "Scedilla", "scedilla", "Gbreve", "gbreve", "dotlessi"]

    func find(_ family: String, _ style: FontStyles) -> FontFile? {
        FontFile(FixtureFonts.latin("ArialMT", extraGlyphs: Self.turkish))
    }
}

extension RedactionKit {
    /// The problems are exactly one, and it is `message` for the object the problem names (the numbers of the output are not
    /// those of the input): what was found in it, or that it could not be looked into.
    static func assertOneProblem(_ problems: [String], attached: Bool, found: Bool, file: StaticString = #filePath, line: UInt = #line) {
        guard problems.count == 1, let number = Int(String(problems[0].unicodeScalars.filter { $0.properties.numericType == .decimal })) else {
            XCTFail("expected one problem naming an object, got \(problems)", file: file, line: line)
            return
        }
        let place = attached ? RedactionText.attachedFile(number) : L10n.t("object {0}|in a sentence", number)
        XCTAssertEqual(problems, [found ? RedactionText.stillInFile(place) : RedactionText.notChecked(place)], file: file, line: line)
    }
}
