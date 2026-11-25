import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Redaction/RedactMarkerTests.cs: the same cases. One string in every place a file can hold
// text: after the application it is searched for in the raw bytes and in every decoded stream, in plain and in UTF-16 form.

final class RedactMarkerTests: XCTestCase {
    private let pixels = "ZQXPIXELDATA0123"

    private func build() throws -> PdfDocument {
        let document = try RedactionKit.page(
            "BT /F1 12 Tf 100 700 Td (ZQXMARKER in text) Tj ET q 1 0 0 1 100 600 cm /Fm1 Do Q q 64 0 0 64 100 100 cm /Im1 Do Q",
            "/XObject <</Fm1 6 0 R /Im1 7 0 R>>") { pdf in
            pdf.stream(6, "/Type /XObject /Subtype /Form /BBox [0 0 300 50] /Resources <</Font <</F1 5 0 R>>>>", "BT /F1 12 Tf 0 20 Td (ZQXMARKER in a form) Tj ET")
            pdf.stream(7, "/Type /XObject /Subtype /Image /Width 4 /Height 4 /ColorSpace /DeviceGray /BitsPerComponent 8", Latin1.bytes(self.pixels))
        }
        let page = document.pages[0]
        _ = try PdfAnnotationWriter(document).addNote(page, PdfRect(100, 500, 120, 520), AnnotationInfo(author: "ZQXMARKER author", contents: "ZQXMARKER in a note"))
        _ = try PdfForm.read(document).addField(FieldSpec(.text, "f", 0, PdfRect(100, 400, 300, 420), value: "ZQXMARKER in a field"))
        let info = PdfDictionary()
        info["Title"] = PdfText.toObject("About ZQXMARKER")
        info["Author"] = PdfText.toObject("Someone")
        info["Keywords"] = PdfText.toObject("ZQXMARKER T\u{FC}rk\u{E7}e")
        document.trailer["Info"] = try document.add(info)
        let xmp = "<?xpacket begin='' id='W5M0MpCehiHzreSzNTczkc9d'?><x:xmpmeta xmlns:x='adobe:ns:meta/'><rdf:RDF xmlns:rdf='http://www.w3.org/1999/02/22-rdf-syntax-ns#'>"
            + "<rdf:Description xmlns:dc='http://purl.org/dc/elements/1.1/'><dc:title><rdf:Alt><rdf:li xml:lang='x-default'>ZQXMARKER xmp title</rdf:li></rdf:Alt></dc:title></rdf:Description></rdf:RDF></x:xmpmeta><?xpacket end='w'?>"
        let metadata = PdfDictionary()
        metadata["Type"] = PdfName("Metadata")
        metadata["Subtype"] = PdfName("XML")
        document.catalog["Metadata"] = try document.add(PdfStream(metadata, data: Array(xmp.utf8)))
        let outline = Outline.read(document)
        let item = OutlineItem()
        item.title = "Chapter ZQXMARKER"
        item.destination = PdfDestination(0)
        _ = try outline.add(item)
        try outline.write(document)
        return document
    }

    private func everywhere(_ document: PdfDocument) throws -> [RedactionMark] {
        var marks = try RedactionKit.marksOf(document, 0, "ZQXMARKER")
        marks.append(RedactionMark.fromRect(0, PdfRect(90, 490, 130, 530)))
        marks.append(RedactionMark.fromRect(0, PdfRect(90, 390, 310, 430)))
        marks.append(RedactionMark.fromRect(0, PdfRect(100, 100, 164, 164)))
        return marks
    }

    func test_nothingOfTheMarkerIsLeftAnywhereWhenMetadataIsChanged() throws {
        let document = try build()
        XCTAssertTrue(RedactionKit.holds(try document.saveRewrite(), RedactionKit.marker))
        XCTAssertTrue(RedactionKit.holds(try document.saveRewrite(), pixels))
        var options = RedactionOptions()
        options.changeMetadata = true
        let result = try PdfRedactor(document).apply(try everywhere(document), options)
        XCTAssertTrue(result.verification.isClean, result.verification.problems.joined(separator: "; "))
        XCTAssertFalse(RedactionKit.holds(result.bytes, RedactionKit.marker))
        XCTAssertFalse(RedactionKit.holds(result.bytes, pixels))
        let output = try RedactionKit.reopen(result.bytes)
        XCTAssertEqual(RedactionKit.text(output), " in text in a form")
        XCTAssertTrue(result.report.findings.contains { $0.where.contains("XMP") && $0.changed })
        XCTAssertTrue(result.report.findings.contains { $0.where.contains("information") && $0.changed })
        XCTAssertTrue(result.report.findings.contains { $0.where.contains("bookmark") && $0.changed })
        let author = try XCTUnwrap(output.info?["Author"] as? PdfString)
        XCTAssertEqual(PdfText.decode(author.bytes), "Someone")
        XCTAssertTrue(Outline.read(output).items[0].title.contains("Chapter"))
    }

