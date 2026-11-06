import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Redaction/RedactCopiesTests.cs: the same cases. Other places that keep a copy of what was
// removed: image keys, the tag tree, XMP, private data, the file id.

final class RedactCopiesTests: XCTestCase {
    private let pixels = "ZQXPIXELSDATAZQXPIXELSDATAZQXPIXELSDATAZQXPIXELSDATAZQXPIXELSDATA123"
    private let imageEntries = "/Type /XObject /Subtype /Image /Width 8 /Height 8 /ColorSpace /DeviceGray /BitsPerComponent 8"
    private let place = "q 160 0 0 160 100 100 cm /Im1 Do Q"
    private let topLeft = PdfRect(100, 220, 140, 260)

    private func redact(_ document: PdfDocument, _ mark: PdfRect? = nil, _ options: RedactionOptions? = nil) throws -> RedactionResult {
        try PdfRedactor(document).apply([RedactionMark.fromRect(0, mark ?? topLeft)], options)
    }

    func test_cutImageDropsItsAlternatesOpiAndBytesPastTheLastRow() throws {
        let document = try RedactionKit.page(place, "/XObject <</Im1 6 0 R>>") { pdf in
            pdf.stream(6, "\(self.imageEntries) /Alternates [<</Image 7 0 R>>] /OPI <</Version 1.3 /F (ZQXOPIPATH)>>", self.pixels + "ZQXTRAILING")
            pdf.stream(7, self.imageEntries, self.pixels.replacingOccurrences(of: "PIXELS", with: "ALTERN"))
        }
        let result = try redact(document)
        _ = try RedactionKit.open(result)
        XCTAssertFalse(RedactionKit.holds(result.bytes, "ZQXALTERN"))
        XCTAssertFalse(RedactionKit.holds(result.bytes, "ZQXOPIPATH"))
        XCTAssertFalse(RedactionKit.holds(result.bytes, "ZQXTRAILING"))
        XCTAssertEqual(result.report.images, 1)
    }

    private func tag(_ document: PdfDocument, _ kid: PdfObject, _ alt: String) throws {
        let root = PdfDictionary()
        root["Type"] = PdfName("StructTreeRoot")
        let top = PdfDictionary()
        let figure = PdfDictionary()
        let rootRef = try document.add(root)
        let topRef = try document.add(top)
        let figureRef = try document.add(figure)
        root["K"] = PdfArray([topRef])
        top["Type"] = PdfName("StructElem")
        top["S"] = PdfName("Document")
        top["P"] = rootRef
        top["K"] = PdfArray([figureRef])
        figure["Type"] = PdfName("StructElem")
        figure["S"] = PdfName("Figure")
        figure["P"] = topRef
        figure["Pg"] = document.pages[0].reference
        figure["K"] = kid
        figure["Alt"] = PdfText.toObject(alt)
        document.catalog["StructTreeRoot"] = rootRef
    }

    private func imageInForm(_ page: String, _ form: String) throws -> PdfDocument {
        try RedactionKit.page(page, "/XObject <</Fm1 6 0 R>>") { pdf in
            pdf.stream(6, "/Type /XObject /Subtype /Form /BBox [0 0 600 800] /Resources <</XObject <</Im1 7 0 R>>>>", form)
            pdf.stream(7, self.imageEntries, self.pixels)
        }
    }

    func test_removalInsideAFormReachesTheElementOfTheSequenceThatCallsIt() throws {
        let document = try imageInForm("/Figure <</MCID 0>> BDC /Fm1 Do EMC", place)
        try tag(document, PdfNumber(0), "Signature of Jane Doe")
        let result = try redact(document)
        _ = try RedactionKit.open(result)
        XCTAssertFalse(RedactionKit.holds(result.bytes, "Signature of Jane Doe"))
    }

