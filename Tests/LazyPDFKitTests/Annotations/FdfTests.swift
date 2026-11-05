import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Annotations/FdfTests.cs: the same cases. The random bytes of GarbageIsRefusedOrSurvived
// come from the port of System.Random(7). StreamsKeepTheirBytesWhateverTheLengthSays also tries a /Length of long.Max, which the C#
// adds to the start of the stream without a check and then reads outside the file.

final class FdfTests: XCTestCase {
    private let day = DateTimeOffset(2026, 3, 1, 9, 0, 0)

    private func later(_ hours: Int) -> DateTimeOffset { DateTimeOffset(2026, 3, 1, 9 + hours, 0, 0) }

    private func commented() throws -> PdfDocument {
        let document = try AnnotationFixtures.blank(2)
        let writer = PdfAnnotationWriter(document)
        let note = try writer.addNote(document.pages[0], PdfRect(50, 100, 70, 120), AnnotationInfo(author: "Ayşe", contents: "başlık: şiir", subject: "Review", date: day))
        try PdfComments.reply(document, note, "yanıt", "Can", later(1))
        try PdfComments.setStatus(document, note, .accepted, "Can", later(2))
        try writer.addTextMarkup(document.pages[1], .highlight, [MarkupQuad.fromRect(PdfRect(50, 700, 150, 714))], info: AnnotationInfo(author: "Ali", contents: "marked", date: day))
        try writer.addStamp(document.pages[1], PdfRect(300, 600, 500, 660), "Approved")
        return document
    }

    private func text(_ d: PdfDictionary, _ key: String) -> String? {
        (d[key] as? PdfString).map { PdfText.decode($0.bytes) }
    }

    func test_exportWriteReadKeepsEveryAnnotationAndItsLinks() throws {
        let source = try commented()
        let fdf = try PdfFdf.export(source, "book.pdf")
        let read = try PdfFdf.read(try PdfFdf.write(fdf))

        XCTAssertEqual(read.fileName, "book.pdf")
        XCTAssertEqual(read.annotations.count, 5)
        XCTAssertEqual(read.annotations.map { $0.pageIndex }.sorted(), [0, 0, 0, 1, 1])
        let notes = read.annotations.filter { text($0.dictionary, "Contents") == "başlık: şiir" }
        XCTAssertEqual(notes.count, 1)
        let note = notes[0]
        XCTAssertEqual(text(note.dictionary, "T"), "Ayşe")
        let replies = read.annotations.filter { $0.dictionary["IRT"] is PdfReference }
        XCTAssertEqual(replies.count, 2)
        for r in replies { XCTAssertTrue(note.dictionary === read.resolve(r.dictionary["IRT"])) }
        let stamps = read.annotations.filter { ($0.dictionary["Subtype"] as? PdfName)?.value == "Stamp" }
        XCTAssertEqual(stamps.count, 1)
        let ap = try XCTUnwrap(stamps[0].dictionary["AP"] as? PdfDictionary)
        XCTAssertTrue(read.resolve(ap["N"]) is PdfStream)
    }

    func test_importRebuildsThemInAnotherDocument() throws {
        let target = try AnnotationFixtures.blank(2)
        let result = try PdfFdf.import(target, try PdfFdf.read(try PdfFdf.write(try PdfFdf.export(try commented()))))
        XCTAssertEqual(result, FdfImportResult(imported: 5, skipped: 0, withoutAppearance: 0))

        let reopened = try AnnotationFixtures.reopen(target)
        XCTAssertEqual(PdfAnnotations.read(reopened, reopened.pages[0]).count, 3)
        XCTAssertEqual(PdfAnnotations.read(reopened, reopened.pages[1]).count, 2)
        let comments = PdfComments.list(reopened)
        let thread = try XCTUnwrap(comments.first { $0.text == "başlık: şiir" })
        XCTAssertEqual(thread.replies.count, 2)
        XCTAssertEqual(thread.status, .accepted)
        for a in PdfAnnotations.readAll(reopened) {
            XCTAssertTrue(a.hasAppearance)
            XCTAssertFalse(a.dictionary.containsKey("Page"))
            XCTAssertNotNil(a.dictionary["P"])
        }
    }

    func test_importingTwiceSkipsWhatIsAlreadyThere() throws {
        let target = try AnnotationFixtures.blank(2)
        let fdf = try PdfFdf.read(try PdfFdf.write(try PdfFdf.export(try commented())))
        try PdfFdf.import(target, fdf)
        let again = try PdfFdf.import(target, fdf)
        XCTAssertEqual(again.imported, 0)
        XCTAssertEqual(again.skipped, 5)
        XCTAssertEqual(PdfAnnotations.readAll(target).count, 5)
    }

    func test_pagesOutsideTheDocumentAreSkippedAndTheirLinksCut() throws {
        let fdf = try PdfFdf.export(try commented())
        let target = try AnnotationFixtures.blank(1)
        let result = try PdfFdf.import(target, fdf)
        XCTAssertEqual(result.imported, 3)
        XCTAssertEqual(result.skipped, 2)
        XCTAssertEqual(PdfAnnotations.readAll(target).count, 3)
        let loose = target.objectNumbers.filter { n in
            guard let d = target.get(n) as? PdfDictionary else { return false }
            return d.containsKey("Subtype") && d.containsKey("Rect")
        }
        XCTAssertEqual(loose.count, 3)
    }

    func test_exportCanBeNarrowedByType() throws {
        let fdf = try PdfFdf.export(try commented(), types: [.highlight])
        XCTAssertEqual(fdf.annotations.count, 1)
        XCTAssertEqual((fdf.annotations[0].dictionary["Subtype"] as? PdfName)?.value, "Highlight")
    }

