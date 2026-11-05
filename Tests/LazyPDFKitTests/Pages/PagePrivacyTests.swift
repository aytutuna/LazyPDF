import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Pages/PagePrivacyTests.cs: the same cases. Nothing of a page that was taken out may be
// left in what is written: the marker of each page appears in its content, in a form it draws, in a note on it, and in a
// resource the whole file lists.

final class PagePrivacyTests: XCTestCase {
    private func marker(_ page: Int) -> String { "MARKER-\(page)-\(page * 7919)" }

    /// Three pages (objects 10 to 12). With `shared` the root's /Resources lists all three forms, which is how some writers
    /// give every page everything; without it each page lists its own. A link on page 1 goes to page 2; page 3 has a
    /// bookmark, a named destination and a bead.
    private func source(shared: Bool = true) -> [UInt8] {
        func own(_ page: Int) -> String { shared ? "" : "/Resources <</Font <</F1 3 0 R>> /XObject <</Fm\(page) \(19 + page) 0 R>>>>" }
        let pdf = TestPdf()
            .obj(1, "<</Type /Catalog /Pages 2 0 R /Outlines 30 0 R /Dests <</two [11 0 R /Fit]>> /Names <</Dests <</Names [(three) [12 0 R /Fit]]>>>> /Threads [40 0 R]>>")
            .obj(2, "<</Type /Pages /Kids [10 0 R 11 0 R 12 0 R] /Count 3 /MediaBox [0 0 200 200] " + (shared ? "/Resources <</Font <</F1 3 0 R>> /XObject <</Fm1 20 0 R /Fm2 21 0 R /Fm3 22 0 R>>>>" : "") + ">>")
            .obj(3, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica>>")
            .obj(10, "<</Type /Page /Parent 2 0 R /Contents 13 0 R /Annots [50 0 R 51 0 R] " + own(1) + ">>")
            .obj(11, "<</Type /Page /Parent 2 0 R /Contents 14 0 R /Annots [52 0 R] " + own(2) + ">>")
            .obj(12, "<</Type /Page /Parent 2 0 R /Contents 15 0 R /B [41 0 R] " + own(3) + ">>")
            .stream(13, "", "BT /F1 12 Tf (\(marker(1))) Tj ET /Fm1 Do")
            .stream(14, "", "BT /F1 12 Tf (\(marker(2))) Tj ET /Fm2 Do")
            .stream(15, "", "BT /F1 12 Tf (\(marker(3))) Tj ET /Fm3 Do")
            .stream(20, "/Type /XObject /Subtype /Form /BBox [0 0 10 10] /Resources <<>>", "BT (\(marker(1))-form) Tj ET")
            .stream(21, "/Type /XObject /Subtype /Form /BBox [0 0 10 10]", "BT (\(marker(2))-form) Tj ET")
            .stream(22, "/Type /XObject /Subtype /Form /BBox [0 0 10 10]", "BT (\(marker(3))-form) Tj ET")
            .obj(30, "<</Type /Outlines /First 31 0 R /Last 31 0 R /Count 1>>")
            .obj(31, "<</Title (Chapter) /Parent 30 0 R /Dest [12 0 R /Fit]>>")
            .obj(40, "<</Type /Thread /F 41 0 R>>")
            .obj(41, "<</Type /Bead /T 40 0 R /N 41 0 R /V 41 0 R /P 12 0 R /R [0 0 10 10]>>")
            .obj(50, "<</Type /Annot /Subtype /Link /Rect [0 0 10 10] /Dest [11 0 R /Fit]>>")
            .obj(51, "<</Type /Annot /Subtype /Text /Rect [0 0 10 10] /Contents (\(marker(1))-note)>>")
            .obj(52, "<</Type /Annot /Subtype /Text /Rect [0 0 10 10] /Contents (\(marker(2))-note)>>")
        return pdf.finish()
    }

    /// The marker written anywhere in the file: in the bytes, in a stream once decoded, in an object once read.
    private func holds(_ file: [UInt8], _ marker: String) throws -> Bool {
        if TestPdf.contains(file, marker) { return true }
        let document = try PdfDocument.open(file)
        for number in document.objectNumbers {
            switch document.get(number) {
            case let stream as PdfStream:
                if Latin1.string(try document.data(stream)).contains(marker) { return true }
            case let found as PdfDictionary:
                if found.description.contains(marker) { return true }
            case let found as PdfArray:
                if found.description.contains(marker) { return true }
            default:
                break
            }
        }
        return false
    }

    private func assertOnly(_ file: [UInt8], _ pages: [Int], line: UInt = #line) throws {
        for page in 1...3 {
            XCTAssertEqual(pages.contains(page), try holds(file, marker(page)), "page \(page)", line: line)
        }
    }

    func test_theMarkersAreFoundWhereTheyAre() throws {
        try assertOnly(try PdfDocument.open(source()).saveRewrite(), [1, 2, 3])
        try assertOnly(try PdfDocument.open(source()).saveRewrite(PdfSaveOptions(useObjectStreams: true)), [1, 2, 3])
    }

    func test_anExtractedPartHoldsOnlyItsOwnPages() throws {
        for packed in [false, true] {
            let options = PdfSaveOptions(useObjectStreams: packed)
            try assertOnly(try PageAssembly.extract(try PdfDocument.open(source()), [0]).saveRewrite(options), [1])
            try assertOnly(try PageAssembly.extract(try PdfDocument.open(source()), [1]).saveRewrite(options), [2])
            try assertOnly(try PageAssembly.extract(try PdfDocument.open(source()), [2]).saveRewrite(options), [3])
            try assertOnly(try PageAssembly.extract(try PdfDocument.open(source()), [2, 0]).saveRewrite(options), [1, 3])
        }
    }

    func test_everySplitPartHoldsOnlyItsOwnPages() throws {
        let parts = try PageAssembly.splitEvery(try PdfDocument.open(source()), 1)
        XCTAssertEqual(parts.count, 3)
        for i in 0..<3 { try assertOnly(try parts[i].saveRewrite(), [i + 1]) }
    }

    func test_aNewDocumentHasNothingOfTheSourcesStructure() throws {
        let part = try PageAssembly.extract(try PdfDocument.open(source()), [0])
        let again = try PdfDocument.open(try part.saveRewrite())
        for key in ["Outlines", "Dests", "Names", "Threads", "PageLabels", "StructTreeRoot", "OpenAction"] {
            XCTAssertFalse(again.catalog.containsKey(key), key)
        }
        XCTAssertEqual(again.pages.count, 1)
        XCTAssertEqual(again.repairs, [])
        XCTAssertEqual(again.objectNumbers.filter { n in (again.get(n) as? PdfDictionary).map { again.name($0, "Type") == "Page" } ?? false }.count, 1)
    }

    func test_aResourceThePageNeverMentionsIsNotCopied() throws {
        let part = try PageAssembly.extract(try PdfDocument.open(source()), [0])
        let again = try PdfDocument.open(try part.saveRewrite())
        let forms = try XCTUnwrap(again.dict(again.pages[0].resources, "XObject"))
        XCTAssertEqual(forms.entries.map { $0.key }, ["Fm1"])
    }

    func test_aDeletedPageLeavesNothingInARewrite() throws {
        for packed in [false, true] {
            var document = try PdfDocument.open(source(shared: false))
            try PageOperations.delete(document, [1])
            try assertOnly(try document.saveRewrite(PdfSaveOptions(useObjectStreams: packed)), [1, 3])
            document = try PdfDocument.open(source(shared: false))
            try PageOperations.delete(document, [2])
            try assertOnly(try document.saveRewrite(PdfSaveOptions(useObjectStreams: packed)), [1, 2])
        }
    }

    func test_aDeleteAfterAnEditSessionCommitStillLeavesNothingInACompactSave() throws {
        let session = try PdfEditSession.open(source(shared: false))
        try PageOperations.delete(session.document, [0, 2])
        XCTAssertTrue(try session.commit("Delete"))
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("privacy.pdf").path
        try session.saveCompact(path)
        try assertOnly([UInt8](try Data(contentsOf: URL(fileURLWithPath: path))), [2])
    }

    func test_theIncrementalFileStillHoldsWhatWasDeletedAsAnyHistoryDoes() throws {
        let session = try PdfEditSession.open(source())
        try PageOperations.delete(session.document, [1])
        XCTAssertTrue(try session.commit("Delete"))
        XCTAssertTrue(try holds(session.current, marker(2)))
    }
}
