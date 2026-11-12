import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Pages/PageImposeTests.cs: the same cases. The argument checks that are
// preconditions in Swift (a count per sheet) are not there.

final class PageImposeTests: XCTestCase {
    private func nUp(_ source: PdfDocument, _ per: Int, width: Double = 600, height: Double = 400, gap: Double = 0, border: Bool = false) throws -> ImposeResult {
        try PageOperations.impose(source, Array(0..<source.pages.count), ImposeOptions(mode: .nUp, sheetWidth: width, sheetHeight: height, perSheet: per, gap: gap, border: border))
    }

    private func booklet(_ source: PdfDocument, width: Double = 300, height: Double = 400) throws -> ImposeResult {
        try PageOperations.impose(source, Array(0..<source.pages.count), ImposeOptions(mode: .booklet, sheetWidth: width, sheetHeight: height))
    }

    // What a sheet draws: the "Page n" its form shows (0 when none) and where the form's box lands.
    private func placed(_ document: PdfDocument, _ sheet: Int) throws -> [(page: Int, box: PdfRect, matrix: PdfMatrix)] {
        let page = document.pages[sheet]
        let forms = document.dict(page.resources, "XObject")!
        var found: [(page: Int, box: PdfRect, matrix: PdfMatrix)] = []
        var current = PdfMatrix.identity
        for op in ContentParser.parse(page.contents()) {
            if op.operator == "cm" {
                let n = op.operands.map { ($0 as! PdfNumber).value }
                current = PdfMatrix(n[0], n[1], n[2], n[3], n[4], n[5])
            } else if op.operator == "Do" {
                let form = document.resolve(forms[(op.operands[0] as! PdfName).value]) as! PdfStream
                let text = Latin1.string(try document.data(form))
                var number = 0
                if let range = text.range(of: #"\(Page \d+\)"#, options: .regularExpression) { number = Int(text[range].filter { $0.isNumber }) ?? 0 }
                found.append((number, current.transform(document.rect(form.dictionary, "BBox")!), current))
            }
        }
        return found
    }

    private func sheets(_ document: PdfDocument) throws -> String {
        try (0..<document.pages.count).map { i in try placed(document, i).map { String($0.page) }.joined(separator: ",") }.joined(separator: " | ")
    }

    func test_fourUpFillsAcrossThenDown() throws {
        let result = try nUp(try PageTestFiles.open(5), 4)
        XCTAssertEqual(result.sheets, 2)
        let document = result.document
        XCTAssertEqual(try sheets(document), "1,2,3,4 | 5")
        XCTAssertEqual(document.pages[0].mediaBox, PdfRect(0, 0, 600, 400))
        let cells = try placed(document, 0)
        let fit = 200.0 / 300
        XCTAssertEqual(cells[0].box.width, 200 * fit, accuracy: 1e-3)
        XCTAssertTrue(cells[1].box.left > cells[0].box.left && cells[1].box.bottom == cells[0].box.bottom)
        XCTAssertTrue(cells[2].box.bottom < cells[0].box.bottom && cells[2].box.left == cells[0].box.left)
        XCTAssertEqual(cells[3].box.left, cells[1].box.left, accuracy: 1e-3)
        XCTAssertEqual(cells[3].box.bottom, cells[2].box.bottom, accuracy: 1e-3)
        XCTAssertEqual(try placed(document, 1)[0].box.left, cells[0].box.left, accuracy: 1e-3)
    }

    func test_everySupportedCountMakesOneSheet() throws {
        for per in [2, 6, 9, 16] {
            let result = try nUp(try PageTestFiles.open(per), per)
            XCTAssertEqual(result.sheets, 1)
            XCTAssertEqual(try placed(result.document, 0).count, per)
            let reopened = try PageTestFiles.reopen(result.document)
            XCTAssertTrue(reopened[0].contains("Page \(per)"))
        }
    }

    func test_gapAndBorderAreDrawn() throws {
        let result = try nUp(try PageTestFiles.open(2), 2, width: 400, height: 300, gap: 10, border: true)
        let cells = try placed(result.document, 0)
        XCTAssertTrue(cells[1].box.left - cells[0].box.right >= 10 - 1e-6)
        XCTAssertTrue(cells[0].box.left >= 10 - 1e-6)
        XCTAssertTrue(Latin1.string(result.document.pages[0].contents()).contains(" re"))
        assertReadFails(try nUp(try PageTestFiles.open(2), 2, width: 400, height: 300, gap: 200), .damaged)
    }

    func test_bookletOrdersPagesForFolding() throws {
        let result = try booklet(try PageTestFiles.open(8))
        XCTAssertEqual(result.sheets, 4)
        XCTAssertEqual(try sheets(result.document), "8,1 | 2,7 | 6,3 | 4,5")
        XCTAssertEqual(result.document.pages[0].mediaBox, PdfRect(0, 0, 400, 300))
    }

    func test_bookletPadsWithBlanksToAMultipleOfFour() throws {
        let result = try booklet(try PageTestFiles.open(5))
        XCTAssertEqual(result.sheets, 4)
        XCTAssertEqual(try sheets(result.document), "1 | 2 | 3 | 4,5")
        XCTAssertTrue(try placed(result.document, 0)[0].box.left > 100)
        XCTAssertTrue(try placed(result.document, 1)[0].box.left < 100)
        XCTAssertEqual(try booklet(try PageTestFiles.open(1)).sheets, 2)
    }

    func test_theSourceIsLeftAlone() throws {
        let document = try PageTestFiles.open(3)
        _ = try nUp(document, 2)
        XCTAssertEqual(PageTestFiles.order(document), [1, 2, 3])
        XCTAssertEqual(try PdfDocument.open(try document.saveRewrite()).repairs, [])
    }

    func test_rotationAndCropBoxAreKept() throws {
        for turn in [90, 180, 270] {
            let document = try PageTestFiles.open(1, pageExtra: { _ in "/Rotate \(turn) /CropBox [20 30 120 230]" })
            let result = try PageOperations.impose(document, [0], ImposeOptions(mode: .nUp, sheetWidth: 400, sheetHeight: 400, perSheet: 2))
            let (_, box, matrix) = try placed(result.document, 0)[0]
            let sideways = turn != 180
            XCTAssertEqual(box.width, 200, accuracy: 1e-3)
            XCTAssertEqual(box.height, sideways ? 100 : 400, accuracy: 1e-3)
            let lowerLeft = matrix.transform(20, 30)
            let upperRight = matrix.transform(120, 230)
            switch turn {
            case 90:
                XCTAssertEqual(lowerLeft.x, box.left, accuracy: 1e-3)
                XCTAssertEqual(lowerLeft.y, box.top, accuracy: 1e-3)
            case 180:
                XCTAssertEqual(lowerLeft.x, box.right, accuracy: 1e-3)
                XCTAssertEqual(lowerLeft.y, box.top, accuracy: 1e-3)
            default:
                XCTAssertEqual(lowerLeft.x, box.right, accuracy: 1e-3)
                XCTAssertEqual(lowerLeft.y, box.bottom, accuracy: 1e-3)
            }
            XCTAssertEqual(upperRight.x, box.right + box.left - lowerLeft.x, accuracy: 1e-3)
            XCTAssertEqual(upperRight.y, box.top + box.bottom - lowerLeft.y, accuracy: 1e-3)
        }
    }

    func test_annotationsWithAnAppearanceAreFlattenedAndTheRestDropped() throws {
        let free = PageTestFiles.free(1)
        let bytes = PageTestFiles.make(1, pageExtra: { _ in "/Annots [\(free) 0 R \(free + 1) 0 R \(free + 2) 0 R]" }, add: { pdf in
            pdf.obj(free, "<</Type /Annot /Subtype /Square /Rect [10 10 60 60] /F 4 /AP <</N \(free + 3) 0 R>>>>")
            pdf.obj(free + 1, "<</Type /Annot /Subtype /Link /Rect [0 0 20 20] /Border [0 0 0]>>")
            pdf.obj(free + 2, "<</Type /Annot /Subtype /Text /Rect [70 70 90 90] /Contents (note)>>")
            pdf.stream(free + 3, "/Type /XObject /Subtype /Form /BBox [0 0 50 50]", "1 0 0 rg 0 0 50 50 re f")
        })
        let result = try PageOperations.impose(try PdfDocument.open(bytes), [0], ImposeOptions(mode: .nUp, sheetWidth: 400, sheetHeight: 300, perSheet: 2))
        XCTAssertEqual(result.annotationsFlattened, 1)
        XCTAssertEqual(result.annotationsDropped, 2)
        let document = try PdfDocument.open(try result.document.saveRewrite())
        XCTAssertEqual(document.repairs, [])
        XCTAssertNil(document.pages[0].dictionary["Annots"])
        let forms = document.dict(document.pages[0].resources, "XObject")!
        let form = document.resolve(forms.entries.first!.value) as! PdfStream
        XCTAssertTrue(Latin1.string(try document.data(form)).contains(" Do"))
    }

    func test_badArgumentsAreRefused() throws {
        let document = try PageTestFiles.open(2)
        assertReadFails(try PageOperations.impose(document, [], ImposeOptions(mode: .nUp, sheetWidth: 400, sheetHeight: 300)), .damaged)
        assertReadFails(try nUp(document, 2, width: 0), .damaged)
    }
}
