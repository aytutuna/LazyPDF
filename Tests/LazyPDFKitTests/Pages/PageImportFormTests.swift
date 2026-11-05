import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Pages/PageImportFormTests.cs: the same cases. The PdfPig open in
// TheImportedFormReadsBackAndOpensInPdfPig has no twin; the text layer reads the saved file instead.

final class PageImportFormTests: XCTestCase {
    // Page 4 carries a text field, one widget of a field "grp" and a signature field; page 5 carries the other widget of "grp".
    private let form = "/AcroForm <</Fields [50 0 R 52 0 R 54 0 R] /DA (/Helv 0 Tf 0 g) /DR <</Font <</Helv 60 0 R>>>> /NeedAppearances true>>"

    private func source() throws -> PdfDocument {
        try PdfDocument.open(PageImportTests.source("/Annots [50 0 R 51 0 R 54 0 R]", form, { pdf in
            pdf.obj(50, "<</Type /Annot /Subtype /Widget /FT /Tx /T (name) /V (Alice) /DA (/Helv 12 Tf 0 g) /Rect [0 0 50 20]>>")
                .obj(51, "<</Type /Annot /Subtype /Widget /Parent 52 0 R /Rect [0 30 50 50]>>")
                .obj(52, "<</T (grp) /FT /Tx /V (G) /Kids [51 0 R 53 0 R]>>")
                .obj(53, "<</Type /Annot /Subtype /Widget /Parent 52 0 R /Rect [0 60 50 80]>>")
                .obj(54, "<</Type /Annot /Subtype /Widget /FT /Sig /T (sig) /V 55 0 R /Rect [0 90 50 110]>>")
                .obj(55, "<</Type /Sig /Filter /Adobe.PPKLite /Contents <0000> /ByteRange [0 1 2 3]>>")
                .obj(60, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica>>")
        }, extra5: "/Annots [53 0 R]"))
    }

    private func roots(_ document: PdfDocument) -> [PdfDictionary] {
        (document.array(document.dict(document.catalog, "AcroForm"), "Fields")?.items ?? []).compactMap { document.resolve($0) as? PdfDictionary }
    }

    private func text(_ document: PdfDocument, _ field: PdfDictionary, _ key: String) -> String {
        PageTestFiles.text(document.resolve(field[key]))
    }

    private func names(_ document: PdfDocument) -> String {
        roots(document).map { text(document, $0, "T") }.joined(separator: ",")
    }

    func test_theFieldsOfAnImportedPageJoinTheTargetsForm() throws {
        let target = try PageTestFiles.open(1)
        try PageOperations.importPages(target, try source(), [0], 1)
        let again = try PdfDocument.open(try target.saveRewrite())
        XCTAssertEqual(names(again), "name,grp,sig")
        let fields = roots(again)
        XCTAssertEqual(text(again, fields[0], "V"), "Alice")
        XCTAssertEqual(text(again, fields[1], "V"), "G")
        XCTAssertFalse(fields[2].containsKey("V"))
        XCTAssertEqual(text(again, fields[0], "DA"), "/Helv 12 Tf 0 g")
        XCTAssertEqual(text(again, fields[1], "DA"), "/Helv 0 Tf 0 g")
        XCTAssertEqual(again.bool(again.dict(again.catalog, "AcroForm"), "NeedAppearances"), true)
        XCTAssertTrue(try XCTUnwrap(again.dict(again.dict(again.dict(again.catalog, "AcroForm"), "DR"), "Font")).containsKey("Helv"))
    }

    func test_aFieldKeepsOnlyTheWidgetsThatCameAcross() throws {
        let target = try PageTestFiles.open(1)
        try PageOperations.importPages(target, try source(), [0], 1)
        let again = try PdfDocument.open(try target.saveRewrite())
        let group = roots(again)[1]
        let kids = try XCTUnwrap(again.array(group, "Kids")).items
        XCTAssertEqual(kids.count, 1)
        let widget = try XCTUnwrap(again.resolve(kids[0]) as? PdfDictionary)
        assertSame(group, again.resolve(widget["Parent"]))
        let annots = try XCTUnwrap(again.array(again.pages[1].dictionary, "Annots")).items
        XCTAssertTrue(annots.contains { ($0 as? PdfReference) == (kids[0] as? PdfReference) })
    }

    func test_widgetsOfOneFieldOnSeveralImportedPagesShareTheField() throws {
        let target = try PageTestFiles.open(1)
        try PageOperations.importPages(target, try source(), [0, 1], 1)
        let again = try PdfDocument.open(try target.saveRewrite())
        XCTAssertEqual(names(again), "name,grp,sig")
        XCTAssertEqual(try XCTUnwrap(again.array(roots(again)[1], "Kids")).items.count, 2)
    }

    func test_aSignatureFieldKeepsItsLookAndLosesTheSignature() throws {
        let target = try PageTestFiles.open(1)
        try PageOperations.importPages(target, try source(), [0], 1)
        let again = try PdfDocument.open(try target.saveRewrite())
        XCTAssertFalse(TestPdf.contains(try target.saveRewrite(), "Adobe.PPKLite"))
        let widget = roots(again)[2]
        XCTAssertEqual(again.name(widget, "Subtype"), "Widget")
        XCTAssertTrue(widget.containsKey("Rect"))
    }

    func test_aNameThatIsTakenGetsASuffixSoTheValuesStaySeparate() throws {
        let target = try PageTestFiles.open(1)
        let imported = try source()
        try PageOperations.importPages(target, imported, [0], 1)
        try PageOperations.importPages(target, imported, [0], 1)
        try PageOperations.importPages(target, imported, [0, 0], 1)
        let again = try PdfDocument.open(try target.saveRewrite())
        XCTAssertEqual(names(again), "name,grp,sig,name_2,grp_2,sig_2,name_3,grp_3,sig_3,name_4,grp_4,sig_4")
        XCTAssertEqual(roots(again).count, 12)
        XCTAssertEqual(again.pages.count, 5)
    }

    func test_aFormTheTargetHadIsKeptAsItWas() throws {
        let target = try PageTestFiles.open(1, "/AcroForm <</Fields [20 0 R] /DR <</Font <</Helv 21 0 R>>>>>>", add: { pdf in
            pdf.obj(20, "<</Type /Annot /Subtype /Widget /FT /Tx /T (name) /V (Bob) /Rect [0 0 10 10]>>")
                .obj(21, "<</Type /Font /Subtype /Type1 /BaseFont /Times-Roman>>")
        })
        try PageOperations.importPages(target, try source(), [0], 1)
        let again = try PdfDocument.open(try target.saveRewrite())
        XCTAssertEqual(names(again), "name,name_2,grp,sig")
        XCTAssertEqual(text(again, roots(again)[0], "V"), "Bob")
        XCTAssertEqual(text(again, roots(again)[1], "V"), "Alice")
        let fonts = try XCTUnwrap(again.dict(again.dict(again.dict(again.catalog, "AcroForm"), "DR"), "Font"))
        XCTAssertEqual(again.name(again.resolve(fonts["Helv"]) as? PdfDictionary, "BaseFont"), "Times-Roman")
    }

    func test_aDuplicatedPageGetsFieldsOfItsOwn() throws {
        let target = try source()
        try PageOperations.duplicate(target, [0])
        let again = try PdfDocument.open(try target.saveRewrite())
        XCTAssertEqual(names(again), "name,grp,sig,name_2,grp_2,sig_2")
        let firstWidgets = try XCTUnwrap(again.array(again.pages[0].dictionary, "Annots")).items.compactMap { $0 as? PdfReference }
        let secondWidgets = try XCTUnwrap(again.array(again.pages[1].dictionary, "Annots")).items.compactMap { $0 as? PdfReference }
        XCTAssertEqual(Set(firstWidgets).intersection(secondWidgets), [])
        XCTAssertEqual(try XCTUnwrap(again.array(roots(again)[1], "Kids")).items.count, 2)
        XCTAssertEqual(try XCTUnwrap(again.array(roots(again)[4], "Kids")).items.count, 1)
    }

    func test_theImportedFormReadsBackAndOpensInPdfPig() throws {
        let target = try PageTestFiles.open(1)
        try PageOperations.importPages(target, try source(), [0, 1], 1)
        XCTAssertEqual(try PageTestFiles.reopen(target).count, 3)
    }
}
