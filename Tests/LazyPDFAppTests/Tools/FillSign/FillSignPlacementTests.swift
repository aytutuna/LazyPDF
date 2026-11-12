import XCTest
import LazyPDFKit
@testable import LazyPDFApp

// Mirrors windows/LazyPDF.App.Tests/Tools/sign/FillSignPlacementTests.cs: where a signature or a line of text lands on the page,
// and that the placing is one undoable step. The Windows test of the signed-file caution signs with a certificate; the file here
// says it is signed through its permissions entry, which is what the caution reads.

@MainActor
final class FillSignPlacementTests: XCTestCase {
    private let page = ViewSize(612, 792)
    private let ink = PdfRgbaImage(2, 1, [0, 0, 0, 255, 0, 0, 0, 255])
    private let now = DateTimeOffset(2026, 11, 8, 10, 0, 0, offsetMinutes: 0)

    private func newTab() throws -> DocumentTab {
        DocumentTab(session: try PdfEditSession.open(Pdfs.text()), renderer: FakeRenderer(), url: nil, title: "a.pdf")
    }

    private func pageHeight(_ tab: DocumentTab) -> Double {
        PageGeometry(tab.document.pages[0]).height
    }

    func test_aClickCentresTheBox() async {
        let box = FillSignPlacement.around(ViewPoint(300, 400), 150, 3, page)

        XCTAssertEqual(box, DisplayRect(225, 375, 150, 50))
    }

    func test_aClickAtTheEdgeKeepsTheBoxOnThePage() async {
        let box = FillSignPlacement.around(ViewPoint(5, 790), 150, 3, page)

        XCTAssertEqual(box.x, 0)
        XCTAssertEqual(box.y, 742)
    }

    func test_aDragKeepsTheProportionsOfThePicture() async {
        let box = FillSignPlacement.fromDrag(ViewPoint(100, 100), ViewPoint(400, 150), 3, page)

        XCTAssertEqual(box, DisplayRect(100, 100, 150, 50))
    }

    func test_aDragUpAndToTheLeftFillsTheSameCorner() async {
        let box = FillSignPlacement.fromDrag(ViewPoint(400, 300), ViewPoint(300, 100), 2, page)

        XCTAssertEqual(box.width, 100)
        XCTAssertEqual(box.height, 50)
        XCTAssertEqual(box.x, 300)
        XCTAssertEqual(box.y, 250)
    }

    func test_aSignatureIsAStampAtTheBoxInPageSpace() async throws {
        let tab = try newTab()

        XCTAssertTrue(try FillSignPlacement.placeImage(tab, 0, DisplayRect(100, 100, 150, 50), ink, now))

        let stamp = try XCTUnwrap(PdfAnnotations.readAll(tab.document).first)
        XCTAssertEqual(PdfAnnotations.readAll(tab.document).count, 1)
        XCTAssertEqual(stamp.type, .stamp)
        XCTAssertEqual(stamp.rect.left, 100, accuracy: 0.001)
        XCTAssertEqual(stamp.rect.bottom, pageHeight(tab) - 150, accuracy: 0.001)
        XCTAssertEqual(stamp.rect.width, 150, accuracy: 0.001)
    }

    func test_placingASignatureCanBeUndone() async throws {
        let tab = try newTab()
        try FillSignPlacement.placeImage(tab, 0, DisplayRect(10, 10, 60, 20), ink, now)

        XCTAssertTrue(try tab.undo())

        XCTAssertTrue(PdfAnnotations.readAll(tab.document).isEmpty)
        XCTAssertEqual(tab.session.redoLabel, "Place signature")
    }

    func test_textIsFreeTextWithItsWordsAtTheClick() async throws {
        let tab = try newTab()

        XCTAssertTrue(try FillSignPlacement.placeText(tab, FakeFonts(), 0, ViewPoint(72, 200), "Approved", 12, now))

        let notes = PdfAnnotations.readAll(tab.document)
        XCTAssertEqual(notes.count, 1)
        let note = try XCTUnwrap(notes.first)
        XCTAssertEqual(note.type, .freeText)
        XCTAssertEqual(note.contents, "Approved")
        XCTAssertEqual(note.rect.left, 72, accuracy: 0.001)
        XCTAssertTrue(note.rect.top < pageHeight(tab) - 190 && note.rect.bottom > pageHeight(tab) - 215)
        XCTAssertEqual(tab.session.undoLabel, "Place text")
    }

    func test_textTheFontsCannotDrawChangesNothing() async throws {
        let tab = try newTab()

        XCTAssertThrowsError(try FillSignPlacement.placeText(tab, FakeFonts(), 0, ViewPoint(72, 200), "\u{00C7}a\u{011F}r\u{0131}", 12, now)) {
            XCTAssertTrue($0 is InvalidOperationException, "\($0)")
        }

        XCTAssertFalse(tab.isDirty)
    }

