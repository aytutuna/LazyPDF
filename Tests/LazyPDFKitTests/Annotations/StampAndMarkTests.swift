import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Annotations/StampAndMarkTests.cs: the same cases. CustomStampMayBeTurkish uses the
// synthetic font and its letters. PdfPigSeesTheStampAndTheNote has no twin (PdfPig). In JpegStampNeedsAReadableJpeg the
// bad pixel size is a precondition of ContentImages.addRgba and cannot be caught, and a bad JPEG is a PdfReadException.

final class StampAndMarkTests: XCTestCase {
    private func start(_ fonts: FontSource? = nil) throws -> (document: PdfDocument, writer: PdfAnnotationWriter, page: PdfPage) {
        let document = try AnnotationFixtures.blank()
        return (document, PdfAnnotationWriter(document, fonts), document.pages[0])
    }

    private let rgba: [UInt8] = [255, 0, 0, 255, 0, 255, 0, 128, 0, 0, 255, 255, 255, 255, 0, 255]

    func test_everyStandardStampSaysItsWordsInsideItsBox() throws {
        let (document, writer, page) = try start()
        for name in AnnotationText.standardStamps {
            let stamp = try writer.addStamp(page, PdfRect(100, 600, 300, 660), name)
            let recorder = try AnnotationFixtures.draw(document, stamp)
            XCTAssertEqual(recorder.text.replacingOccurrences(of: " ", with: ""), AnnotationText.stampLabel(name).replacingOccurrences(of: " ", with: ""), name)
            for g in recorder.glyphs { XCTAssertTrue(g.bounds.left >= 0 && g.bounds.right <= 200 && g.bounds.top <= 60, name) }
            XCTAssertEqual(stamp.iconName, name)
        }
        try AnnotationFixtures.reopen(document)
    }

    func test_longStampWordsShrinkToFit() throws {
        let (document, writer, page) = try start()
        let stamp = try writer.addStamp(page, PdfRect(100, 600, 160, 640), "NotForPublicRelease")
        let glyphs = try AnnotationFixtures.draw(document, stamp).glyphs
        XCTAssertTrue(try XCTUnwrap(glyphs.last).bounds.right <= 60)
        XCTAssertTrue(try XCTUnwrap(glyphs.first).bounds.height < 10)
    }

    func test_customStampMayBeTurkish() throws {
        let (document, writer, page) = try start(try AnnotationFixtures.ArialSource())
        let stamp = try writer.addStamp(page, PdfRect(100, 600, 360, 660), "AB ğİ BA", color: [0, 0.4, 0])
        XCTAssertEqual(try AnnotationFixtures.draw(document, stamp).text, "AB ğİ BA")
        XCTAssertEqual(stamp.color, [0, 0.4, 0])
    }

    func test_imageStampPaintsItsPicture() throws {
        let (document, writer, page) = try start()
        let stamp = try writer.addImageStamp(page, PdfRect(100, 600, 180, 660), 2, 2, rgba)
        let images = try AnnotationFixtures.draw(document, stamp).images
        XCTAssertEqual(images.count, 1)
        let image = images[0]
        XCTAssertEqual(image.width, 2)
        XCTAssertEqual(image.height, 2)
        XCTAssertEqual(image.bounds.width, 80, accuracy: 5e-4)
        XCTAssertNotNil(document.stream(image.dictionary, "SMask"))

        let moved = try writer.resize(stamp, PdfRect(100, 600, 260, 720))
        XCTAssertEqual(moved.rect.width, 160)
        XCTAssertEqual(try AnnotationFixtures.draw(document, moved).images[0].bounds.width, 80, accuracy: 5e-4)
        try AnnotationFixtures.reopen(document)
    }

    func test_opacityAndColorKeepTheArtworkOfAnImageStamp() throws {
        let (document, writer, page) = try start()
        let stamp = try writer.addImageStamp(page, PdfRect(100, 600, 180, 660), 2, 2, rgba)
        let faded = try writer.setColor(try writer.setOpacity(stamp, 0.5), [1, 0, 0])
        XCTAssertEqual(try AnnotationFixtures.draw(document, faded).images.count, 1)
    }