    func test_annotationWithoutAppearanceGetsOneOnImport() throws {
        let text = "%FDF-1.2\n1 0 obj\n<</FDF<</F (a.pdf) /Annots [2 0 R]>>>>\nendobj\n"
            + "2 0 obj\n<</Subtype /Square /Page 0 /Rect [10 10 90 60] /C [1 0 0] /NM (sq)>>\nendobj\ntrailer\n<</Root 1 0 R>>\n%%EOF"
        let target = try AnnotationFixtures.blank(1)
        let result = try PdfFdf.import(target, try PdfFdf.read(TestPdf.latin(text)))
        XCTAssertEqual(result.imported, 1)
        let list = PdfAnnotations.read(target, target.pages[0])
        XCTAssertEqual(list.count, 1)
        XCTAssertTrue(list[0].hasAppearance)
    }

    func test_readsFieldsWithKidsAndDottedNames() throws {
        let text = "%FDF-1.2\n1 0 obj\n<</FDF<</Fields[<</T (person) /Kids[<</T (name) /V (Ayse)>> <</T (tick) /V /Yes>> <</T (many) /V [(a) (b)]>>]>> <</T (lone) /V <FEFF015F>>>]>>>>\nendobj\ntrailer\n<</Root 1 0 R>>\n"
        let fdf = try PdfFdf.read(TestPdf.latin(text))
        let flat = fdf.flatFields()
        XCTAssertEqual(flat.map { $0.key }, ["person.name", "person.tick", "person.many", "lone"])
        XCTAssertEqual(PdfText.decode(try XCTUnwrap(flat[0].value as? PdfString).bytes), "Ayse")
        XCTAssertEqual((flat[1].value as? PdfName)?.value, "Yes")
        XCTAssertEqual((flat[2].value as? PdfArray)?.items.count, 2)
        XCTAssertEqual(PdfText.decode(try XCTUnwrap(flat[3].value as? PdfString).bytes), "ş")
        XCTAssertTrue(fdf.annotations.isEmpty)
    }

    func test_fieldsRoundTripThroughWrite() throws {
        let fdf = FdfFile()
        fdf.fileName = "form.pdf"
        fdf.fields.append(FdfField("a", PdfText.toObject("one"), []))
        fdf.fields.append(FdfField("group", nil, [FdfField("b", PdfName("Off"), [])]))
        let bytes = try PdfFdf.write(fdf)
        let read = try PdfFdf.read(bytes)
        XCTAssertEqual(read.flatFields().map { $0.key }, ["a", "group.b"])
        XCTAssertTrue(Latin1.string(try PdfFdf.write(fdf)).hasPrefix("%FDF-1.2"))
    }

    func test_streamsKeepTheirBytesWhateverTheLengthSays() throws {
        let payload = (0..<300).map { UInt8($0 & 255) }
        for length in ["300", "5", "999999", "9223372036854775807", ""] {
            let head = TestPdf.latin("%FDF-1.2\n1 0 obj\n<</FDF<</Annots[2 0 R]>>>>\nendobj\n2 0 obj\n<</Subtype /Stamp /Page 0 /Rect [0 0 9 9] /AP <</N 3 0 R>>>>\nendobj\n3 0 obj\n<</Type /XObject /Subtype /Form /BBox [0 0 9 9] \(length.isEmpty ? "" : "/Length " + length)>>\nstream\n")
            let file = head + payload + TestPdf.latin("\nendstream\nendobj\ntrailer\n<</Root 1 0 R>>\n%%EOF")
            let fdf = try PdfFdf.read(file)
            let ap = try XCTUnwrap(fdf.annotations[0].dictionary["AP"] as? PdfDictionary)
            let stream = try XCTUnwrap(fdf.resolve(ap["N"]) as? PdfStream)
            XCTAssertEqual(stream.data, payload, "length \(length)")
        }
    }

    func test_garbageIsRefusedOrSurvived() throws {
        for file in [TestPdf.latin("hello"), [], TestPdf.simple(1)] {
            XCTAssertThrowsError(try PdfFdf.read(file)) { XCTAssertTrue($0 is PdfReadException) }
        }
        var random = DotNetRandom(7)
        let valid = try PdfFdf.write(try PdfFdf.export(try commented()))
        for _ in 0..<40 {
            var broken = valid
            for _ in 0..<20 { broken[random.next(broken.count)] = UInt8(random.next(256)) }
            do {
                let fdf = try PdfFdf.read(broken)
                try PdfFdf.import(try AnnotationFixtures.blank(2), fdf)
            } catch is PdfReadException {
            }
        }
    }

    func test_anObjectNumberAtTheLimitDoesNotWrap() {
        let fdf = FdfFile()
        fdf.add(Int(Int32.max), PdfDictionary())
        XCTAssertThrowsError(try fdf.reserve()) { XCTAssertTrue($0 is PdfReadException) }
        XCTAssertThrowsError(try PdfFdf.write(fdf)) { XCTAssertTrue($0 is PdfReadException) }
    }

    func test_theFileOnlyHoldsWhatTheAnnotationsReach() throws {
        let fdf = try PdfFdf.export(try commented())
        let text = Latin1.string(try PdfFdf.write(fdf))
        XCTAssertFalse(text.contains("/Pages"))
        XCTAssertFalse(text.contains("/Kids"))
        XCTAssertFalse(text.contains("/Parent 2 0 R"))
    }

    func test_writingAFileThatWasReadKeepsOneCatalog() throws {
        let first = try PdfFdf.write(try PdfFdf.export(try commented()))
        let second = try PdfFdf.write(try PdfFdf.read(first))
        XCTAssertEqual(Latin1.string(second).components(separatedBy: "/FDF").count - 1, 1)
        XCTAssertEqual(try PdfFdf.read(first).annotations.count, try PdfFdf.read(second).annotations.count)
    }
}
