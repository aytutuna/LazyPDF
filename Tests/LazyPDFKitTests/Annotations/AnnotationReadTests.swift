import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Annotations/AnnotationReadTests.cs: the same cases.

final class AnnotationReadTests: XCTestCase {
    private let everything =
        "<</Type /Annot /Subtype /FreeText /Rect [300 400 100 200] /Contents (caf\\351) /T <FEFF00410079015F0065> /Subj (Subject) /NM (id-1)"
        + " /CreationDate (D:20260102030405+03'00') /M (D:20260102030405Z) /F 28 /C [1 0 0] /IC [0.5] /CA 0.5"
        + " /BS <</W 3 /S /D /D [4 2]>> /IRT 21 0 R /RT /Group /StateModel (Review) /State (Accepted)"
        + " /QuadPoints [1 2 3 4 5 6 7 8] /InkList [[1 2 3 4] [5 6]] /Vertices [1 2 3 4 5 6] /L [1 2 3 4] /LE [/Circle /ClosedArrow]"
        + " /CL [1 2 3 4] /IT /FreeTextCallout /RD [1 2 3 4] /BE <</S /C /I 2>> /DA (/Helv 12 Tf 0 g) /DS (font: Arial 12pt)"
        + " /RC (<body/>) /Q 2 /Name /Comment /Popup 22 0 R /AP <</N 23 0 R>> /Extra (unknown)>>"

    private func one(_ body: String) throws -> PdfAnnotation {
        let document = try AnnotationFixtures.blank(1, { $0.obj(20, body) }, pageEntries: "/Annots [20 0 R]")
        let list = PdfAnnotations.read(document, document.pages[0])
        XCTAssertEqual(list.count, 1)
        return try XCTUnwrap(list.first)
    }

    func test_readsEveryKey() throws {
        let a = try one(everything)
        XCTAssertEqual(a.subtype, "FreeText")
        XCTAssertEqual(a.type, .freeText)
        XCTAssertEqual(a.rect, PdfRect(100, 200, 300, 400))
        XCTAssertEqual(a.contents, "café")
        XCTAssertEqual(a.title, "Ayşe")
        XCTAssertEqual(a.subject, "Subject")
        XCTAssertEqual(a.name, "id-1")
        XCTAssertEqual(a.created, DateTimeOffset(2026, 1, 2, 3, 4, 5, offsetMinutes: 180))
        XCTAssertEqual(a.modified, DateTimeOffset(2026, 1, 2, 3, 4, 5))
        XCTAssertEqual(a.flags, [.print, .noZoom, .noRotate])
        XCTAssertEqual(a.color, [1, 0, 0])
        XCTAssertEqual(a.interiorColor, [0.5])
        XCTAssertEqual(a.opacity, 0.5)
        XCTAssertEqual(a.border.style, .dashed)
        XCTAssertEqual(a.border.dash, [4, 2])
        XCTAssertEqual(a.inReplyTo?.number, 21)
        XCTAssertEqual(a.replyType, "Group")
        XCTAssertEqual(a.state, .accepted)
        XCTAssertEqual(a.quadPoints.count, 8)
        XCTAssertEqual(a.inkList.count, 2)
        XCTAssertEqual(a.inkList[1], [5, 6])
        XCTAssertEqual(a.vertices.count, 6)
        XCTAssertEqual(a.line, [1, 2, 3, 4])
        XCTAssertEqual(a.startEnding, .circle)
        XCTAssertEqual(a.endEnding, .closedArrow)
        XCTAssertEqual(a.callout.count, 4)
        XCTAssertEqual(a.intent, "FreeTextCallout")
        XCTAssertEqual(a.rectDifference, [1, 2, 3, 4])
        XCTAssertEqual(a.cloud, 2)
        XCTAssertEqual(a.defaultAppearance, "/Helv 12 Tf 0 g")
        XCTAssertEqual(a.defaultStyle, "font: Arial 12pt")
        XCTAssertEqual(a.richText, "<body/>")
        XCTAssertEqual(a.alignment, 2)
        XCTAssertEqual(a.iconName, "Comment")
        XCTAssertEqual(a.popup?.number, 22)
        XCTAssertTrue(a.hasAppearance)
        XCTAssertEqual(a.reference?.number, 20)
        XCTAssertTrue(a.dictionary.containsKey("Extra"))
    }

