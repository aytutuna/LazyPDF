import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Compare/CompareReviewTests.cs: the same cases. The PdfPig line of
// RemovalFromAPageWithNoWordsLeftIsMarkedWhereItWas (the report opened by a second reader and counted) has no twin; the report
// is still written and read again. The time limit is six times the C# one: a debug build of Swift is slower than .NET's.

final class CompareReviewTests: CompareTestCase {
    private func editWords(_ lines: [String]) -> [String] {
        lines.map { line in
            line.split(separator: " ", omittingEmptySubsequences: false).enumerated()
                .map { $0.offset % 3 == 2 ? "zz\($0.offset)" : String($0.element) }.joined(separator: " ")
        }
    }

    func test_editedPageIsPairedWhenAnotherPageWasInsertedBesideIt() throws {
        let edited = editWords(page("a"))
        let result = try compare([page("a"), page("b")], [page("x"), edited, page("b")])
        XCTAssertEqual(shape(result), "+0 0=1 1=2")
        XCTAssertTrue(result.changes.contains { $0.area == .text && $0.oldPage == 0 && $0.newPage == 1 })
    }

    func test_slidBlockStaysClearOfTheHunkBeforeIt() throws {
        let result = try compare([["alpha beta", "alpha beta gamma delta"]], [["omega beta gamma zeta"]])
        let removed = try single(result.changes, where: { $0.kind == .removed })
        XCTAssertEqual(removed.oldText, "alpha beta")
        assertInRange(try single(removed.oldQuads).bounds.bottom, 700, 725)
        XCTAssertFalse(result.changes.contains { $0.area == .format })
    }

    func test_listBoxSelectionBeyondTheFirstChoiceIsACompare() throws {
        func pick(_ choices: [String]) throws -> PdfDocument {
            let document = try doc([page("form")])
            let form = PdfForm.read(document)
            _ = try form.addField(FieldSpec(.listBox, "colors", 0, PdfRect(100, 400, 200, 460),
                                            options: [FieldOption("A", "A"), FieldOption("B", "B"), FieldOption("C", "C")],
                                            flags: .multiSelect))
            try form.setChoices("colors", choices)
            return try open(document.saveRewrite())
        }
        let before = try pick(["A", "B"])
        let after = try pick(["A", "C"])
        let change = try single(try PdfComparer.compare(before, after).changes)
        XCTAssertEqual(change.area, .document)
        XCTAssertEqual(change.kind, .changed)
        XCTAssertEqual(change.oldText, "A; B")
        XCTAssertEqual(change.newText, "A; C")
    }

    func test_addedPictureAndNoteHaveNoQuadOnTheOldSide() throws {
        let plain = try open(bytes([[CompareLine("Some text")]]))
        let withPicture = try Self.picture("")
        let added = try single(try PdfComparer.compare(plain, withPicture).changes)
        XCTAssertTrue(added.oldQuads.isEmpty)
        _ = try single(added.newQuads)
        let removed = try single(try PdfComparer.compare(withPicture, plain).changes)
        XCTAssertTrue(removed.newQuads.isEmpty)
        _ = try single(removed.oldQuads)
    }

