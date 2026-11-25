import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Optimize/OptimizerTests.cs: the same cases. The PdfPig assertions (page count and
// text of each output) have no twin; the engine's own text is read in their place.

final class OptimizerTests: XCTestCase {
    private let picture = "/Type /XObject /Subtype /Image /Width 300 /Height 300 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /FlateDecode"

    // Text, a 216 dpi picture, a copy of it, a thumbnail and application data.
    private func sample() -> [UInt8] {
        let data = TestPdf.deflate(OptimizeKit.noise(300 * 300 * 3))
        return OptimizeKit.build("BT /F1 12 Tf 10 180 Td (Sample text) Tj ET q 100 0 0 100 10 10 cm /Im0 Do Q q 50 0 0 50 120 10 cm /Im1 Do Q",
                                 "/Font <</F1 5 0 R>> /XObject <</Im0 6 0 R /Im1 7 0 R>>", { pdf in
            pdf.obj(5, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica>>")
            pdf.stream(6, self.picture, data)
            pdf.stream(7, self.picture, data)
            pdf.stream(8, "/Type /XObject /Subtype /Image /Width 4 /Height 4 /ColorSpace /DeviceGray /BitsPerComponent 8", Array(repeating: 0, count: 16))
            pdf.obj(9, "<</App <</Note (private)>>>>")
        }, pageExtra: "/Thumb 8 0 R /PieceInfo 9 0 R")
    }

    func test_presetsTradeSizeForDetailInOrder() throws {
        let file = sample()
        let document = try PdfDocument.open(file)
        let plain = try document.saveRewrite().count
        let codec = OptimizeFakeCodec()
        let small = try PdfOptimizer(document, codec).run(OptimizeOptions.for(.small))
        let balanced = try PdfOptimizer(document, codec).run(OptimizeOptions.for(.balanced))
        let high = try PdfOptimizer(document, codec).run(OptimizeOptions.for(.highQuality))
        XCTAssertTrue(small.sizeAfter < balanced.sizeAfter, "\(small.sizeAfter) \(balanced.sizeAfter)")
        XCTAssertTrue(balanced.sizeAfter <= high.sizeAfter)
        XCTAssertTrue(high.sizeAfter <= plain)
        XCTAssertEqual(file.count, small.sizeBefore)
        for result in [small, balanced, high] {
            let reopened = try PdfDocument.open(result.bytes)
            XCTAssertEqual(1, reopened.pages.count)
            XCTAssertEqual("Sample text", try OptimizeKit.engineText(result.bytes).trimmingCharacters(in: .whitespacesAndNewlines))
            XCTAssertEqual(result.bytes.count, result.sizeAfter)
        }
        let smallDocument = try PdfDocument.open(small.bytes)
        XCTAssertEqual(1, OptimizeKit.count(smallDocument) { OptimizeKit.isImage(smallDocument, $0) })
        XCTAssertTrue((smallDocument.integer(try OptimizeKit.image(smallDocument).dictionary, "Width") ?? 0) < 300)
    }

    func test_onlyTheSmallestPresetMakesPicturesOneBit() {
        XCTAssertTrue(OptimizeOptions.for(.small).bilevelTolerance >= 0)
        let balanced = OptimizeOptions.for(.balanced)
        XCTAssertTrue(balanced.bilevelTolerance < 0)
        XCTAssertEqual(80, balanced.jpegQuality)
        XCTAssertEqual(150, balanced.imageDpi)
    }

    func test_thePlanNamesTheStepsAndAuditsTheFile() throws {
        let document = try PdfDocument.open(sample())
        let plan = PdfOptimizer(document).plan(OptimizeOptions.for(.balanced))
        XCTAssertEqual(OptimizeStepKind.removeUnreferenced, plan.steps[0])
        XCTAssertTrue(plan.steps.contains(.downsampleImages))
        XCTAssertTrue(plan.steps.contains(.subsetFonts))
        XCTAssertFalse(plan.steps.contains(.grayscale))
        XCTAssertEqual(document.length, plan.audit.fileSize)
        XCTAssertTrue(plan.audit.of(.images) > 100_000)
        XCTAssertEqual(plan.audit.fileSize, plan.audit.bytes.values.reduce(0, +))
        for step in plan.steps {
            XCTAssertNotEqual("\(step)", OptimizeText.stepName(step))
        }
    }

    func test_theDocumentItWasGivenIsNotChanged() throws {
        let document = try PdfDocument.open(sample())
        let before = describe(document)
        _ = try PdfOptimizer(document).run(OptimizeOptions.for(.small).with { $0.grayscale = true })
        XCTAssertEqual(before, describe(document))
    }

    func test_aCancelledTokenThrowsBeforeAnyStep() async throws {
        let file = sample()
        let task = Task { () throws -> Int in
            let document = try PdfDocument.open(file)
            let codec = OptimizeFakeCodec()
            while !Task.isCancelled { await Task.yield() }
            do {
                _ = try PdfOptimizer(document, codec).run(OptimizeOptions.for(.small))
            } catch is CancellationError {
                return codec.decodes
            }
            return -1
        }
        task.cancel()
        let decodes = try await task.value
        XCTAssertEqual(0, decodes)
    }

    func test_cancellingInsideTheImagesStopsTheRest() async throws {
        let dictionary = "/Type /XObject /Subtype /Image /Width 16 /Height 16 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode"
        let file = OptimizeKit.build("q 72 0 0 72 10 10 cm /Im0 Do Q q 72 0 0 72 10 10 cm /Im1 Do Q q 72 0 0 72 10 10 cm /Im2 Do Q q 72 0 0 72 10 10 cm /Im3 Do Q",
                                     "/XObject <</Im0 5 0 R /Im1 6 0 R /Im2 7 0 R /Im3 8 0 R>>", { pdf in
            for i in 5...8 { pdf.stream(i, dictionary, OptimizeKit.tinyJpeg) }
        })
        let task = Task { () throws -> Int in
            let document = try PdfDocument.open(file)
            let codec = OptimizeFakeCodec()
            codec.onDecode = { withUnsafeCurrentTask { $0?.cancel() } }
            let options = OptimizeKit.off.with { $0.imageDpi = 8; $0.imageDpiAbove = 10 }
            do {
                _ = try PdfOptimizer(document, codec).run(options)
            } catch is CancellationError {
                return codec.decodes
            }
            return -1
        }
        let decodes = try await task.value
        XCTAssertEqual(1, decodes)
    }

    func test_aLiveTokenChangesNothingInTheResult() async throws {
        let file = sample()
        let options = OptimizeOptions.for(.balanced).with { $0.objectStreams = false; $0.documentId = Array(repeating: 0, count: 16) }
        let plain = try PdfOptimizer(PdfDocument.open(file), OptimizeFakeCodec()).run(options).bytes
        let task = Task { () throws -> [UInt8] in
            try PdfOptimizer(PdfDocument.open(file), OptimizeFakeCodec()).run(options).bytes
        }
        let watched = try await task.value
        // The second half of the trailer id is random, so the bytes differ there and nowhere else.
        XCTAssertEqual(plain.count, watched.count)
        XCTAssertTrue(zip(plain, watched).filter { $0 != $1 }.count <= 32)
    }

    private func describe(_ document: PdfDocument) -> String {
        document.objectNumbers.map { n -> String in
            let value = document.get(n)
            if let s = value as? PdfStream { return "\(n):\(s.dictionary.description)\(document.rawData(s).count)" }
            return "\(n):\(value?.description ?? "")"
        }.joined(separator: "|")
    }

    func test_aTinyFileIsNeverLargerThanAPlainRewrite() throws {
        let document = try PdfDocument.open(TestPdf.simple(1))
        let plain = try document.saveRewrite().count
        for preset in [OptimizePreset.small, .balanced, .highQuality] {
            let result = try PdfOptimizer(document).run(OptimizeOptions.for(preset))
            XCTAssertTrue(result.sizeAfter <= plain, "\(preset): \(result.sizeAfter) > \(plain)")
        }
    }

    func test_objectStreamsAreUsedWhenTheyPay() throws {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R>>")
        let kids = (0..<60).map { "\(3 + $0) 0 R" }.joined(separator: " ")
        pdf.obj(2, "<</Type /Pages /Kids [\(kids)] /Count 60 /MediaBox [0 0 200 200]>>")
        for i in 0..<60 { pdf.obj(3 + i, "<</Type /Page /Parent 2 0 R /Resources <</ProcSet [/PDF /Text]>>>>") }
        let document = try PdfDocument.open(pdf.finish())
        let result = try PdfOptimizer(document).run(OptimizeOptions.for(.balanced))
        XCTAssertEqual(1, result.steps.first { $0.kind == .objectStreams }?.count)
        XCTAssertTrue(result.sizeAfter < (try document.saveRewrite().count))
        XCTAssertEqual(60, try PdfDocument.open(result.bytes).pages.count)
    }

    func test_anEncryptedFileComesOutOpenOrEncryptedAsAsked() throws {
        let id = Array(repeating: UInt8(0), count: 16)
        let security = PdfSecurity.create(userPassword: "user", ownerPassword: "owner", permissions: .all, strength: .aes256, firstId: id)
        let plain = try PdfDocument.open(sample())
        let locked = try plain.saveRewrite(PdfSaveOptions(security: security))
        let document = try PdfDocument.open(locked, password: "user")
        XCTAssertTrue(document.isEncrypted)

        let open = try PdfOptimizer(document).run(OptimizeOptions.for(.balanced))
        XCTAssertFalse(try PdfDocument.open(open.bytes).isEncrypted)

        let again = PdfSecurity.create(userPassword: "user", ownerPassword: "owner", permissions: .all, strength: .aes256, firstId: id)
        let sealedResult = try PdfOptimizer(document).run(OptimizeOptions.for(.balanced).with { $0.security = again })
        let closed = try PdfDocument.open(sealedResult.bytes, password: "user")
        XCTAssertTrue(closed.isEncrypted)
        XCTAssertEqual("Sample text", try OptimizeKit.engineText(open.bytes).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