    func test_contentItemInACopiedFormDoesNotKeepTheOriginalReachable() throws {
        let document = try imageInForm("/Fm1 Do", "/Figure <</MCID 0>> BDC " + place + " EMC")
        let item = PdfDictionary()
        item["Type"] = PdfName("MCR")
        item["Pg"] = document.pages[0].reference
        item["Stm"] = PdfReference(6, 0)
        item["MCID"] = PdfNumber(0)
        try tag(document, item, "Signature of Jane Doe")
        let result = try redact(document)
        _ = try RedactionKit.open(result)
        XCTAssertFalse(RedactionKit.holds(result.bytes, pixels))
        XCTAssertFalse(RedactionKit.holds(result.bytes, "Signature of Jane Doe"))
    }

    func test_objectReferenceToACutImageDoesNotKeepTheOriginal() throws {
        let document = try RedactionKit.page(place, "/XObject <</Im1 6 0 R>>") { pdf in pdf.stream(6, self.imageEntries, self.pixels) }
        let item = PdfDictionary()
        item["Type"] = PdfName("OBJR")
        item["Pg"] = document.pages[0].reference
        item["Obj"] = PdfReference(6, 0)
        try tag(document, item, "Signature of Jane Doe")
        let result = try redact(document)
        _ = try RedactionKit.open(result)
        XCTAssertFalse(RedactionKit.holds(result.bytes, pixels))
        XCTAssertFalse(RedactionKit.holds(result.bytes, "Signature of Jane Doe"))
    }

    func test_contentItemWithoutATypeIsNotTakenForAnElement() throws {
        let document = try RedactionKit.page("/P <</MCID 0>> BDC BT /F1 12 Tf 100 700 Td (ZQXMARKER) Tj ET EMC")
        let item = PdfDictionary()
        item["Pg"] = document.pages[0].reference
        item["MCID"] = PdfNumber(0)
        try tag(document, item, "described ZQXALT")
        let result = try PdfRedactor(document).apply(try RedactionKit.marksOf(document, 0, "ZQXMARKER"))
        _ = try RedactionKit.open(result)
        XCTAssertFalse(RedactionKit.holds(result.bytes, "described ZQXALT"))
    }

    private let packet = "<x:xmpmeta xmlns:x=\"adobe:ns:meta/\"><rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\"><rdf:Description>"
        + "<dc:title>kept title</dc:title>"
        + "<xmp:Thumbnails><rdf:Alt><rdf:li><xmpGImg:image>ZQXTHUMBNAIL</xmpGImg:image></rdf:li></rdf:Alt></xmp:Thumbnails>"
        + "<xmpMM:History><rdf:Seq><rdf:li>ZQXHISTORY</rdf:li></rdf:Seq></xmpMM:History>"
        + "</rdf:Description></rdf:RDF></x:xmpmeta>"

