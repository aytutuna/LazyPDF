import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Standards/PdfAMalformedTests.cs: the same cases. The damage of the random test is drawn
// from DotNetRandom with the seed of the C#, so the same bytes of the same file are hit.

final class PdfAMalformedTests: XCTestCase {
    private func convert(_ file: [UInt8]) throws -> PdfAConversion {
        try PdfAConverter(SystemFonts()).convert(file, .a2b, StandardsKit.date)
    }

    func test_aFormThatUsesItselfDoesNotLoop() throws {
        let file = StandardsKit.compliant(content: "/Fm Do", resources: "/XObject <</Fm 9 0 R>>", extra: { pdf in
            pdf.stream(9, "/Type /XObject /Subtype /Form /BBox [0 0 10 10] /Resources << /XObject << /Fm 9 0 R >> >>", "/Fm Do 0 g 0 0 5 5 re f")
        })
        XCTAssertNotNil(try convert(file).bytes)
        _ = try StandardsKit.check(file)
    }

    func test_aChainOfNestedFormsFarDeeperThanTheCapIsCutShort() throws {
        let depth = 400
        let file = StandardsKit.compliant(content: "/Fm Do", resources: "/XObject <</Fm 9 0 R>>", extra: { pdf in
            for i in 0..<depth {
                pdf.stream(9 + i, "/Type /XObject /Subtype /Form /BBox [0 0 10 10] /Resources << /XObject << /Fm \(10 + i) 0 R >> >>", "/Fm Do")
            }
            pdf.stream(9 + depth, "/Type /XObject /Subtype /Form /BBox [0 0 10 10]", "0 g 0 0 5 5 re f")
        })
        _ = try StandardsKit.check(file)
        XCTAssertNotNil(try convert(file).bytes)
    }

    func test_aDocumentWithNoPagesIsCheckedWithoutFailing() throws {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R>>")
        pdf.obj(2, "<</Type /Pages /Kids [] /Count 0>>")
        let file = pdf.finish("/Root 1 0 R")
        XCTAssertFalse(try StandardsKit.check(file).issues.isEmpty)
        XCTAssertNotNil(try convert(file).bytes)
    }

    func test_anAnnotationArrayWithJunkInItIsRead() throws {
        let file = StandardsKit.compliant(page: "/Annots [1 (text) null 99 0 R << /Subtype /Square >> 9 0 R]", extra: { pdf in
            pdf.obj(9, "<</Type /Annot /Subtype /Sound /Rect [0 0 1 1]>>")
        })
        StandardsKit.assertContains(try StandardsKit.clauses(file), "6.3.1")
        let result = try convert(file)
        XCTAssertNotNil(result.bytes)
        StandardsKit.assertNone(result.remaining) { $0.clause == "6.3.1" }
    }

    func test_aFontWithNothingUsableInItIsReportedAndConverted() throws {
        let file = StandardsKit.compliant(content: "BT /F1 12 Tf (x) Tj ET", resources: "/Font <</F1 9 0 R>>", extra: { pdf in
            pdf.obj(9, "<</Type /Font /Subtype /TrueType /BaseFont /Nothing /FontDescriptor 10 0 R>>").stream(10, "/Length1 4", [UInt8](repeating: 0, count: 4))
        })
        StandardsKit.assertContains(try StandardsKit.clauses(file), "6.2.11.4.1")
        XCTAssertNotNil(try convert(file).bytes)
    }

    func test_aCutOffFileIsRefusedOrRepairedButNeverFails() throws {
        let whole = StandardsKit.compliant()
        var cut = 40
        while cut < whole.count {
            let result = try convert(Array(whole[..<cut]))
            XCTAssertTrue(result.bytes != nil || result.refusal != nil, "cut at \(cut)")
            cut += 97
        }
    }

    func test_damageAtRandomPlacesNeverEscapesAsAnException() throws {
        let whole = StandardsKit.compliant(page: "/Annots [9 0 R]", content: "BT /F1 12 Tf 10 10 Td (Hello) Tj ET 0 0 1 rg 20 20 50 50 re f", resources: "/Font <</F1 11 0 R>>", extra: { pdf in
            pdf.obj(9, "<</Type /Annot /Subtype /Square /Rect [10 10 50 50] /F 4 /AP <</N 10 0 R>>>>")
            pdf.stream(10, "/Type /XObject /Subtype /Form /BBox [0 0 40 40]", "0 0 1 rg 0 0 40 40 re f")
            pdf.obj(11, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica>>")
        })
        var random = DotNetRandom(7)
        for round in 0..<150 {
            var damaged = whole
            for _ in 0..<(1 + round % 5) { damaged[random.next(damaged.count)] = UInt8(random.next(256)) }
            do {
                let document = try PdfDocument.open(damaged)
                _ = PdfAValidator.validate(document, .a2b)
            } catch is PdfReadException {
            }
            let result = try convert(damaged)
            XCTAssertTrue(result.bytes != nil || result.refusal != nil, "round \(round)")
        }
    }

    func test_aHugeNumberOfEntriesInAResourceDictionaryIsAffordable() throws {
        var states = ""
        for i in 0..<20_000 { states += "/G\(i) <</ca 1>> " }
        let file = StandardsKit.compliant(resources: "/ExtGState <<\(states)>>")
        try StandardsKit.assertClean(file)
    }
}
