import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Optimize/OptimizeStreamTests.cs: the same cases. The words are drawn with a
// generator of the test's own.

final class OptimizeStreamTests: XCTestCase {
    private func words() -> String {
        var state: UInt64 = 7
        func next(_ bound: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 33) % UInt64(bound))
        }
        let list = ["alpha", "bravo", "charlie", "delta", "echo", "foxtrot", "golf", "hotel", "india", "juliet"]
        var text = ""
        for i in 0..<400 { text += "BT /F1 10 Tf 10 \(190 - i % 180) Td (\(list[next(list.count)]) \(list[next(list.count)])) Tj ET\n" }
        return text
    }

    private let font = "/Font <</F1 <</Type /Font /Subtype /Type1 /BaseFont /Helvetica>>>>"

    func test_flateStreamIsDeflatedAgainAtTheSmallestLevel() throws {
        let content = Latin1.bytes(words())
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R>>")
        pdf.obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 200 200]>>")
        pdf.obj(3, "<</Type /Page /Parent 2 0 R /Contents 4 0 R /Resources <<\(font)>>>>")
        pdf.stream(4, "/Filter /FlateDecode", TestPdf.deflate(content))
        let document = try PdfDocument.open(pdf.finish())
        let result = try PdfOptimizer(document).run(OptimizeKit.off.with { $0.recompressStreams = true })
        XCTAssertEqual(1, result.steps.first { $0.kind == .recompressStreams }?.count)
        XCTAssertTrue(result.sizeAfter < (try document.saveRewrite().count))
        let after = try PdfDocument.open(result.bytes)
        let stream = try XCTUnwrap(after.resolve(after.pages[0].dictionary["Contents"]) as? PdfStream)
        XCTAssertEqual(content, try after.data(stream))
    }

    func test_lzwWithPredictorBecomesFlateAndKeepsThePredictor() throws {
        let w = 20, h = 20
        var rows: [UInt8] = []
        let samples = OptimizeKit.gradient(w, h, 3)
        for y in 0..<h {
            rows.append(0)
            rows += samples[(y * w * 3)..<(y * w * 3 + w * 3)]
        }
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R>>")
        pdf.obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 200 200]>>")
        pdf.obj(3, "<</Type /Page /Parent 2 0 R /Contents 4 0 R /Resources <</XObject <</Im0 5 0 R>>>>>>")
        pdf.stream(4, "", "q 100 0 0 100 0 0 cm /Im0 Do Q")
        pdf.stream(5, "/Type /XObject /Subtype /Image /Width \(w) /Height \(h) /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /LZWDecode /DecodeParms <</Predictor 12 /Colors 3 /Columns \(w) /EarlyChange 0>>",
                   PdfFilterEncoders.lzw(rows, false))
        let document = try PdfDocument.open(pdf.finish())
        XCTAssertEqual(samples, try document.data(try OptimizeKit.image(document)))

        let result = try PdfOptimizer(document).run(OptimizeOptions.for(.highQuality).with { $0.imageDpi = 0; $0.bilevelTolerance = -1 })
        XCTAssertEqual(1, result.steps.first { $0.kind == .convertOldFilters }?.count)
        let after = try PdfDocument.open(result.bytes)
        let image = try OptimizeKit.image(after)
        XCTAssertEqual("FlateDecode", after.name(image.dictionary, "Filter"))
        XCTAssertEqual(12, after.integer(after.dict(image.dictionary, "DecodeParms"), "Predictor"))
        XCTAssertNil(after.dict(image.dictionary, "DecodeParms")?["EarlyChange"])
        XCTAssertEqual(samples, try after.data(image))
    }

    func test_streamThatDoesNotDecodeIsLeftAlone() throws {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R>>")
        pdf.obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 200 200]>>")
        pdf.obj(3, "<</Type /Page /Parent 2 0 R /Contents 4 0 R /Resources <<>> /Junk 5 0 R>>")
        pdf.stream(4, "", "0 0 10 10 re f")
        let junk = OptimizeKit.noise(300)
        pdf.stream(5, "/Filter /FlateDecode", junk)
        let document = try PdfDocument.open(pdf.finish())
        let result = try PdfOptimizer(document).run(OptimizeKit.off.with { $0.recompressStreams = true })
        let after = try PdfDocument.open(result.bytes)
        XCTAssertEqual(0, result.steps.first { $0.kind == .recompressStreams }?.count)
        let stream = try XCTUnwrap(after.resolve(after.pages[0].dictionary["Junk"]) as? PdfStream)
        XCTAssertEqual(junk, after.rawData(stream))
    }
}
