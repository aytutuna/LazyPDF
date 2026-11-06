import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Optimize/SanitizerTests.cs: the same cases. The PdfPig assertions (the text and page
// count of the output, the page count of ARunOnNothingToRemoveJustRewrites) have no twin; the engine's own page count and
// text stand in for them.

final class SanitizerTests: XCTestCase {
    func test_scanCountsEachKindAndChangesNothing() throws {
        let document = try PdfDocument.open(try SanitizeKit.dirty())
        let before = try document.saveRewrite()
        let findings = try PdfSanitizer(document).scan()
        XCTAssertTrue(SanitizeKit.count(findings, .javaScript) >= 5)
        XCTAssertEqual(1, SanitizeKit.count(findings, .launchActions))
        XCTAssertEqual(2, SanitizeKit.count(findings, .externalLinks))
        XCTAssertTrue(SanitizeKit.count(findings, .embeddedFiles) >= 1)
        XCTAssertEqual(2, SanitizeKit.count(findings, .comments))
        XCTAssertEqual(1, SanitizeKit.count(findings, .formData))
        XCTAssertEqual(2, SanitizeKit.count(findings, .metadata))
        XCTAssertEqual(1, SanitizeKit.count(findings, .pieceInfo))
        XCTAssertEqual(1, SanitizeKit.count(findings, .thumbnails))
        XCTAssertEqual(2, SanitizeKit.count(findings, .searchIndexes))
        XCTAssertTrue(SanitizeKit.count(findings, .filePaths) >= 1)
        XCTAssertEqual(1, SanitizeKit.count(findings, .previousVersions))
        XCTAssertEqual(findings.map { $0.item.rawValue }.sorted(), findings.map { $0.item.rawValue })
        XCTAssertEqual(before.count, try document.saveRewrite().count)
        for f in findings { XCTAssertFalse(OptimizeText.itemName(f.item).isEmpty) }
    }

    func test_runLeavesNoMarkerInTheBytesOrTheDecodedStreams() throws {
        let dirty = try SanitizeKit.dirty()
        for marker in SanitizeKit.markers { XCTAssertTrue(try OptimizeKit.everywhere(dirty, marker), marker + " should be in the source") }
        let document = try PdfDocument.open(dirty)
        let result = try PdfSanitizer(document).run(SanitizeOptions())
        for marker in SanitizeKit.markers { XCTAssertFalse(try OptimizeKit.everywhere(result.bytes, marker), marker) }
        XCTAssertEqual("Visible text", try OptimizeKit.engineText(result.bytes).trimmingCharacters(in: .whitespacesAndNewlines))
        XCTAssertEqual(1, try PdfDocument.open(result.bytes).pages.count)
        XCTAssertEqual(1, Latin1.string(result.bytes).components(separatedBy: "%%EOF").count - 1)
        XCTAssertEqual(dirty.count, result.sizeBefore)
        XCTAssertEqual(result.bytes.count, result.sizeAfter)
        XCTAssertEqual(2, SanitizeKit.count(result.removed, .comments))
        XCTAssertTrue(result.kept.isEmpty)
    }

    func test_whatWasNotChosenStaysAndIsListedAsKept() throws {
        let document = try PdfDocument.open(try SanitizeKit.dirty())
        let result = try PdfSanitizer(document).run(SanitizeOptions(javaScript: false, comments: false))
        XCTAssertTrue(try OptimizeKit.everywhere(result.bytes, "MARKERJS1"))
        XCTAssertTrue(try OptimizeKit.everywhere(result.bytes, "MARKERNOTE"))
        XCTAssertFalse(try OptimizeKit.everywhere(result.bytes, "MARKERXMP"))
        XCTAssertFalse(try OptimizeKit.everywhere(result.bytes, "MARKERLAUNCH"))
        XCTAssertTrue(SanitizeKit.count(result.kept, .javaScript) >= 5)
        XCTAssertEqual(2, SanitizeKit.count(result.kept, .comments))
        XCTAssertEqual(0, SanitizeKit.count(result.removed, .javaScript))
    }

    func test_altTextOfAnImageIsLeftAlone() throws {
        let document = try PdfDocument.open(try SanitizeKit.dirty())
        let result = try PdfSanitizer(document).run(SanitizeOptions(thumbnails: false))
        XCTAssertTrue(try OptimizeKit.everywhere(result.bytes, "MARKERALT"))
    }

    func test_scriptChainedAfterAGoToIsCutOutOfTheChain() throws {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R>>")
        pdf.obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 200 200]>>")
        pdf.obj(3, "<</Type /Page /Parent 2 0 R /Annots [4 0 R]>>")
        pdf.obj(4, "<</Type /Annot /Subtype /Link /Rect [0 0 10 10] /A <</S /GoTo /D [3 0 R /Fit] /Next [<</S /JavaScript /JS (MARKERJS1)>> <</S /Named /N /NextPage>>]>>>>")
        let document = try PdfDocument.open(pdf.finish())
        let result = try PdfSanitizer(document).run(SanitizeOptions())
        XCTAssertFalse(try OptimizeKit.everywhere(result.bytes, "MARKERJS1"))
        let after = try PdfDocument.open(result.bytes)
        let link = try XCTUnwrap(after.resolve(after.array(after.pages[0].dictionary, "Annots")?.items.first) as? PdfDictionary)
        let action = try XCTUnwrap(after.dict(link, "A"))
        XCTAssertEqual("GoTo", after.name(action, "S"))
        XCTAssertEqual(1, after.array(action, "Next")?.items.count)
    }

    func test_filePathsAreCutToTheFileNameWhenTheAttachmentStays() throws {
        let document = try PdfDocument.open(try SanitizeKit.dirty())
        let result = try PdfSanitizer(document).run(SanitizeOptions(embeddedFiles: false))
        XCTAssertTrue(try OptimizeKit.everywhere(result.bytes, "MARKERATTACH"))
        XCTAssertTrue(try OptimizeKit.everywhere(result.bytes, "MARKERPATH.txt"))
        XCTAssertFalse(try OptimizeKit.everywhere(result.bytes, "Users"))
        XCTAssertFalse(try OptimizeKit.everywhere(result.bytes, "bob"))
    }

    func test_formValuesAreClearedAndTheFieldsStay() throws {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R /AcroForm <</Fields [4 0 R 5 0 R] /DA (/Helv 12 Tf 0 g) /DR <</Font <</Helv 6 0 R>>>>>>>>")
        pdf.obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 200 200]>>")
        pdf.obj(3, "<</Type /Page /Parent 2 0 R /Annots [4 0 R 5 0 R]>>")
        pdf.obj(4, "<</Type /Annot /Subtype /Widget /FT /Tx /T (name) /V (MARKERFORM) /DV (MARKERDEFAULT) /Rect [10 100 150 120] /P 3 0 R>>")
        pdf.obj(5, "<</Type /Annot /Subtype /Widget /FT /Btn /T (agree) /V /Yes /AS /Yes /Rect [10 50 30 70] /P 3 0 R /AP <</N <</Yes 7 0 R /Off 8 0 R>>>>>>")
        pdf.obj(6, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica>>")
        pdf.stream(7, "/Type /XObject /Subtype /Form /BBox [0 0 20 20]", "0 0 20 20 re f")
        pdf.stream(8, "/Type /XObject /Subtype /Form /BBox [0 0 20 20]", "")
        let document = try PdfDocument.open(pdf.finish())
        let result = try PdfSanitizer(document).run(SanitizeOptions())
        XCTAssertEqual(2, SanitizeKit.count(result.removed, .formData))
        XCTAssertFalse(try OptimizeKit.everywhere(result.bytes, "MARKERFORM"))
        XCTAssertFalse(try OptimizeKit.everywhere(result.bytes, "MARKERDEFAULT"))
        let after = try PdfDocument.open(result.bytes)
        let form = PdfForm.read(after)
        XCTAssertEqual(2, form.fields.count)
        XCTAssertTrue((form.find("name")?.value ?? "").isEmpty)
        XCTAssertEqual(false, form.find("agree")?.isChecked)
    }

    func test_blankingAFieldTakesEveryCopyOfTheEnteredValue() throws {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R /AcroForm <</Fields [4 0 R 5 0 R]>>>>")
        pdf.obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 200 200]>>")
        pdf.obj(3, "<</Type /Page /Parent 2 0 R /Annots [4 0 R 5 0 R]>>")
        pdf.obj(4, "<</Type /Annot /Subtype /Widget /FT /Btn /T (agree) /V /Yes /AS /Yes /Rect [10 50 30 70] /P 3 0 R /AP <</N <</Yes 7 0 R>>>>>>")
        pdf.obj(5, "<</Type /Annot /Subtype /Widget /FT /Ch /T (pick) /Opt [(a) (b) (c)] /V (c) /I [2] /Rect [10 100 80 140] /P 3 0 R>>")
        pdf.stream(7, "/Type /XObject /Subtype /Form /BBox [0 0 20 20]", "0 0 20 20 re f")
        let document = try PdfDocument.open(pdf.finish())
        for field in PdfForm.read(document).fields { SanitizeData.blank(document, field.dictionary) }
        let saved = try document.saveRewrite()
        for key in ["/V", "/AS", "/I ", "/AP"] { XCTAssertFalse(try OptimizeKit.everywhere(saved, key), key) }
    }

    func test_aRunOnNothingToRemoveJustRewrites() throws {
        let document = try PdfDocument.open(TestPdf.simple(2))
        let findings = try PdfSanitizer(document).scan()
        XCTAssertTrue(findings.isEmpty)
        let result = try PdfSanitizer(document).run(SanitizeOptions())
        XCTAssertTrue(result.removed.isEmpty)
        XCTAssertEqual(2, try PdfDocument.open(result.bytes).pages.count)
    }
}
