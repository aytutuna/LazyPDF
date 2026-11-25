#if canImport(PDFKit)
import XCTest
import LazyPDFApp
import LazyPDFKit

// Mirrors windows/LazyPDF.App.Tests/Tools/forms/ScanFormTests.cs: a scanned form drawn by the system and read for blanks, on a
// page as it comes and turned a quarter. ScanFormCorpusTests is left out: it reads the files a list in LAZYPDF_CORPUS names and
// does nothing without one.

final class ScanFormTests: XCTestCase {
    private static let width = 600, height = 800

    // A 300 by 400 point page holding one grey picture: two ruled lines, a check box and a box. With rotate 90 the picture lies
    // on its side on a 400 by 300 page that the viewer turns upright, as a sheet fed in sideways comes out.
    private static func scanPdf(rotate: Int) -> [UInt8] {
        var pixels = [UInt8](repeating: 245, count: width * height)
        func ink(_ x1: Int, _ y1: Int, _ x2: Int, _ y2: Int) {
            for y in y1..<y2 {
                for x in x1..<x2 { pixels[y * width + x] = 20 }
            }
        }
        func box(_ x: Int, _ y: Int, _ w: Int, _ h: Int) {
            ink(x, y, x + w, y + 3)
            ink(x, y + h - 3, x + w, y + h)
            ink(x, y, x + 3, y + h)
            ink(x + w - 3, y, x + w, y + h)
        }
        ink(150, 200, 500, 203)
        ink(150, 300, 500, 303)
        box(150, 380, 30, 30)
        box(150, 480, 350, 60)

        var imageWidth = width, imageHeight = height
        if rotate == 90 {
            var side = [UInt8](repeating: 0, count: pixels.count)
            for y in 0..<width {
                for x in 0..<height { side[y * height + x] = pixels[x * width + (width - 1 - y)] }
            }
            pixels = side
            (imageWidth, imageHeight) = (height, width)
        }

        var file: [UInt8] = []
        var offsets: [Int] = []
        func write(_ text: String) { file.append(contentsOf: Array(text.utf8)) }
        func object(_ number: Int, _ body: String) {
            offsets.append(file.count)
            write("\(number) 0 obj\n\(body)\nendobj\n")
        }
        write("%PDF-1.4\n")
        object(1, "<</Type /Catalog /Pages 2 0 R>>")
        object(2, "<</Type /Pages /Kids [3 0 R] /Count 1>>")
        object(3, "<</Type /Page /Parent 2 0 R /MediaBox [0 0 \(rotate == 90 ? "400 300" : "300 400")] /Rotate \(rotate) /Contents 4 0 R "
            + "/Resources <</XObject <</Im1 5 0 R>>>>>>")
        let content = rotate == 90 ? "q 400 0 0 300 0 0 cm /Im1 Do Q" : "q 300 0 0 400 0 0 cm /Im1 Do Q"
        object(4, "<</Length \(content.utf8.count)>>\nstream\n\(content)\nendstream")
        offsets.append(file.count)
        write("5 0 obj\n<</Type /XObject /Subtype /Image /Width \(imageWidth) /Height \(imageHeight) /ColorSpace /DeviceGray "
            + "/BitsPerComponent 8 /Length \(pixels.count)>>\nstream\n")
        file.append(contentsOf: pixels)
        write("\nendstream\nendobj\n")
        let xref = file.count
        write("xref\n0 6\n0000000000 65535 f \n" + offsets.map { String(format: "%010ld 00000 n \n", $0) }.joined()
            + "trailer\n<</Size 6 /Root 1 0 R>>\nstartxref\n\(xref)\n%%EOF\n")
        return file
    }

    // The proposals, and where the viewer shows them, in points from the top left of the page.
    private func found(_ rotate: Int) throws -> (proposals: [FieldProposal], places: [DisplayRect]) {
        let session = try PdfEditSession.open(Self.scanPdf(rotate: rotate))
        let renderer = PdfKitRenderer()
        XCTAssertTrue(renderer.load(session, nil))
        let proposals = try FieldDetector.detect(session.document, renderer)
        let geometry = PageGeometry(session.document.pages[0])
        let places = proposals.map { geometry.toDisplay($0.rect) }.sorted { $0.y != $1.y ? $0.y < $1.y : $0.x < $1.x }
        return (proposals, places)
    }

    func test_theLinesTheCheckBoxAndTheBoxOfAScanAreFound() throws {
        let proposals = try found(0).proposals

        XCTAssertEqual(proposals.filter { $0.kind == .text && $0.rect.height < 25 }.count, 2)
        XCTAssertEqual(proposals.filter { $0.kind == .checkBox }.count, 1)
        XCTAssertEqual(proposals.filter { $0.kind == .text && $0.rect.height > 25 }.count, 1)
        XCTAssertTrue(proposals.allSatisfy(\.fromPixels))
        let line = try XCTUnwrap(proposals.filter { $0.rect.height < 25 }.max { $0.rect.top < $1.rect.top })
        // The picture is 600 pixels over 300 points; the upper line is 100 points down the page, above 175 to 250 points across.
        XCTAssertEqual(line.rect.left, 75, accuracy: 2)
        XCTAssertEqual(line.rect.right, 250, accuracy: 2)
        XCTAssertEqual(line.rect.bottom, 301, accuracy: 1)
    }

    func test_aSidewaysScanTurnedUprightGivesTheSameFieldsInTheSamePlaces() throws {
        let upright = try found(0).places
        let turned = try found(90).places

        XCTAssertEqual(upright.count, 4)
        XCTAssertEqual(upright.count, turned.count)
        for (a, b) in zip(upright, turned) {
            XCTAssertEqual(a.x, b.x, accuracy: 2)
            XCTAssertEqual(a.y, b.y, accuracy: 2)
            XCTAssertEqual(a.width, b.width, accuracy: 2)
            XCTAssertEqual(a.height, b.height, accuracy: 2)
        }
    }
}
#endif
