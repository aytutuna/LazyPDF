import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Compare/ImageCompareTests.cs: the same cases.

final class ImageCompareTests: CompareTestCase {
    private let text = [CompareLine("Some text on a page with pictures")]

    private struct Pic {
        var x: Double
        var y: Double
        var w: Double
        var h: Double
        var pixels: String
    }

    private let logo = Pic(x: 100, y: 300, w: 80, h: 60, pixels: "00FF00FF")

    /// A page with the given pictures: gray 2 by 2 images, or the real JPEG when the pixels read "jpeg".
    private func withImages(_ images: [Pic]) throws -> PdfDocument {
        let file = bytes([text], more: { pdf, first in
            for (i, image) in images.enumerated() {
                if image.pixels == "jpeg" {
                    let jpeg = [UInt8](Data(base64Encoded: CompareKit.sampleJpeg) ?? Data())
                    pdf.stream(first + i, "/Type /XObject /Subtype /Image /Width 8 /Height 6 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode", jpeg)
                } else {
                    pdf.stream(first + i, "/Type /XObject /Subtype /Image /Width 2 /Height 2 /ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /ASCIIHexDecode", image.pixels + ">")
                }
            }
        })
        let xobjects = images.indices.map { "/Im\($0) \(8 + $0) 0 R" }.joined(separator: " ")
        let draw = images.enumerated().map { i, m in
            "q \(TextTestPdf.number(m.w)) 0 0 \(TextTestPdf.number(m.h)) \(TextTestPdf.number(m.x)) \(TextTestPdf.number(m.y)) cm /Im\(i) Do Q "
        }.joined()
        let changed = TestPdf.text(file)
            .replacingOccurrences(of: "/Resources <</Font", with: "/Resources <</XObject <<\(xobjects)>> /Font")
            .replacingOccurrences(of: "Tj ET\n", with: "Tj ET\n\(draw)")
        return try open(TestPdf.latin(changed))
    }

    private func run(_ a: [Pic], _ b: [Pic]) throws -> ComparisonResult {
        let before = try withImages(a)
        let after = try withImages(b)
        return try PdfComparer.compare(before, after)
    }

    func test_sameImageSamePlaceIsNoChange() throws {
        XCTAssertTrue(try run([logo], [logo]).isIdentical)
    }

    func test_sameJpegSamePlaceIsNoChange() throws {
        let photo = Pic(x: 100, y: 300, w: 80, h: 60, pixels: "jpeg")
        XCTAssertTrue(try run([photo], [photo]).isIdentical)
    }

    func test_jpegAgainstAGrayImageIsAReplacement() throws {
        let change = try single(try run([Pic(x: 100, y: 300, w: 80, h: 60, pixels: "jpeg")], [logo]).changes)
        XCTAssertEqual(change.detail, CompareText.imageReplaced)
    }

    func test_movedImageIsOneChange() throws {
        var moved = logo
        moved.x = 300
        moved.y = 400
        let change = try single(try run([logo], [moved]).changes)
        XCTAssertEqual(change.kind, .changed)
        XCTAssertEqual(change.area, .image)
        XCTAssertEqual(change.detail, CompareText.imageMoved)
        assertInRange(try single(change.oldQuads).bounds.left, 99, 101)
        assertInRange(try single(change.newQuads).bounds.left, 299, 301)
    }

    func test_replacedImageAtTheSamePlaceIsOneChange() throws {
        var replaced = logo
        replaced.pixels = "FF00FF00"
        let change = try single(try run([logo], [replaced]).changes)
        XCTAssertEqual(change.detail, CompareText.imageReplaced)
    }

    func test_addedAndRemovedImages() throws {
        let added = try single(try run([], [logo]).changes)
        XCTAssertEqual(added.kind, .added)
        XCTAssertEqual(added.area, .image)
        XCTAssertTrue(added.oldQuads.isEmpty)
        let removed = try single(try run([logo], []).changes)
        XCTAssertEqual(removed.kind, .removed)
        XCTAssertTrue(removed.newQuads.isEmpty)
    }

    func test_equalPicturesAreMatchedOneToOne() throws {
        let result = try run([logo, logo], [logo])
        XCTAssertEqual(try single(result.changes).kind, .removed)
    }

    func test_pictureOnlyPagesArePairedByTheirPictures() throws {
        func make(_ first: String, _ second: String) -> [UInt8] {
            let pdf = TestPdf()
            pdf.obj(1, "<</Type /Catalog /Pages 2 0 R>>")
            pdf.obj(2, "<</Type /Pages /Kids [3 0 R 4 0 R] /Count 2 /MediaBox [0 0 200 200]>>")
            pdf.obj(3, "<</Type /Page /Parent 2 0 R /Contents 5 0 R /Resources <</XObject <</I 6 0 R>>>>>>")
            pdf.obj(4, "<</Type /Page /Parent 2 0 R /Contents 5 0 R /Resources <</XObject <</I 7 0 R>>>>>>")
            pdf.stream(5, "", "q 200 0 0 200 0 0 cm /I Do Q")
            pdf.stream(6, "/Type /XObject /Subtype /Image /Width 2 /Height 2 /ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /ASCIIHexDecode", first + ">")
            pdf.stream(7, "/Type /XObject /Subtype /Image /Width 2 /Height 2 /ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /ASCIIHexDecode", second + ">")
            return pdf.finish()
        }
        let a = try open(make("00112233", "FF00FF00"))
        let b = try open(make("44556677", "FF00FF00"))
        let result = try PdfComparer.compare(a, b)
        XCTAssertEqual(result.pages.map { $0.newIndex }, [0, 1])
        for p in result.pages { XCTAssertFalse(p.isAdded || p.isRemoved) }
        let change = try single(result.changes)
        XCTAssertEqual(change.area, .image)
        XCTAssertEqual(change.newPage, 0)
    }
}
