import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Pages/PageDeleteFieldTests.cs: the same cases.

final class PageDeleteFieldTests: XCTestCase {
    // Field a is a widget on page 1; field b has widgets on pages 2 and 3; field c is a tree, group.c, with a widget on page 4.
    private func open() throws -> PdfDocument {
        let n = PageTestFiles.free(4)
        return try PageTestFiles.open(4,
            "/AcroForm <</Fields [\(n) 0 R \(n + 1) 0 R \(n + 4) 0 R] /CO [\(n) 0 R \(n + 1) 0 R]>>",
            pageExtra: { i in
                switch i {
                case 0: return "/Annots [\(n) 0 R]"
                case 1: return "/Annots [\(n + 2) 0 R]"
                case 2: return "/Annots [\(n + 3) 0 R]"
                default: return "/Annots [\(n + 6) 0 R]"
                }
            },
            add: { pdf in
                pdf.obj(n, "<</Type /Annot /Subtype /Widget /FT /Tx /T (a) /V (x) /Rect [0 0 10 10]>>")
                pdf.obj(n + 1, "<</FT /Tx /T (b) /V (y) /Kids [\(n + 2) 0 R \(n + 3) 0 R]>>")
                pdf.obj(n + 2, "<</Type /Annot /Subtype /Widget /Parent \(n + 1) 0 R /Rect [0 0 10 10]>>")
                pdf.obj(n + 3, "<</Type /Annot /Subtype /Widget /Parent \(n + 1) 0 R /Rect [0 0 10 10]>>")
                pdf.obj(n + 4, "<</T (group) /Kids [\(n + 5) 0 R]>>")
                pdf.obj(n + 5, "<</T (c) /Parent \(n + 4) 0 R /FT /Tx /Kids [\(n + 6) 0 R]>>")
                pdf.obj(n + 6, "<</Type /Annot /Subtype /Widget /Parent \(n + 5) 0 R /Rect [0 0 10 10]>>")
            })
    }

    private func fields(_ document: PdfDocument) -> [Int] {
        (document.array(document.dict(document.catalog, "AcroForm"), "Fields")?.items ?? [])
            .compactMap { ($0 as? PdfReference)?.number }.map { $0 - PageTestFiles.free(4) }
    }

    func test_aFieldWhoseOnlyWidgetIsOnADeletedPageLeavesTheForm() throws {
        let document = try open()
        try PageOperations.delete(document, [0])
        XCTAssertEqual(fields(document), [1, 4])
        let order = try XCTUnwrap(document.array(document.dict(document.catalog, "AcroForm"), "CO"))
        XCTAssertEqual(order.items.count, 1)
    }

    func test_aFieldWithAWidgetLeftStaysWithThatWidgetOnly() throws {
        let document = try open()
        let n = PageTestFiles.free(4)
        try PageOperations.delete(document, [1])
        XCTAssertEqual(fields(document), [0, 1, 4])
        let kids = try XCTUnwrap(document.array(document.get(n + 1) as? PdfDictionary, "Kids"))
        XCTAssertEqual(kids.items.compactMap { $0 as? PdfReference }, [PdfReference(n + 3, 0)])
        XCTAssertEqual(kids.items.count, 1)
    }

    func test_aFieldGoesWhenItsLastWidgetDoes() throws {
        let document = try open()
        try PageOperations.delete(document, [1, 2])
        XCTAssertEqual(fields(document), [0, 4])
    }

    func test_aTreeOfFieldsGoesFromTheLeafUp() throws {
        let document = try open()
        let n = PageTestFiles.free(4)
        try PageOperations.delete(document, [3])
        XCTAssertEqual(fields(document), [0, 1])
        XCTAssertEqual(try XCTUnwrap(document.array(document.get(n + 4) as? PdfDictionary, "Kids")).items.count, 0)
    }

    func test_theFormReadsBackWithOnlyTheFieldsOnTheRemainingPages() throws {
        let document = try open()
        try PageOperations.delete(document, [0, 3])
        let again = try PdfDocument.open(try document.saveRewrite())
        let form = try XCTUnwrap(again.dict(again.catalog, "AcroForm"))
        XCTAssertEqual(try XCTUnwrap(again.array(form, "Fields")).items.count, 1)
        XCTAssertEqual(again.repairs, [])
    }
}