    func test_jpegStampNeedsAReadableJpeg() throws {
        let (_, writer, page) = try start()
        XCTAssertThrowsError(try writer.addJpegStamp(page, PdfRect(1, 1, 50, 50), [1, 2, 3])) {
            XCTAssertEqual(($0 as? PdfReadException)?.problem, .damaged)
        }
    }

    func test_caretIsAFilledWedge() throws {
        let (document, writer, page) = try start()
        let caret = try writer.addCaret(page, PdfRect(100, 600, 116, 616), info: AnnotationInfo(author: "A", contents: "insert here"))
        XCTAssertEqual(document.name(caret.dictionary, "Sy"), "P")
        let recorder = try AnnotationFixtures.draw(document, caret)
        XCTAssertEqual(recorder.paths.count, 1)
        let path = try XCTUnwrap(recorder.paths.first).path
        XCTAssertTrue(path.fill)
        XCTAssertEqual(path.bounds.width, 16, accuracy: 0.01)
    }

    func test_attachedFileCanBeListedAndExtracted() throws {
        let (document, writer, page) = try start()
        let data = (0..<500).map { UInt8($0 % 7) }
        let clip = try writer.addFileAttachment(page, PdfRect(100, 700, 116, 716), "notes.bin", data, info: AnnotationInfo(author: "A", contents: "see file"),
                                                icon: "Paperclip", mimeType: "application/octet-stream")
        XCTAssertEqual(clip.iconName, "Paperclip")
        let reopened = try AnnotationFixtures.reopen(document)
        let list = PdfAttachments.list(reopened)
        XCTAssertEqual(list.count, 1)
        let attachment = list[0]
        XCTAssertEqual(attachment.fileName, "notes.bin")
        XCTAssertEqual(attachment.pageIndex, 0)
        XCTAssertEqual(try PdfAttachments.extract(reopened, attachment), data)
        XCTAssertTrue(AnnotationFixtures.operators(try AnnotationFixtures.appearance(document, clip)).contains("S"))
    }

    func test_redactIsOnlyAMark() throws {
        let (document, writer, page) = try start()
        let mark = try writer.addRedact(page, [MarkupQuad.fromRect(PdfRect(100, 600, 200, 614))], info: AnnotationInfo(author: "A"), fill: [0, 0, 0], overlayText: "REDACTED")
        XCTAssertEqual(mark.type, .redact)
        XCTAssertEqual(mark.interiorColor, [0, 0, 0])
        XCTAssertEqual(PdfText.read(document, mark.dictionary, "OverlayText"), "REDACTED")
        let recorder = try AnnotationFixtures.draw(document, mark)
        XCTAssertEqual(recorder.paths.count, 1)
        let path = try XCTUnwrap(recorder.paths.first).path
        XCTAssertTrue(path.stroke && !path.fill)
        XCTAssertThrowsError(try writer.addRedact(page, [])) { XCTAssertTrue($0 is ArgumentException) }
    }

    func test_linkWithABorderGetsAnAppearanceAndOneWithoutDoesNot() throws {
        let (document, writer, page) = try start()
        let bordered = try writer.addLink(page, PdfRect(100, 600, 200, 620), UriAction("https://example.com"), style: AnnotationStyle(color: [0, 0, 1], width: 2))
        let plain = try writer.addLink(page, PdfRect(100, 500, 200, 520), PdfDestination(1, .fit))
        XCTAssertTrue(bordered.hasAppearance)
        XCTAssertFalse(plain.hasAppearance)
        let recorder = try AnnotationFixtures.draw(document, bordered)
        XCTAssertEqual(recorder.paths.count, 1)
        XCTAssertEqual(try XCTUnwrap(recorder.paths.first).path.bounds, PdfRect(1, 1, 99, 19))
        let links = PdfLinks.read(try AnnotationFixtures.reopen(document), document.pages[0])
        XCTAssertEqual(links.count, 2)
        XCTAssertEqual(links[0].uri, "https://example.com")
        XCTAssertEqual(links[1].destination?.pageIndex, 1)
    }
}