    func test_insertionAfterAHebrewWordIsAnchoredAtItsLeftEdge() throws {
        // Codes 1 to 5 are Hebrew letters; the text is set in visual order, so the first letter of a word is its rightmost glyph.
        func make(_ line: String) throws -> PdfDocument {
            try TextTestPdf.page(TextTestPdf.line(100, 700, line), "", [(1, "א"), (2, "ב"), (3, "ג"), (4, "ד"), (5, "ה")])
        }
        let before = try make(#"\004\003 \002\001"#)
        let after = try make(#"\005 \004\003 \002\001"#)
        let change = try single(try PdfComparer.compare(before, after).changes)
        XCTAssertEqual(change.kind, .added)
        assertInRange(try single(change.oldQuads).bounds.left, 99, 101)
    }

    static func picture(_ imageKeys: String, _ extra: ((TestPdf, Int) -> Void)? = nil) throws -> PdfDocument {
        let file = CompareKit.bytes([[CompareLine("Some text")]], more: { pdf, first in
            pdf.stream(first, "/Type /XObject /Subtype /Image /Width 2 /Height 2 /ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /ASCIIHexDecode " + imageKeys, "00FF00FF>")
            pdf.stream(first + 1, "/Type /XObject /Subtype /Image /Width 2 /Height 2 /ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /ASCIIHexDecode", "FF80FF80>")
            extra?(pdf, first + 2)
        })
        let text = TestPdf.text(file)
            .replacingOccurrences(of: "/Resources <</Font", with: "/Resources <</XObject <</Im0 8 0 R>> /Font")
            .replacingOccurrences(of: "Tj ET\n", with: "Tj ET\nq 80 0 0 60 100 300 cm /Im0 Do Q ")
        return try CompareKit.open(TestPdf.latin(text))
    }

    /// A picture whose tint transform is a stitching function (object `top`) of two others.
    private func tinted(_ top: Int, _ low: Int, _ high: Int, _ c1: String) throws -> PdfDocument {
        try Self.picture("/ColorSpace [/Separation /Spot /DeviceGray \(top) 0 R]", { pdf, _ in
            pdf.obj(top, "<</FunctionType 3 /Domain [0 1] /Functions [\(low) 0 R \(high) 0 R] /Bounds [0.5] /Encode [0 1 0 1]>>")
            pdf.obj(low, "<</FunctionType 2 /Domain [0 1] /C0 [0] /C1 [1] /N 1>>")
            pdf.obj(high, "<</FunctionType 2 /Domain [0 1] /C0 [0] /C1 [\(c1)] /N 1>>")
        })
    }

    func test_colourSpaceIsJudgedByWhatItReferencesNotByObjectNumbers() throws {
        let file = try tinted(10, 11, 12, "1")
        let renumbered = try tinted(12, 10, 11, "1")
        let changed = try tinted(10, 11, 12, "0.5")
        XCTAssertTrue(try PdfComparer.compare(file, renumbered).isIdentical)
        XCTAssertEqual(try single(try PdfComparer.compare(file, changed).changes).detail, CompareText.imageReplaced)
    }

    func test_decodeParametersOnTheSameBytesAreSeen() throws {
        let black = try Self.picture("/Filter /CCITTFaxDecode /DecodeParms <</K -1 /Columns 2 /BlackIs1 true>>")
        let white = try Self.picture("/Filter /CCITTFaxDecode /DecodeParms <</K -1 /Columns 2 /BlackIs1 false>>")
        XCTAssertEqual(try single(try PdfComparer.compare(black, white).changes).detail, CompareText.imageReplaced)
    }

    func test_streamReachedThroughManyReferencesIsReadOnce() throws {
        let zeros = PdfFilterEncoders.flate([UInt8](repeating: 0, count: 8 << 20))
        let row = "[" + String(repeating: "11 0 R ", count: 64) + "]"
        let rows = "[" + String(repeating: row + " ", count: 64) + "]"
        let file = try Self.picture("/ColorSpace \(rows)", { pdf, _ in pdf.stream(11, "/Filter /FlateDecode", zeros) })
        let start = Date()
        _ = try PdfComparer.compare(file, file)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 30, "\(elapsed) s")
    }

    func test_insertionAfterANumberInARightToLeftLineIsAnchoredAtTheNumbersLeftEdge() throws {
        func make(_ line: String) throws -> PdfDocument {
            try TextTestPdf.page(TextTestPdf.line(100, 700, line), "", [(1, "א"), (2, "ב"), (5, "ה")])
        }
        let before = try make(#"12 \002\001"#)
        let after = try make(#"\005 12 \002\001"#)
        let change = try single(try PdfComparer.compare(before, after).changes)
        XCTAssertEqual(change.kind, .added)
        assertInRange(try single(change.oldQuads).bounds.left, 99, 101)
    }

    func test_editedPageIsPairedWhenOneIsInsertedAndOneRemovedBesideIt() throws {
        let result = try compare([page("a"), page("b"), page("c")], [page("x"), editWords(page("a")), editWords(page("b"))])
        XCTAssertEqual(shape(result), "-2 +0 0=1 1=2")
    }

    func test_pagesAppendedAtTheEndDoNotTakeThePartnerOfAnEditedPoorPage() throws {
        let result = try compare([["Title page"]], [["Title pages"], []])
        XCTAssertEqual(shape(result), "0=0 +1")
    }

    func test_softMaskAndDecodeChangesOnTheSameSamplesAreSeen() throws {
        let plain = try Self.picture("")
        let masked = try Self.picture("/SMask 9 0 R")
        let inverted = try Self.picture("/Decode [1 0]")
        XCTAssertEqual(try single(try PdfComparer.compare(plain, masked).changes).detail, CompareText.imageReplaced)
        XCTAssertEqual(try single(try PdfComparer.compare(plain, inverted).changes).detail, CompareText.imageReplaced)
        let again = try Self.picture("/Decode [1 0]")
        XCTAssertTrue(try PdfComparer.compare(inverted, again).isIdentical)
    }

    func test_respelledValuesDoNotMakeAPictureReplaced() throws {
        let hex = try Self.picture("/ColorSpace [/Indexed /DeviceGray 1 <00FF>]")
        let literal = try Self.picture(#"/ColorSpace [/Indexed /DeviceGray 1 (\000\377)]"#)
        XCTAssertTrue(try PdfComparer.compare(hex, literal).isIdentical)
        let whole = try Self.picture("/Decode [1 0]")
        let real = try Self.picture("/Decode [1.0 0.0]")
        XCTAssertTrue(try PdfComparer.compare(whole, real).isIdentical)
    }

    func test_rotationThatKeepsTheSizeIsAPageChange() throws {
        let upright = try open(bytes([[CompareLine("Some text")]]))
        let turned = try open(bytes([[CompareLine("Some text")]], pageKeys: "/Rotate 180"))
        let change = try single(try PdfComparer.compare(upright, turned).changes)
        XCTAssertEqual(change.kind, .changed)
        XCTAssertEqual(change.area, .page)
        XCTAssertTrue(try XCTUnwrap(change.detail).contains("180"))

        let square = try open(bytes([[CompareLine("Some text")]], pageKeys: "/MediaBox [0 0 600 600]"))
        let squareTurned = try open(bytes([[CompareLine("Some text")]], pageKeys: "/MediaBox [0 0 600 600] /Rotate 90"))
        XCTAssertTrue(try PdfComparer.compare(square, squareTurned).changes.contains { $0.area == .page })
    }

    /// A file with two attachments; the tree keys differ but both specifications name the file report.pdf.
    private func reports(_ first: String, _ second: String, undecodable: Bool = false) throws -> PdfDocument {
        let document = try doc([page("files")])
        try PdfAttachments.add(document, "a.txt", Array(first.utf8))
        try PdfAttachments.add(document, "b.txt", Array(second.utf8))
        for attachment in PdfAttachments.list(document) {
            let spec = try XCTUnwrap(document.resolve(attachment.spec) as? PdfDictionary)
            spec["UF"] = PdfText.toObject("report.pdf")
            spec["F"] = PdfText.toObject("report.pdf")
            if undecodable { try XCTUnwrap(PdfAttachments.streamOf(document, attachment)).dictionary["Filter"] = PdfName("NoSuchDecode") }
        }
        return try open(document.saveRewrite())
    }

    func test_secondFileWithTheSameNameIsCompared() throws {
        let before = try reports("one", "two")
        let after = try reports("one", "changed")
        let change = try single(try PdfComparer.compare(before, after).changes)
        XCTAssertEqual(change.area, .document)
        XCTAssertTrue(try XCTUnwrap(change.detail).contains("report.pdf (2)"))
    }

    func test_attachmentThatDoesNotDecodeIsComparedByItsStoredBytes() throws {
        let before = try reports("one", "two", undecodable: true)
        let same = try reports("one", "two", undecodable: true)
        let other = try reports("one", "three", undecodable: true)
        XCTAssertTrue(try PdfComparer.compare(before, same).isIdentical)
        _ = try single(try PdfComparer.compare(before, other).changes)
    }

    func test_removalFromAPageWithNoWordsLeftIsMarkedWhereItWas() throws {
        let a = try doc([["alpha beta gamma"]])
        let b = try doc([[String]()])
        let result = try PdfComparer.compare(a, b)
        let change = try single(result.changes)
        XCTAssertEqual(change.kind, .removed)
        XCTAssertTrue(change.newQuads.isEmpty)
        let bytes = try ComparisonReport.write(b, result, "old.pdf", "new.pdf")
        let report = try PdfDocument.open(bytes)
        let mark = try single(PdfAnnotations.read(report, report.pages[1]), where: { $0.type == .highlight })
        XCTAssertEqual(mark.contents, "Was: alpha beta gamma")
    }
}