    func test_metadataIsReportedButKeptUnlessAsked() throws {
        let document = try build()
        let result = try PdfRedactor(document).apply(try everywhere(document))
        XCTAssertEqual(result.report.findings.count, 3)
        for f in result.report.findings { XCTAssertFalse(f.changed) }
        XCTAssertFalse(result.verification.isClean)
        XCTAssertTrue(RedactionKit.holds(result.bytes, RedactionKit.marker))
        // The page itself is clean either way.
        let output = try RedactionKit.reopen(result.bytes)
        XCTAssertEqual(RedactionKit.text(output), " in text in a form")
    }

    func test_reportDoesNotRepeatTheTextUnlessAsked() throws {
        let document = try build()
        let plain = try PdfRedactor(document).apply(try everywhere(document))
        XCTAssertFalse(plain.report.description.contains(RedactionKit.marker))
        XCTAssertTrue(plain.report.text.isEmpty)
        var options = RedactionOptions()
        options.includeText = true
        let asked = try PdfRedactor(document).apply(try everywhere(document), options)
        XCTAssertTrue(asked.report.text.contains { $0.contains(RedactionKit.marker) })
        XCTAssertTrue(asked.report.description.contains(RedactionKit.marker))
    }

    func test_theOutputIsAFreshFileWithNoEarlierRevision() throws {
        // A file that was saved by appending twice: the first revision holds the marker text in the clear.
        let original = try build().saveRewrite()
        let session = try PdfEditSession.open(original)
        _ = try PdfAnnotationWriter(session.document).addNote(session.document.pages[0], PdfRect(300, 300, 320, 320), AnnotationInfo(author: "a", contents: "later"))
        _ = try session.commit("note")
        XCTAssertTrue(session.current.count > original.count)
        XCTAssertTrue(Latin1.string(session.current).contains("ZQXMARKER"))
        var options = RedactionOptions()
        options.changeMetadata = true
        let result = try PdfRedactor(session.document).apply(try everywhere(session.document), options)
        XCTAssertEqual(Latin1.string(result.bytes).components(separatedBy: "%%EOF").count - 1, 1)
        XCTAssertFalse(try RedactionKit.everything(result.bytes).contains("ZQXMARKER"))
        let output = try RedactionKit.reopen(result.bytes)
        XCTAssertTrue(output.repairs.isEmpty)
    }

    func test_taggedContentLosesItsDescriptionAndEmptyElements() throws {
        let document = try RedactionKit.page("/P <</MCID 0>> BDC BT /F1 12 Tf 100 700 Td (ZQXMARKER) Tj ET EMC /P <</MCID 1>> BDC BT /F1 12 Tf 100 600 Td (kept) Tj ET EMC")
        let page = document.pages[0]
        page.dictionary["StructParents"] = PdfNumber(0)
        let root = PdfDictionary()
        let docElement = PdfDictionary()
        let first = PdfDictionary()
        let second = PdfDictionary()
        let rootRef = try document.add(root)
        let docRef = try document.add(docElement)
        let firstRef = try document.add(first)
        let secondRef = try document.add(second)
        root["Type"] = PdfName("StructTreeRoot")
        root["K"] = PdfArray([docRef])
        let parents = PdfDictionary()
        parents["Nums"] = PdfArray([PdfNumber(0), PdfArray([firstRef, secondRef])])
        root["ParentTree"] = parents
        docElement["Type"] = PdfName("StructElem")
        docElement["S"] = PdfName("Document")
        docElement["P"] = rootRef
        docElement["K"] = PdfArray([firstRef, secondRef])
        for (element, mcid) in [(first, 0), (second, 1)] {
            element["Type"] = PdfName("StructElem")
            element["S"] = PdfName("P")
            element["P"] = docRef
            element["Pg"] = page.reference
            element["K"] = PdfNumber(mcid)
        }
        first["Alt"] = PdfText.toObject("description of ZQXMARKER")
        document.catalog["StructTreeRoot"] = rootRef
        let result = try PdfRedactor(document).apply(try RedactionKit.marksOf(document, 0, "ZQXMARKER"))
        let output = try RedactionKit.open(result)
        XCTAssertFalse(RedactionKit.holds(result.bytes, "description of"))
        let tree = try XCTUnwrap(output.dict(output.catalog, "StructTreeRoot"))
        let topKids = try XCTUnwrap(output.resolve(tree["K"]) as? PdfArray)
        let top = try XCTUnwrap(output.resolve(topKids.items[0]) as? PdfDictionary)
        let kids = try XCTUnwrap(output.resolve(top["K"]) as? PdfArray)
        XCTAssertEqual(kids.items.count, 1)
        XCTAssertEqual(output.integer(try XCTUnwrap(output.resolve(kids.items[0]) as? PdfDictionary), "K"), 1)
        let nums = PdfNumberTree.read(output, tree["ParentTree"])
        XCTAssertEqual(nums.count, 1)
        let entry = try XCTUnwrap(output.resolve(nums[0].value) as? PdfArray)
        XCTAssertNil(output.resolve(entry.items[0]))
        XCTAssertNotNil(output.resolve(entry.items[1]))
    }
}
