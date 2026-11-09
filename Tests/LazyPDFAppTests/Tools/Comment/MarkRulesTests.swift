import XCTest
@testable import LazyPDFKit
@testable import LazyPDFApp

// Mirrors windows/LazyPDF.App.Tests/Tools/comment/MarkRulesTests.cs: marks on turned pages, which marks may be touched, what a
// restyle keeps, and what the file allows.

@MainActor
final class MarkRulesTests: XCTestCase {
    private func turned(_ degrees: Int) throws -> CommentFixture {
        let f = try CommentFixture()
        f.document.pages[0].dictionary["Rotate"] = PdfNumber(degrees)
        return f
    }

    func test_aStampOnATurnedPageStaysUprightAtItsNaturalSize() throws {
        for degrees in [90, 180, 270] {
            let f = try turned(degrees)

            let stamp = try f.marker.addStamp(0, pt(200, 300), "Approved", .default)

            XCTAssertTrue(stamp.flags.contains(.noRotate))
            XCTAssertEqual(stamp.rect.width, Marker.stampWidth, accuracy: 0.5)
            XCTAssertEqual(stamp.rect.height, Marker.stampHeight, accuracy: 0.5)
            let box = f.marker.box(of: stamp)
            XCTAssertEqual(box.x, 200 - Marker.stampWidth / 2, accuracy: 0.5)
            XCTAssertEqual(box.y, 300 - Marker.stampHeight / 2, accuracy: 0.5)
            XCTAssertEqual(box.width, Marker.stampWidth, accuracy: 0.5)
            XCTAssertEqual(box.height, Marker.stampHeight, accuracy: 0.5)
        }
    }

    func test_aStampOnAnUpPageIsNotMarkedToStayUpright() throws {
        let f = try CommentFixture()

        let stamp = try f.marker.addStamp(0, pt(200, 300), "Approved", .default)

        XCTAssertFalse(stamp.flags.contains(.noRotate))
    }

    func test_aTextBoxOnATurnedPageKeepsTheSizeItWasDrawnAt() throws {
        for degrees in [90, 270] {
            let f = try turned(degrees)

            let made = try f.marker.add(.textBox, 0, [pt(60, 80), pt(260, 140)], red, "Hello")

            XCTAssertTrue(made.flags.contains(.noRotate))
            let box = f.marker.box(of: made)
            XCTAssertEqual(box.x, 60, accuracy: 0.5)
            XCTAssertEqual(box.y, 80, accuracy: 0.5)
            XCTAssertEqual(box.width, 200, accuracy: 0.5)
            XCTAssertEqual(box.height, 60, accuracy: 0.5)
        }
    }

    func test_resizingAnUprightMarkGivesTheNewBoxBack() throws {
        let f = try turned(90)
        let stamp = try f.marker.addStamp(0, pt(200, 300), "Approved", .default)

        let resized = try f.marker.resize(stamp, ViewRect(100, 150, 220, 70))

        let box = f.marker.box(of: resized)
        XCTAssertEqual(box.x, 100, accuracy: 0.5)
        XCTAssertEqual(box.y, 150, accuracy: 0.5)
        XCTAssertEqual(box.width, 220, accuracy: 0.5)
        XCTAssertEqual(box.height, 70, accuracy: 0.5)
    }

    func test_aCalloutOnATurnedPageIsABoxWithAnArrowToTheSpot() throws {
        let f = try turned(90)

        let made = try f.marker.add(.callout, 0, [pt(100, 100), pt(300, 200)], red, "See the chart")

        XCTAssertEqual(made.type, .freeText)
        XCTAssertTrue(made.flags.contains(.noRotate))
        XCTAssertTrue(f.marks().contains { $0.type == .line })
    }

    func test_resizingACalloutKeepsItsTextBoxInsideItsRectangle() throws {
        let f = try CommentFixture()
        let made = try f.marker.add(.callout, 0, [pt(40, 100), pt(380, 200)], red, "See the chart")
        let box = f.marker.box(of: made)

        let resized = try f.marker.resize(made, ViewRect(box.x, box.y, box.width / 2, box.height))

        let inset = resized.rectDifference
        XCTAssertEqual(inset.count, 4)
        XCTAssertLessThan(inset[0] + inset[2], resized.rect.width)
        XCTAssertLessThan(inset[1] + inset[3], resized.rect.height)
        XCTAssertEqual(inset[0], made.rectDifference[0] / 2, accuracy: 0.5)
    }

    func test_opacityAppliesToStampsAndNotesWhenTheyArePlaced() throws {
        let f = try CommentFixture()
        let faint = MarkStyle(color: [0.9, 0.1, 0.1], opacity: 0.4)

        let stamp = try f.marker.addStamp(0, pt(200, 300), "Approved", faint)
        let note = try f.marker.add(.note, 0, [pt(100, 100)], faint, "Check")

        XCTAssertEqual(stamp.opacity, 0.4, accuracy: 0.001)
        XCTAssertEqual(note.opacity, 0.4, accuracy: 0.001)
    }