    private func turned(_ degrees: Int) throws -> DocumentTab {
        let tab = try newTab()
        PageOperations.rotate(tab.document, [0], degrees)
        try tab.commit("Rotate")
        return tab
    }

    private func appearance(_ tab: DocumentTab, _ annotation: PdfAnnotation) throws -> PdfStream {
        let ap = try XCTUnwrap(tab.document.dict(annotation.dictionary, "AP"))
        return try XCTUnwrap(tab.document.resolve(ap["N"]) as? PdfStream)
    }

    func test_aSignatureOnATurnedPageIsDrawnUprightAndTurnedBack() async throws {
        let cases: [(Int, [Int])] = [(90, [0, 1, -1, 0]), (180, [-1, 0, 0, -1]), (270, [0, -1, 1, 0])]
        for (degrees, matrix) in cases {
            let tab = try turned(degrees)

            try FillSignPlacement.placeImage(tab, 0, DisplayRect(100, 100, 150, 50), ink, now)

            let stamp = try XCTUnwrap(PdfAnnotations.readAll(tab.document).first)
            let sideways = degrees != 180
            XCTAssertEqual(stamp.rect.width, sideways ? 50 : 150, accuracy: 0.001, "\(degrees)")
            XCTAssertEqual(stamp.rect.height, sideways ? 150 : 50, accuracy: 0.001, "\(degrees)")
            let form = try appearance(tab, stamp)
            XCTAssertEqual(tab.document.rect(form.dictionary, "BBox"), PdfRect(0, 0, 150, 50), "\(degrees)")
            let turn = try XCTUnwrap(tab.document.array(form.dictionary, "Matrix")).items.prefix(4).map { Int(($0 as? PdfNumber)?.value ?? 99) }
            XCTAssertEqual(turn, matrix, "\(degrees)")
        }
    }

    func test_aSignatureOnAnUprightPageIsNotTurned() async throws {
        let tab = try newTab()
        try FillSignPlacement.placeImage(tab, 0, DisplayRect(100, 100, 150, 50), ink, now)

        let stamp = try XCTUnwrap(PdfAnnotations.readAll(tab.document).first)

        XCTAssertEqual(stamp.rect.width, 150, accuracy: 0.001)
        XCTAssertEqual(stamp.rect.height, 50, accuracy: 0.001)
        let matrix = tab.document.array(try appearance(tab, stamp).dictionary, "Matrix")?.items.map { Int(($0 as? PdfNumber)?.value ?? 99) }
        XCTAssertTrue(matrix == nil || matrix! == [1, 0, 0, 1, 0, 0])
    }

    func test_textOnATurnedPageHasRoomForItsLines() async throws {
        let tab = try turned(90)

        try FillSignPlacement.placeText(tab, FakeFonts(), 0, ViewPoint(72, 200), "4 November 2026", 12, now)

        let note = try XCTUnwrap(PdfAnnotations.readAll(tab.document).first)
        let form = try appearance(tab, note)
        let shown = try XCTUnwrap(tab.document.rect(form.dictionary, "BBox"))
        XCTAssertTrue(shown.width > shown.height)
        XCTAssertEqual(shown.width, note.rect.height, accuracy: 0.001)
        XCTAssertEqual(shown.height, note.rect.width, accuracy: 0.001)
        XCTAssertNotNil(form.dictionary["Matrix"])
    }

    func test_aSignedFileIsCautionedAndAPlainOneIsNot() async throws {
        let signed = try PdfDocument.open(Pdfs.signed(certified: false))
        let plain = try PdfDocument.open(Pdfs.text())

        XCTAssertNotNil(FillSignPlacement.caution(signed))
        XCTAssertNil(FillSignPlacement.caution(plain))
    }

    func test_aFileThatForbidsCommentsRefusesStampsAndText() async throws {
        let locked = try PdfDocument.open(Pdfs.restricted(.print), password: "")
        let owner = try PdfDocument.open(Pdfs.restricted(.print), password: "owner")

        XCTAssertNotNil(FillSignPlacement.refusal(locked))
        XCTAssertNil(FillSignPlacement.refusal(owner))
        XCTAssertNil(FillSignPlacement.refusal(try PdfDocument.open(Pdfs.text())))
    }

    func test_theTextIsMeasuredWithHelveticaAndGrowsWithItsLines() async {
        let one = FillSignPlacement.measure("Approved", 12)
        let two = FillSignPlacement.measure("Approved\nApproved", 12)

        XCTAssertGreaterThan(one.width, 40)
        XCTAssertEqual(one.width, two.width)
        XCTAssertGreaterThan(two.height, one.height)
    }

    func test_turkishLettersAreMeasuredByTheirBaseLetter() async {
        XCTAssertEqual(FillSignPlacement.measure("şŞğĞİ", 12).width, FillSignPlacement.measure("sSgGI", 12).width)
        XCTAssertEqual(FillSignPlacement.measure("ı", 12).width, FillSignPlacement.measure("i", 12).width)
        XCTAssertEqual(FillSignPlacement.measure("abc", 12).width, 28)
    }
}