    private func withPrivateData() throws -> PdfDocument {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R /Metadata 7 0 R /PieceInfo <</App <</Data (ZQXPIECE)>>>>>>")
        pdf.obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 600 800]>>")
        pdf.obj(3, "<</Type /Page /Parent 2 0 R /Contents 4 0 R /Resources <</Font <</F1 5 0 R>> /XObject <</Fm1 6 0 R>>>>>>")
        pdf.stream(4, "", "/Fm1 Do BT /F1 12 Tf 100 700 Td (ZQXMARKER) Tj ET")
        pdf.obj(5, RedactionKit.helvetica)
        pdf.stream(6, "/Type /XObject /Subtype /Form /BBox [0 0 10 10] /PieceInfo <</App <</Data (ZQXFORMPIECE)>>>>", "0 g 0 0 1 1 re f")
        pdf.stream(7, "/Type /Metadata /Subtype /XML", packet)
        return try PdfDocument.open(pdf.finish("/Root 1 0 R /ID [<0102030405060708090a0b0c0d0e0f10> <0102030405060708090a0b0c0d0e0f10>]"))
    }

    func test_pageCopiesInXmpAndPrivateDataGoWithoutAskingForMetadataChanges() throws {
        let document = try withPrivateData()
        let result = try PdfRedactor(document).apply(try RedactionKit.marksOf(document, 0, "ZQXMARKER"))
        let output = try RedactionKit.open(result)
        for gone in ["ZQXTHUMBNAIL", "ZQXHISTORY", "ZQXPIECE", "ZQXFORMPIECE"] { XCTAssertFalse(RedactionKit.holds(result.bytes, gone), gone) }
        let metadata = try XCTUnwrap(output.stream(output.catalog, "Metadata"))
        XCTAssertTrue(String(decoding: try output.data(metadata), as: UTF8.self).contains("kept title"))
    }

    func test_openOutputHasAnIdOfItsOwn() throws {
        let document = try withPrivateData()
        let result = try PdfRedactor(document).apply(try RedactionKit.marksOf(document, 0, "ZQXMARKER"))
        let output = try RedactionKit.open(result)
        XCTAssertNotEqual(document.id[0], output.id[0])
    }

    private func withWordElsewhere() throws -> PdfDocument {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R /Metadata 9 0 R>>")
        pdf.obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 600 800]>>")
        pdf.obj(3, "<</Type /Page /Parent 2 0 R /Contents 4 0 R /Annots [6 0 R] /Resources <</Font <</F1 5 0 R>> /XObject <</Fm1 7 0 R>>>>>>")
        pdf.stream(4, "", "/Fm1 Do BT /F1 12 Tf 100 700 Td (ZQXMARKER) Tj ET")
        pdf.obj(5, RedactionKit.helvetica)
        pdf.obj(6, "<</Type /Annot /Subtype /Link /Rect [10 10 50 50] /A <</S /URI /URI (http://example.com/ZQXMARKER)>>>>")
        pdf.stream(7, "/Type /XObject /Subtype /Form /BBox [0 0 10 10] /Metadata 8 0 R", "0 g 0 0 1 1 re f")
        pdf.stream(8, "/Type /Metadata /Subtype /XML", "<x:xmpmeta><dc:title>ZQXMARKER in a form</dc:title></x:xmpmeta>")
        pdf.stream(9, "/Type /Metadata /Subtype /XML", "<x:xmpmeta><dc:title>ZQXMARKER in the catalog</dc:title></x:xmpmeta>")
        let document = try PdfDocument.open(pdf.finish())
        try tag(document, PdfNumber(0), "about ZQXMARKER")
        return document
    }

    func test_wordInDescriptionsLinksAndEveryXmpPacketIsReportedAndOnlyReplacedWhenAsked() throws {
        let document = try withWordElsewhere()
        let marks = try RedactionKit.marksOf(document, 0, "ZQXMARKER")
        let kept = try PdfRedactor(document).apply(marks)
        XCTAssertFalse(kept.verification.isClean)
        XCTAssertTrue(kept.report.findings.contains { $0.where == RedactionText.textElsewhere && !$0.changed })
        XCTAssertTrue(kept.report.findings.contains { $0.where.contains("XMP") && !$0.changed })
        XCTAssertTrue(RedactionKit.holds(kept.bytes, "example.com/ZQXMARKER"))
        // The packet of a form is private data of the page and goes with it; the catalog's is the file's own.
        XCTAssertFalse(RedactionKit.holds(kept.bytes, "in a form"))
        XCTAssertTrue(RedactionKit.holds(kept.bytes, "in the catalog"))

        var options = RedactionOptions()
        options.changeMetadata = true
        let changed = try PdfRedactor(document).apply(marks, options)
        _ = try RedactionKit.open(changed)
        XCTAssertFalse(RedactionKit.holds(changed.bytes, "ZQXMARKER"))
        XCTAssertTrue(RedactionKit.holds(changed.bytes, "example.com/[redacted]"))
        XCTAssertTrue(changed.report.findings.contains { $0.where == RedactionText.textElsewhere && $0.changed })
    }

    func test_wordInAnAttachmentIsNamedAsSuch() throws {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R /Extra 4 0 R>>")
        pdf.obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 600 800]>>")
        pdf.obj(3, "<</Type /Page /Parent 2 0 R>>")
        pdf.stream(4, "/Type /EmbeddedFile", "notes about ZQXMARKER")
        let verification = PdfRedactor.verify(pdf.finish(), [], ["ZQXMARKER"])
        XCTAssertEqual(verification.problems.count, 1)
        XCTAssertTrue(verification.problems.first?.contains("attached file") ?? false)
    }
}