    func test_aMarkTheFileLocksCannotBePickedOrErased() throws {
        for flag in [AnnotationFlags.locked, .readOnly] {
            let f = try CommentFixture()
            let stamp = try f.marker.addStamp(0, pt(200, 300), "Approved", .default)
            stamp.dictionary["F"] = PdfNumber(AnnotationFlags([.print, flag]).rawValue)

            XCTAssertNil(f.marker.at(0, pt(200, 300), 4))
            XCTAssertTrue(f.marker.along(0, [pt(100, 300), pt(300, 300)], 4).isEmpty)
        }
    }

    func test_aHollowRectangleLeavesTheMarkInsideItReachable() throws {
        let f = try CommentFixture()
        let quad = TextQuad(100, 700, 180, 700, 180, 712, 100, 712)
        _ = try f.marker.markup(.highlight, [SelectedRun(page: 0, range: TextRange(0, 0), text: "Hello", quads: [quad])], .default)
        let (_, top) = f.geometry.toDisplay(0, 706)
        try f.marker.add(.rectangle, 0, [pt(60, top - 40), pt(300, top + 40)], red)

        XCTAssertEqual(f.marker.at(0, pt(140, top), 4)?.type, .highlight)
        XCTAssertEqual(f.marker.at(0, pt(60, top), 4)?.type, .square)
    }

    func test_aHollowOvalIsFoundOnItsOutlineOnly() throws {
        let f = try CommentFixture()
        try f.marker.add(.oval, 0, [pt(100, 100), pt(300, 200)], red)

        XCTAssertNotNil(f.marker.at(0, pt(200, 100), 4))
        XCTAssertNotNil(f.marker.at(0, pt(100, 150), 4))
        XCTAssertNil(f.marker.at(0, pt(200, 150), 4))
    }

    func test_aFastStrokeStillCrossesAThinLineBetweenItsSamples() throws {
        let f = try CommentFixture()
        try f.marker.add(.line, 0, [pt(200, 50), pt(200, 250)], red)

        let hit = f.marker.along(0, [pt(100, 150), pt(300, 150)], 4)

        XCTAssertEqual(hit.count, 1)
        XCTAssertTrue(f.marker.along(0, [pt(100, 150), pt(150, 150)], 4).isEmpty)
    }

    func test_erasingInsideAHollowRectangleLeavesTheRectangle() throws {
        let f = try CommentFixture()
        try f.marker.add(.rectangle, 0, [pt(50, 50), pt(350, 250)], red)
        try f.marker.add(.pencil, 0, [pt(100, 100), pt(200, 100), pt(200, 200)], red)

        let hit = f.marker.along(0, [pt(150, 80), pt(150, 120)], 4)

        XCTAssertEqual(hit.map(\.type), [.ink])
    }

    func test_aTextBoxIsReadBackAsTheFontItWasSetIn() throws {
        let f = try CommentFixture()
        let look = MarkStyle(color: [0.9, 0.1, 0.1], family: "Times New Roman", size: 18, font: [.bold, .italic])

        let made = try f.marker.add(.textBox, 0, [pt(60, 80), pt(260, 140)], look, "Hello")

        let text = Marker.textOf(made)
        XCTAssertEqual(text.family, "Times New Roman")
        XCTAssertEqual(text.size, 18)
        XCTAssertEqual(text.font, [.bold, .italic])
        XCTAssertEqual(text.textColor, [0.9, 0.1, 0.1])
    }

    func test_changingTheFontOfATextBoxKeepsItsColourAndAlignment() throws {
        let f = try CommentFixture()
        let made = try f.marker.add(.textBox, 0, [pt(60, 80), pt(260, 140)], red, "Hello")

        var look = red
        look.family = "Courier New"
        look.size = 10
        look.font = .regular
        let changed = try f.marker.restyle(made, look)

        let text = Marker.textOf(changed)
        XCTAssertEqual(text.family, "Courier New")
        XCTAssertEqual(text.size, 10)
        XCTAssertEqual(text.textColor, [0.9, 0.1, 0.1])
        XCTAssertEqual(changed.alignment, made.alignment)
    }

    func test_colouringATextBoxPaintsTheFrameAndTheText() throws {
        let f = try CommentFixture()
        var look = red
        look.family = "Times New Roman"
        look.size = 16
        let made = try f.marker.add(.textBox, 0, [pt(60, 80), pt(260, 140)], look, "Hello")

        let blue = try f.marker.recolor(made, [0, 0, 1])

        XCTAssertEqual(blue.color, [0, 0, 1])
        let text = Marker.textOf(blue)
        XCTAssertEqual(text.textColor, [0, 0, 1])
        XCTAssertEqual(text.family, "Times New Roman")
        XCTAssertEqual(text.size, 16)
    }

