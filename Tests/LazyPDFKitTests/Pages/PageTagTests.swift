import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Pages/PageTagTests.cs: the same cases.

final class PageTagTests: XCTestCase {
    // Four pages with a heading each, a table across pages 2 and 3 and a link annotation on page 2.
    private static func tagged() throws -> PdfDocument {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R /StructTreeRoot 12 0 R /MarkInfo <</Marked true>> /Lang (en)>>")
        pdf.obj(2, "<</Type /Pages /Kids [4 0 R 5 0 R 6 0 R 7 0 R] /Count 4 /MediaBox [0 0 200 300]>>")
        pdf.obj(3, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica>>")
        for i in 0..<4 {
            let annots = i == 1 ? "/Annots [22 0 R]" : ""
            pdf.obj(4 + i, "<</Type /Page /Parent 2 0 R /Contents \(8 + i) 0 R /Resources <</Font <</F1 3 0 R>>>> /StructParents \(i) \(annots)>>")
            let row = i == 1 || i == 2 ? "/TR <</MCID 1>> BDC BT /F1 12 Tf 20 50 Td (Row \(i + 1)) Tj ET EMC" : ""
            pdf.stream(8 + i, "", "/H1 <</MCID 0>> BDC BT /F1 12 Tf 20 100 Td (Page \(i + 1)) Tj ET EMC \(row)")
        }
        pdf.obj(12, "<</Type /StructTreeRoot /K 13 0 R /ParentTree 30 0 R /ParentTreeNextKey 6 /RoleMap <</Head /H1>>>>")
        pdf.obj(13, "<</Type /StructElem /S /Document /P 12 0 R /K [14 0 R 15 0 R 18 0 R 16 0 R 17 0 R 21 0 R]>>")
        for i in 0..<4 { pdf.obj(14 + i, "<</Type /StructElem /S /H1 /P 13 0 R /Pg \(4 + i) 0 R /K 0 /Alt (Heading \(i + 1))>>") }
        pdf.obj(18, "<</Type /StructElem /S /Table /P 13 0 R /K [19 0 R 20 0 R] /Alt (TABLEALT)>>")
        pdf.obj(19, "<</Type /StructElem /S /TR /P 18 0 R /Pg 5 0 R /K 1>>")
        pdf.obj(20, "<</Type /StructElem /S /TR /P 18 0 R /Pg 6 0 R /K 1>>")
        pdf.obj(21, "<</Type /StructElem /S /Link /P 13 0 R /Pg 5 0 R /K <</Type /OBJR /Pg 5 0 R /Obj 22 0 R>>>>")
        pdf.obj(22, "<</Type /Annot /Subtype /Link /Rect [10 10 50 30] /Border [0 0 0] /StructParent 5 /A <</S /URI /URI (http://example.com)>>>>")
        pdf.obj(30, "<</Nums [0 [14 0 R] 1 [15 0 R 19 0 R] 2 [16 0 R 20 0 R] 3 [17 0 R] 5 21 0 R]>>")
        return try PdfDocument.open(pdf.finish())
    }

    private func roles(_ document: PdfDocument, _ node: PdfObject?) -> String {
        guard let element = document.resolve(node) as? PdfDictionary else { return "" }
        let kids = document.resolve(element["K"])
        let below: [PdfObject] = (kids as? PdfArray)?.items ?? (element["K"].map { [$0] } ?? [])
        return ([document.name(element, "S") ?? ""] + below.map { roles(document, $0) }).filter { $0 != "" }.joined(separator: " ")
    }

    private func root(_ document: PdfDocument) -> PdfDictionary { document.dict(document.catalog, "StructTreeRoot")! }

    private func keys(_ document: PdfDocument) -> [Int] {
        PdfNumberTree.read(document, root(document)["ParentTree"]).map { $0.key }
    }

    private func saved(_ part: PdfDocument) throws -> (PdfDocument, String) {
        let bytes = try part.saveRewrite()
        let again = try PdfDocument.open(bytes)
        XCTAssertEqual(again.repairs, [])
        return (again, Latin1.string(bytes))
    }

    private func marked(_ document: PdfDocument) -> Bool {
        guard let mark = document.dict(document.catalog, "MarkInfo") else { return false }
        return (document.resolve(mark["Marked"]) as? PdfBoolean)?.value == true
    }

    func test_extractKeepsTheElementsOfThePageTaken() throws {
        let (part, text) = try saved(PageAssembly.extract(Self.tagged(), [1]))
        XCTAssertEqual(roles(part, root(part)), "Document H1 Table TR Link")
        XCTAssertEqual(keys(part), [1, 5])
        let page = part.pages[0].dictionary
        XCTAssertEqual(part.integer(page, "StructParents"), 1)
        let annotation = part.array(page, "Annots")!.items[0] as! PdfReference
        XCTAssertEqual(part.integer(part.resolve(annotation) as? PdfDictionary, "StructParent"), 5)
        let link = part.resolve(PdfNumberTree.read(part, root(part)["ParentTree"]).first { $0.key == 5 }!.value) as! PdfDictionary
        XCTAssertEqual((part.dict(link, "K")!["Obj"] as! PdfReference).number, annotation.number)
        XCTAssertTrue(text.contains("Heading 2"))
        for gone in ["Heading 1", "Heading 3", "TABLEALT", "Row 3", "Page 3"] { XCTAssertFalse(text.contains(gone), gone) }
        XCTAssertTrue(try AccessibilityChecker.check(part)[.taggedContent].status == .passed)
        XCTAssertTrue(marked(part))
    }

    func test_extractLeavesOutAnElementWhoseContentIsAllOnOtherPages() throws {
        let (part, text) = try saved(PageAssembly.extract(Self.tagged(), [0]))
        XCTAssertEqual(roles(part, root(part)), "Document H1")
        XCTAssertEqual(keys(part), [0])
        XCTAssertFalse(text.contains("TABLEALT"))
        XCTAssertTrue(try AccessibilityChecker.check(part)[.taggedContent].status == .passed)
    }

    func test_mergeGivesEachSourceKeysOfItsOwn() throws {
        let (merged, _) = try saved(PageAssembly.merge([MergeSource(Self.tagged()), MergeSource(Self.tagged())]))
        XCTAssertEqual(keys(merged), [0, 1, 2, 3, 5, 6, 7, 8, 9, 11])
        XCTAssertEqual(merged.pages.map { merged.integer($0.dictionary, "StructParents")! }, [0, 1, 2, 3, 6, 7, 8, 9])
        let top = root(merged)
        XCTAssertEqual(merged.integer(top, "ParentTreeNextKey"), 12)
        XCTAssertEqual(roles(merged, top), "Document H1 H1 Table TR TR H1 H1 Link Document H1 H1 Table TR TR H1 H1 Link")
        for kid in merged.array(top, "K")!.items {
            XCTAssertEqual(((merged.resolve(kid) as! PdfDictionary)["P"] as! PdfReference).number, (merged.catalog["StructTreeRoot"] as! PdfReference).number)
        }
        XCTAssertTrue(try AccessibilityChecker.check(merged)[.taggedContent].status == .passed)
        XCTAssertTrue(marked(merged))
    }

    func test_mergeWithAnUntaggedSourceIsNotMarked() throws {
        let (merged, _) = try saved(PageAssembly.merge([MergeSource(Self.tagged(), [1]), MergeSource(PageTestFiles.open(2))]))
        XCTAssertEqual(keys(merged), [1, 5])
        XCTAssertFalse(marked(merged))
        XCTAssertFalse(merged.pages[1].dictionary.containsKey("StructParents"))
    }
}
