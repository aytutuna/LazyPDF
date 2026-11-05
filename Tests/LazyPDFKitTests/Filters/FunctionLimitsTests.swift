import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Filters/FunctionLimitsTests.cs: the same cases. The Task and Task.Delay
// of the sharing test are a thread and a semaphore with the same ten seconds.

final class FunctionLimitsTests: XCTestCase {
    private final class Outcome: @unchecked Sendable {
        var result: Result<PdfFunction, Error>?
    }

    private func parse(_ dictionary: String, _ data: [UInt8]? = nil) throws -> PdfFunction {
        let streams = FilterFixtures.Streams()
        let function: PdfObject
        if let data {
            function = try streams.add(dictionary, data)
        } else {
            function = try FilterFixtures.parse(dictionary)
        }
        return try PdfFunction.parse(function, FilterFixtures.resolve, streams.decode)
    }

    private func eval(_ f: PdfFunction, _ input: Double...) throws -> [Double] {
        var output = [Double](repeating: 0, count: f.outputs)
        try f.evaluate(input, &output)
        return output
    }

    func test_tintTransformWithAHugeRangeIsRefusedBeforeItAllocates() throws {
        let range = "[" + String(repeating: "0 1 ", count: 1_000_000) + "]"
        let streams = FilterFixtures.Streams()
        let tint = try streams.add("<< /FunctionType 4 /Domain [0 1] /Range \(range) >>", Array("{ }".utf8))
        let image = try FilterFixtures.dict("<< /Width 1 /Height 1 /BitsPerComponent 8 >>")
        image["ColorSpace"] = PdfArray([PdfName("Separation"), PdfName("X"), PdfName("DeviceGray"), tint])
        XCTAssertThrowsError(try PdfImageSamples.toRgba(image, [128], FilterFixtures.resolve, streams.decode)) { error in
            XCTAssertTrue(error is PdfReadException)
        }
    }

    func test_functionsThatManyOthersShareAreParsedOnce() throws {
        // Each level lists the next 256 times; parsed afresh every time that is 256 to the 8th power calls.
        var table: [Int: PdfObject] = [:]
        let bounds = (1...255).map(String.init).joined(separator: " ")
        let encode = Array(repeating: "0 1", count: 256).joined(separator: " ")
        for level in 1...7 {
            let kids = Array(repeating: "\(level + 1) 0 R", count: 256).joined(separator: " ")
            table[level] = try FilterFixtures.parse("<< /FunctionType 3 /Domain [0 1] /Bounds [\(bounds)] /Encode [\(encode)] /Functions [\(kids)] >>")
        }
        table[8] = try FilterFixtures.parse("<< /FunctionType 2 /Domain [0 1] /N 1 >>")
        let shared = table
        let resolve: @Sendable (PdfObject?) -> PdfObject? = { v in
            if let reference = v as? PdfReference { return shared[reference.number] }
            return v
        }

        let outcome = Outcome()
        let finished = DispatchSemaphore(value: 0)
        let worker = Thread {
            outcome.result = Result { try PdfFunction.parse(PdfReference(1, 0), resolve, { _ in [] }) }
            finished.signal()
        }
        worker.stackSize = 16 << 20
        worker.start()
        XCTAssertEqual(finished.wait(timeout: .now() + 10), .success)
        let function = try XCTUnwrap(outcome.result).get()
        XCTAssertEqual(try eval(function, 0.5)[0], 0.5, accuracy: 1e-9)
    }

    func test_reversedDomainOrRangeIsDamagedNotAnArgumentError() {
        assertProblem(.damaged, try parse("<< /FunctionType 2 /Domain [1 0] /N 1 >>"))
        assertProblem(.damaged, try parse("<< /FunctionType 2 /Domain [0 1] /Range [1 0] /N 1 >>"))
    }

    func test_labWithAReversedRangeKeepsTheDefaultRange() throws {
        let image = try FilterFixtures.dict("<< /Width 1 /Height 1 /BitsPerComponent 8 /ColorSpace [/Lab << /WhitePoint [0.95 1 1.09] /Range [100 -100 0 1] >>] >>")
        let rgba = try PdfImageSamples.toRgba(image, [128, 140, 120], FilterFixtures.resolve, { _ in [] })
        XCTAssertEqual(rgba.rgba.count, 4)
    }

    func test_sampleCountThatWrapsALongIsDamaged() {
        assertProblem(.damaged, try parse("<< /FunctionType 0 /Domain [0 1 0 1 0 1] /Range [0 1] /Size [65536 131072 1073741824] /BitsPerSample 1 >>", [0xFF]))
    }

    func test_aDimensionOfOneSampleIsCountedOnce() throws {
        let f = try parse("<< /FunctionType 0 /Domain [0 1] /Range [0 1] /Size [1] /BitsPerSample 8 >>", [0x40])
        XCTAssertEqual(try eval(f, 0.5)[0], 0x40 / 255.0, accuracy: 1e-9)
    }

    func test_calculatorDivisionByMinusOneDoesNotOverflow() throws {
        for program in ["{ pop -1e300 -1 idiv }", "{ pop -1e300 -1 mod }"] {
            let f = try parse("<< /FunctionType 4 /Domain [0 1] /Range [-1e30 1e30] >>", Array(program.utf8))
            _ = try eval(f, 0.5)
        }
    }
}