    func test_aColourOfAnyKindIsShownAsRgb() {
        XCTAssertEqual(Marker.rgb(of: [0.5]), [0.5, 0.5, 0.5])
        XCTAssertEqual(Marker.rgb(of: [1, 0, 0]), [1, 0, 0])
        XCTAssertEqual(Marker.rgb(of: [0, 0, 0, 1]), [0, 0, 0])
    }

    func test_noColourAndTransparentHaveNoRgb() {
        XCTAssertNil(Marker.rgb(of: nil))
        XCTAssertNil(Marker.rgb(of: []))
    }

    private func certify(_ document: PdfDocument, _ level: Int?) throws {
        let signature = PdfDictionary()
        signature["Type"] = PdfName("Sig")
        if let level {
            let parameters = PdfDictionary()
            parameters["P"] = PdfNumber(level)
            let reference = PdfDictionary()
            reference["TransformMethod"] = PdfName("DocMDP")
            reference["TransformParams"] = parameters
            signature["Reference"] = PdfArray([reference])
        }
        let perms = PdfDictionary()
        perms["DocMDP"] = try document.add(signature)
        document.catalog["Perms"] = perms
    }

    func test_aFileThatIsNotCertifiedTakesComments() throws {
        let f = try CommentFixture()

        XCTAssertTrue(Exchange.canComment(f.document))
    }

    func test_aCertificationSetsWhetherCommentsMayBeAdded() throws {
        let cases: [(Int?, Bool)] = [(1, false), (2, false), (3, true), (nil, false)]
        for (level, allowed) in cases {
            let f = try CommentFixture()
            try certify(f.document, level)

            XCTAssertTrue(f.document.isCertified)
            XCTAssertEqual(Exchange.canComment(f.document), allowed, "level \(String(describing: level))")
        }
    }

    func test_aFileWithoutTheAnnotateRightRefusesComments() throws {
        let session = try PdfEditSession.open(Pdfs.restricted(.print), password: "")
        let tab = DocumentTab(session: session, renderer: FakeRenderer(), url: nil, title: "locked.pdf")

        XCTAssertFalse(Exchange.canComment(tab.document))
    }

    func test_exportingAFileWithNoCommentsCountsNone() throws {
        let f = try CommentFixture()

        XCTAssertEqual(try Exchange.export(f.document, "a.pdf", xfdf: false).count, 0)
    }

    func test_xfdfCountsWhatItCannotHold() throws {
        let f = try CommentFixture()
        try f.marker.add(.rectangle, 0, [pt(60, 80), pt(260, 140)], red)
        _ = try f.marker.addAttachment(0, pt(300, 100), "data.csv", [1, 2, 3])
        try f.tab.commit("Marks")

        let xfdf = try Exchange.export(f.document, "a.pdf", xfdf: true)
        let fdf = try Exchange.export(f.document, "a.pdf", xfdf: false)

        XCTAssertEqual(xfdf.count, 2)
        XCTAssertEqual(xfdf.left, 1)
        XCTAssertEqual(fdf.left, 0)
    }

    func test_importingTwiceReportsTheCopiesAsSkipped() throws {
        let source = try CommentFixture()
        try source.marker.add(.rectangle, 0, [pt(60, 80), pt(260, 140)], red)
        try source.tab.commit("Marks")
        let target = try CommentFixture()
        let data = try Exchange.export(source.document, nil, xfdf: false).data
        _ = try Exchange.import(target.document, data, xfdf: false, FakeFonts())
        try target.tab.commit("Import comments")

        let again = try Exchange.import(target.document, data, xfdf: false, FakeFonts())

        XCTAssertEqual(again.imported, 0)
        XCTAssertGreaterThan(again.skipped, 0)
    }

    func test_flatteningStopsBetweenPagesWhenCancelled() throws {
        let f = try CommentFixture(pages: 3)
        for page in 0..<3 { try f.marker.add(.rectangle, page, [pt(60, 80), pt(260, 140)], red) }
        let stop = CancelToken()
        stop.cancel()

        XCTAssertThrowsError(try Exchange.flatten(f.document, stop)) { XCTAssertTrue($0 is CancellationError) }
    }

    func test_aDiscardedFlattenLeavesTheFileAsItWas() throws {
        let f = try CommentFixture()
        try f.marker.add(.rectangle, 0, [pt(60, 80), pt(260, 140)], red)
        try f.tab.commit("Marks")

        XCTAssertEqual(try Exchange.flatten(f.document, CancelToken()), 1)
        try f.tab.session.discard()

        XCTAssertEqual(f.marks().count, 1)
        XCTAssertFalse(f.tab.session.isDirty && f.document.hasChanges)
    }
}