    func test_readsTheOlderBorderArrayAndASingleEnding() throws {
        let a = try one("<</Subtype /Line /Rect [0 0 10 10] /Border [0 0 2 [3 1]] /LE /OpenArrow /L [0 0 10 10]>>")
        XCTAssertEqual(a.border.width, 2)
        XCTAssertEqual(a.border.style, .dashed)
        XCTAssertEqual(a.border.dash, [3, 1])
        XCTAssertEqual(a.startEnding, .openArrow)
        XCTAssertEqual(a.endEnding, LineEnding.none)
        let plain = try one("<</Subtype /Square /Rect [0 0 10 10]>>")
        XCTAssertEqual(plain.border.width, AnnotationBorder(1, .solid, []).width)
        XCTAssertNil(plain.color)
        XCTAssertEqual(plain.opacity, 1)
    }

    func test_wrongTypesFallBackToDefaults() throws {
        let a = try one("<</Subtype /Highlight /Rect [1 2] /C [1 2] /CA (x) /F /name /QuadPoints (no) /BS 5 /LE 7 /IRT 3 /Contents 12 /M (junk) /State (Bogus) /Popup (x) /InkList 9>>")
        XCTAssertEqual(a.rect, PdfRect(0, 0, 0, 0))
        XCTAssertNil(a.color)
        XCTAssertEqual(a.opacity, 1)
        XCTAssertEqual(a.flags, AnnotationFlags.none)
        XCTAssertTrue(a.quadPoints.isEmpty)
        XCTAssertEqual(a.startEnding, LineEnding.none)
        XCTAssertNil(a.inReplyTo)
        XCTAssertNil(a.contents)
        XCTAssertNil(a.modified)
        XCTAssertNil(a.state)
        XCTAssertNil(a.popup)
        XCTAssertTrue(a.inkList.isEmpty)
        XCTAssertFalse(a.hasAppearance)
    }

    func test_junkInTheArrayIsSkipped() throws {
        let document = try AnnotationFixtures.blank(1, { pdf in
            pdf.obj(20, "<</Subtype /Text /Rect [0 0 5 5]>>")
            pdf.obj(21, "<</Rect [0 0 5 5]>>")
            pdf.obj(22, "[1 2]")
            pdf.obj(23, "<</Subtype /Unheard /Rect [0 0 5 5]>>")
        }, pageEntries: "/Annots [null 7 20 0 R 21 0 R 22 0 R 99 0 R 23 0 R (x)]")
        let list = PdfAnnotations.read(document, document.pages[0])
        XCTAssertEqual(list.map { $0.subtype }, ["Text", "Unheard"])
        XCTAssertEqual(list[1].type, .other)
        XCTAssertEqual(list[0].pageIndex, 0)
        XCTAssertFalse(list[1].isMarkup)
        XCTAssertTrue(list[0].isMarkup)
    }

    func test_loopsAndHugeArraysDoNotHang() throws {
        let document = try AnnotationFixtures.blank(1, { $0.obj(20, "<</Subtype /Text /Rect [0 0 5 5] /IRT 20 0 R /Popup 20 0 R>>") }, pageEntries: "/Annots [20 0 R 20 0 R]")
        XCTAssertEqual(PdfAnnotations.read(document, document.pages[0]).count, 2)
        XCTAssertFalse(PdfComments.list(document).contains { !$0.replies.isEmpty })
    }

    func test_statesAndEndingsAreReadByTheirNames() throws {
        let a = try one("<</Subtype /Text /Rect [0 0 5 5] /State (2) /LE /3>>")
        XCTAssertNil(a.state)
        XCTAssertEqual(a.startEnding, LineEnding.none)
        XCTAssertNil(try one("<</Subtype /Text /Rect [0 0 5 5] /State ( Rejected )>>").state)
        XCTAssertEqual(try one("<</Subtype /Text /Rect [0 0 5 5] /State (Rejected)>>").state, .rejected)
    }

