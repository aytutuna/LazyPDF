import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Annotations/AnnotationFixtures.cs. Reopen does not hand the files to PdfPig, which has
// no Swift twin; the document is still written both ways and read again. The C# font source reads Arial from the Windows
// fonts folder; here it hands out the synthetic font of the font program tests, which has A, B, space, ğ, ı, İ and À, so
// the tests that need Turkish letters use those.

struct MissingAppearance: Error {}

enum AnnotationFixtures {
    /// Pages are 3 and up, 600 by 800 points with no content; `more` adds objects from number 20.
    static func blank(_ pages: Int = 2, _ more: ((TestPdf) -> Void)? = nil, pageEntries: String = "") throws -> PdfDocument {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R>>")
        let kids = (0..<pages).map { "\(3 + $0) 0 R" }.joined(separator: " ")
        pdf.obj(2, "<</Type /Pages /Kids [\(kids)] /Count \(pages) /MediaBox [0 0 600 800]>>")
        for i in 0..<pages { pdf.obj(3 + i, "<</Type /Page /Parent 2 0 R \(pageEntries)>>") }
        more?(pdf)
        return try PdfDocument.open(pdf.finish())
    }

    /// The document written both ways and read again; the document read from the update is returned.
    @discardableResult
    static func reopen(_ document: PdfDocument, file: StaticString = #filePath, line: UInt = #line) throws -> PdfDocument {
        let rewritten = try document.saveRewrite()
        XCTAssertEqual(try PdfDocument.open(rewritten).pages.count, document.pages.count, file: file, line: line)
        XCTAssertTrue(try PdfDocument.open(rewritten).repairs.isEmpty, file: file, line: line)

        let updated = try document.saveIncremental()
        let reopened = try PdfDocument.open(updated)
        XCTAssertEqual(reopened.pages.count, document.pages.count, file: file, line: line)
        XCTAssertTrue(reopened.repairs.isEmpty, "\(reopened.repairs)", file: file, line: line)
        return reopened
    }

    /// The operators of an annotation's normal appearance, in order.
    static func appearance(_ document: PdfDocument, _ annotation: PdfAnnotation) throws -> [ContentOperation] {
        ContentParser.parse(try document.data(try normal(document, annotation)))
    }

    static func normal(_ document: PdfDocument, _ annotation: PdfAnnotation) throws -> PdfStream {
        guard let stream = document.stream(document.dict(annotation.dictionary, "AP"), "N") else {
            XCTFail("The annotation has no /AP /N.")
            throw MissingAppearance()
        }
        return stream
    }

    static func operators(_ operations: [ContentOperation]) -> [String] { operations.map { $0.operator } }

    static func has(_ operations: [ContentOperation], _ op: String) -> Bool { operations.contains { $0.operator == op } }

    /// What the annotation's normal appearance shows, recorded.
    static func draw(_ document: PdfDocument, _ annotation: PdfAnnotation) throws -> Recorder {
        let recorder = Recorder()
        ContentInterpreter(document).run(try normal(document, annotation), recorder)
        return recorder
    }

    final class ArialSource: FontSource {
        private let data: [UInt8]

        init() throws {
            data = try SyntheticFonts.ttf()
        }

        func find(_ family: String, _ style: FontStyles) -> FontFile? { FontFile(data) }
    }
}