    func test_arraysManyAnnotationsPointToAreReadOnce() throws {
        let document = try AnnotationFixtures.blank(1, { pdf in
            pdf.obj(20, "<</Subtype /Highlight /Rect [0 0 5 5] /QuadPoints 21 0 R /InkList 22 0 R>>")
            pdf.obj(21, "[" + String(repeating: "1 ", count: 100_000) + "]")
            pdf.obj(22, "[" + String(repeating: "21 0 R ", count: 50_000) + "]")
        }, pageEntries: "/Annots [" + String(repeating: "20 0 R ", count: 20_000) + "]")
        let list = PdfAnnotations.read(document, document.pages[0])
        XCTAssertEqual(list.count, 20_000)
        XCTAssertEqual(list.last?.quadPoints.count, 100_000)
        XCTAssertEqual(list.last?.inkList.count, 50_000)
    }

    func test_readAllWalksEveryPage() throws {
        let document = try AnnotationFixtures.blank(3)
        let writer = PdfAnnotationWriter(document)
        try writer.addSquare(document.pages[0], PdfRect(1, 1, 50, 50))
        try writer.addSquare(document.pages[2], PdfRect(1, 1, 50, 50))
        XCTAssertEqual(PdfAnnotations.readAll(document).map { $0.pageIndex }, [0, 2])
    }

    func test_quadsRoundTripAndHaveBounds() {
        let quad = MarkupQuad.fromRect(PdfRect(10, 20, 110, 40))
        XCTAssertEqual(quad.bounds, PdfRect(10, 20, 110, 40))
        XCTAssertEqual([quad.x1, quad.y1, quad.x4, quad.y4], [10, 40, 110, 20])
    }

    func test_permissionsAreReportedNotEnforced() throws {
        XCTAssertTrue(PdfAnnotations.canAnnotate(try AnnotationFixtures.blank()))
        let id = [UInt8](repeating: 0, count: 16)
        let locked = PdfSecurity.create(userPassword: "user", ownerPassword: "owner", permissions: [.print, .copy], strength: .aes256, firstId: id)
        let file = try AnnotationFixtures.blank().saveRewrite(PdfSaveOptions(security: locked, documentId: id))
        XCTAssertFalse(PdfAnnotations.canAnnotate(try PdfDocument.open(file, password: "user")))
        XCTAssertTrue(PdfAnnotations.canAnnotate(try PdfDocument.open(file, password: "owner")))

        let open = PdfSecurity.create(userPassword: "user", ownerPassword: "owner", permissions: .annotate, strength: .aes256, firstId: id)
        let file2 = try AnnotationFixtures.blank().saveRewrite(PdfSaveOptions(security: open, documentId: id))
        XCTAssertTrue(PdfAnnotations.canAnnotate(try PdfDocument.open(file2, password: "user")))
    }

    func test_annotatingAnEncryptedFileSavesAndReopens() throws {
        let id = [UInt8](repeating: 0, count: 16)
        let security = PdfSecurity.create(userPassword: "user", ownerPassword: "owner", permissions: .all, strength: .aes256, firstId: id)
        let document = try PdfDocument.open(try AnnotationFixtures.blank().saveRewrite(PdfSaveOptions(security: security, documentId: id)), password: "user")
        let writer = PdfAnnotationWriter(document)
        try writer.addTextMarkup(document.pages[0], .highlight, [MarkupQuad.fromRect(PdfRect(10, 10, 100, 24))], info: AnnotationInfo(author: "A", contents: "secret note"))
        let reopened = try PdfDocument.open(try document.saveIncremental(), password: "user")
        XCTAssertEqual(PdfAnnotations.read(reopened, reopened.pages[0]).first?.contents, "secret note")
        XCTAssertEqual(PdfAnnotations.read(reopened, reopened.pages[0]).count, 1)
    }
}
