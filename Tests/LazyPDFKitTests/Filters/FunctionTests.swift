import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Filters/FunctionTests.cs: the same cases.

final class FunctionTests: XCTestCase {
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

    private func calculator(_ program: String, _ domain: String = "[0 1]", _ range: String = "[0 1]") throws -> PdfFunction {
        try parse("<< /FunctionType 4 /Domain \(domain) /Range \(range) >>", Array(program.utf8))
    }

    private func eval(_ f: PdfFunction, _ input: Double...) throws -> [Double] {
        var output = [Double](repeating: 0, count: f.outputs)
        try f.evaluate(input, &output)
        return output
    }

    private func near(_ expected: Double, _ actual: Double, _ tolerance: Double = 1e-9, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(abs(expected - actual) <= tolerance, "expected \(expected), got \(actual)", file: file, line: line)
    }

    func test_exponentialInterpolatesBetweenTheEnds() throws {
        let f = try parse("<< /FunctionType 2 /Domain [0 1] /C0 [0 0] /C1 [1 0.5] /N 2 >>")
        XCTAssertEqual(f.inputs, 1)
        XCTAssertEqual(f.outputs, 2)
        let y = try eval(f, 0.5)
        near(0.25, y[0])
        near(0.125, y[1])
    }

    func test_exponentialClipsToDomainAndRange() throws {
        let f = try parse("<< /FunctionType 2 /Domain [0 1] /Range [0 0.8] /N 1 >>")
        near(0.8, try eval(f, 3)[0])
        near(0, try eval(f, -3)[0])
    }

    func test_exponentialWithUnequalEndsIsDamaged() {
        assertProblem(.damaged, try parse("<< /FunctionType 2 /Domain [0 1] /C0 [0] /C1 [1 1] /N 1 >>"))
    }

    private let stitched =
        "<< /FunctionType 3 /Domain [0 1] /Bounds [0.5] /Encode [0 1 0 1] /Functions [" +
        "<< /FunctionType 2 /Domain [0 1] /C0 [0] /C1 [1] /N 1 >> << /FunctionType 2 /Domain [0 1] /C0 [1] /C1 [0] /N 1 >>] >>"

    func test_stitchingPicksTheSubdomain() throws {
        for (x, expected) in [(0.0, 0.0), (0.25, 0.5), (0.5, 1.0), (0.75, 0.5), (1.0, 0.0)] {
            near(expected, try eval(try parse(stitched), x)[0])
        }
    }

    func test_stitchingEncodeCanRunBackwards() throws {
        let f = try parse("<< /FunctionType 3 /Domain [0 1] /Bounds [] /Encode [1 0] /Functions [<< /FunctionType 2 /Domain [0 1] /N 1 >>] >>")
        near(0.75, try eval(f, 0.25)[0])
    }

    func test_stitchingWithTheWrongBoundsCountIsDamaged() {
        assertProblem(.damaged, try parse("<< /FunctionType 3 /Domain [0 1] /Bounds [0.2 0.4] /Encode [0 1 0 1] /Functions [<< /FunctionType 2 /Domain [0 1] /N 1 >> << /FunctionType 2 /Domain [0 1] /N 1 >>] >>"))
    }

    func test_stitchingDeeperThanTheLimitIsDamaged() {
        var f = "<< /FunctionType 2 /Domain [0 1] /N 1 >>"
        for _ in 0..<12 {
            f = "<< /FunctionType 3 /Domain [0 1] /Bounds [] /Encode [0 1] /Functions [\(f)] >>"
        }
        assertProblem(.damaged, try parse(f))
    }

    func test_sampledInterpolatesOneInput() throws {
        let f = try parse("<< /FunctionType 0 /Domain [0 1] /Range [0 1] /Size [3] /BitsPerSample 8 >>", [0, 255, 0])
        near(0, try eval(f, 0)[0])
        near(0.5, try eval(f, 0.25)[0], 1e-9)
        near(1, try eval(f, 0.5)[0])
        near(0, try eval(f, 1)[0])
    }

    func test_sampledInterpolatesTwoInputsWithTheFirstVaryingFastest() throws {
        let f = try parse("<< /FunctionType 0 /Domain [0 1 0 1] /Range [0 1] /Size [2 2] /BitsPerSample 8 >>", [0, 255, 255, 0])
        near(0, try eval(f, 0, 0)[0])
        near(1, try eval(f, 1, 0)[0])
        near(1, try eval(f, 0, 1)[0])
        near(0, try eval(f, 1, 1)[0])
        near(0.5, try eval(f, 0.5, 0.5)[0])
        near(0.75, try eval(f, 0.75, 0)[0])
    }

    func test_sampledGivesSeveralOutputs() throws {
        let f = try parse("<< /FunctionType 0 /Domain [0 1] /Range [0 1 0 1] /Size [2] /BitsPerSample 8 >>", [0, 255, 255, 0])
        XCTAssertEqual(f.outputs, 2)
        var y = try eval(f, 0)
        near(0, y[0])
        near(1, y[1])
        y = try eval(f, 1)
        near(1, y[0])
        near(0, y[1])
    }

    func test_sampledReadsEveryBitDepth() throws {
        // Three samples; the second is the maximum, the third as given.
        let cases: [(Int, [UInt8], Double)] = [
            (1, [0x40], 0.0),
            (2, [0x34], 1.0 / 3),
            (4, [0x0F, 0x80], 8.0 / 15),
            (12, [0x00, 0x0F, 0xFF, 0x80, 0x00], 2048 / 4095.0),
            (16, [0, 0, 0xFF, 0xFF, 0x80, 0x00], 32768 / 65535.0),
            (24, [0, 0, 0, 0xFF, 0xFF, 0xFF, 0x80, 0, 0], 0.5),
            (32, [0, 0, 0, 0, 0xFF, 0xFF, 0xFF, 0xFF, 0x80, 0, 0, 0], 0.5),
        ]
        for (bits, data, lastSample) in cases {
            let f = try parse("<< /FunctionType 0 /Domain [0 1] /Range [0 1] /Size [3] /BitsPerSample \(bits) >>", data)
            near(lastSample, try eval(f, 1)[0], 1e-6)
            near(1, try eval(f, 0.5)[0], 1e-6)
        }
    }

    func test_sampledDecodeAndEncodeAreApplied() throws {
        let f = try parse("<< /FunctionType 0 /Domain [0 1] /Range [0 1] /Decode [1 0] /Encode [1 0] /Size [2] /BitsPerSample 8 >>", [0, 255])
        // Encode runs backwards, so x = 0 reads the last sample; Decode flips the result.
        near(0, try eval(f, 0)[0])
        near(1, try eval(f, 1)[0])
    }

    func test_sampledWithANanInputStaysInsideTheSamples() throws {
        // A NaN does not clamp, and its fraction is not 0, so the corner past the only sample is weighed.
        let f = try parse("<< /FunctionType 0 /Domain [0 1] /Range [0 1] /Size [1] /BitsPerSample 8 >>", [255])
        near(try eval(f, 0)[0], try eval(f, Double.nan)[0])
    }

    func test_sampledWithFewerSamplesThanSizeIsDamaged() {
        assertProblem(.damaged, try parse("<< /FunctionType 0 /Domain [0 1] /Range [0 1] /Size [100] /BitsPerSample 8 >>", [1, 2, 3]))
    }

    func test_sampledWithAHugeSizeIsDamagedNotAllocated() {
        assertProblem(.damaged, try parse("<< /FunctionType 0 /Domain [0 1 0 1 0 1] /Range [0 1] /Size [2000000 2000000 2000000] /BitsPerSample 32 >>", [1, 2, 3]))
    }

    func test_calculatorRunsArithmetic() throws {
        let wide = "[0 10]"
        near(0.25, try eval(try calculator("{ dup mul }"), 0.5)[0])
        near(3, try eval(try calculator("{ pop 7 2 idiv }", "[0 1]", wide), 0)[0])
        near(1, try eval(try calculator("{ pop 7 2 mod }", "[0 1]", wide), 0)[0])
        near(8, try eval(try calculator("{ pop 2 3 exp }", "[0 1]", wide), 0)[0])
        near(2, try eval(try calculator("{ pop 100 log }", "[0 1]", wide), 0)[0])
        near(3, try eval(try calculator("{ pop 2.5 round }", "[0 1]", wide), 0)[0])
        near(3, try eval(try calculator("{ pop 3.7 cvi }", "[0 1]", wide), 0)[0])
        near(2, try eval(try calculator("{ pop -2.5 truncate abs }", "[0 1]", wide), 0)[0])
        near(8, try eval(try calculator("{ pop 1 3 bitshift }", "[0 1]", wide), 0)[0])
        near(3, try eval(try calculator("{ pop 9 sqrt }", "[0 1]", wide), 0)[0])
        near(4, try eval(try calculator("{ pop 3.2 ceiling }", "[0 1]", wide), 0)[0])
        near(3, try eval(try calculator("{ pop 3.9 floor }", "[0 1]", wide), 0)[0])
        near(5, try eval(try calculator("{ pop 2 3 add }", "[0 1]", wide), 0)[0])
        near(6, try eval(try calculator("{ pop 2 3 mul }", "[0 1]", wide), 0)[0])
        near(2.5, try eval(try calculator("{ pop 5 2 div }", "[0 1]", wide), 0)[0])
        near(0, try eval(try calculator("{ pop 5 0 div }", "[0 1]", wide), 0)[0])
    }

    func test_calculatorTrigonometryIsInDegrees() throws {
        near(1, try eval(try calculator("{ 360 mul sin }", "[0 1]", "[-1 1]"), 0.25)[0], 1e-9)
        near(-1, try eval(try calculator("{ 360 mul cos }", "[0 1]", "[-1 1]"), 0.5)[0], 1e-9)
        near(1, try eval(try calculator("{ pop 1 0 atan 90 div }"), 0)[0])
        near(0.5, try eval(try calculator("{ pop 0 -1 atan 360 div }"), 0)[0])
    }

    func test_calculatorStackOperators() throws {
        let domain = "[0 1 0 1 0 1]"
        let range = "[0 1 0 1 0 1]"
        XCTAssertEqual(try eval(try calculator("{ 3 1 roll }", domain, range), 0.1, 0.2, 0.3), [0.3, 0.1, 0.2])
        XCTAssertEqual(try eval(try calculator("{ 3 -1 roll }", domain, range), 0.1, 0.2, 0.3), [0.2, 0.3, 0.1])
    }

    func test_calculatorIndexAndCopyGiveTheRightValues() throws {
        let two = "[0 1 0 1]"
        XCTAssertEqual(try eval(try calculator("{ 1 index }", two, "[0 1 0 1 0 1]"), 0.1, 0.2), [0.1, 0.2, 0.1])
        XCTAssertEqual(try eval(try calculator("{ 2 copy }", two, "[0 1 0 1 0 1 0 1]"), 0.1, 0.2), [0.1, 0.2, 0.1, 0.2])
        XCTAssertEqual(try eval(try calculator("{ exch }", two, two), 0.1, 0.2), [0.2, 0.1])
    }

    func test_calculatorBranches() throws {
        let f = try calculator("{ 0.5 gt { 1 } { 0 } ifelse }")
        near(1, try eval(f, 0.7)[0])
        near(0, try eval(f, 0.2)[0])
        let g = try calculator("{ dup 0.5 lt { pop 0 } if }")
        near(0, try eval(g, 0.3)[0])
        near(0.8, try eval(g, 0.8)[0])
    }

    func test_calculatorBooleans() throws {
        let two = "[0 1 0 1]"
        let both = try calculator("{ 0.5 gt exch 0.5 gt and { 1 } { 0 } ifelse }", two)
        near(1, try eval(both, 0.7, 0.9)[0])
        near(0, try eval(both, 0.7, 0.1)[0])
        let either = try calculator("{ 0.5 gt exch 0.5 gt or { 1 } { 0 } ifelse }", two)
        near(1, try eval(either, 0.7, 0.1)[0])
        near(0, try eval(either, 0.2, 0.1)[0])
        let differ = try calculator("{ 0.5 gt exch 0.5 gt xor { 1 } { 0 } ifelse }", two)
        near(1, try eval(differ, 0.7, 0.1)[0])
        near(0, try eval(differ, 0.7, 0.9)[0])
        let negated = try calculator("{ 0.5 gt not { 1 } { 0 } ifelse }")
        near(0, try eval(negated, 0.7)[0])
        near(1, try eval(negated, 0.2)[0])
        near(1, try eval(try calculator("{ pop true { 1 } { 0 } ifelse }"), 0)[0])
        near(0, try eval(try calculator("{ pop false { 1 } { 0 } ifelse }"), 0)[0])
        near(1, try eval(try calculator("{ pop 6 3 and 2 eq { 1 } { 0 } ifelse }"), 0)[0])
        near(1, try eval(try calculator("{ pop 4 1 or 5 eq { 1 } { 0 } ifelse }"), 0)[0])
        near(1, try eval(try calculator("{ pop 0 not -1 eq { 1 } { 0 } ifelse }"), 0)[0])
        near(1, try eval(try calculator("{ pop 1 2 ne 3 3 ge and 2 2 le and 1 2 lt and 3 2 gt and { 1 } { 0 } ifelse }"), 0)[0])
    }

    func test_calculatorIgnoresCommentsAndNewlines() throws {
        near(0.5, try eval(try calculator("% tint\n{\n  0.5 % half\n  mul 2\r  mul }"), 0.5)[0], 1e-9)
        near(0.2, try eval(try calculator("{ 0.5 mul 0.8 mul }"), 0.5)[0])
    }

    func test_calculatorClipsInputAndOutput() throws {
        let f = try calculator("{ 10 mul }")
        near(1, try eval(f, 0.9)[0])
        near(1, try eval(f, 50)[0])
    }

    func test_calculatorErrorsAreDamaged() {
        for program in ["{ pop pop }", "{ foo }", "{ 1 2", "1 2 }", "{ 1 if }", "{ 5 index }", "{ 2 copy 5 copy }", "{ exch }", "{ add }"] {
            assertProblem(.damaged, try eval(try calculator(program), 0.5))
        }
    }

    func test_calculatorStackIsLimited() {
        let program = "{ " + String(repeating: "dup ", count: 120) + " }"
        assertProblem(.damaged, try eval(try calculator(program), 0.5))
    }

    func test_calculatorNestingIsLimited() {
        let program = String(repeating: "{ ", count: 200) + String(repeating: "} ", count: 200)
        assertProblem(.damaged, try calculator(program))
    }

    func test_calculatorWithoutAStreamIsDamaged() {
        assertProblem(.damaged, try parse("<< /FunctionType 4 /Domain [0 1] /Range [0 1] >>"))
    }

    func test_anArrayOfFunctionsBehavesAsOne() throws {
        let f = try parse("[<< /FunctionType 2 /Domain [0 1] /N 1 >> << /FunctionType 2 /Domain [0 1] /C0 [1] /C1 [0] /N 1 >>]")
        XCTAssertEqual(f.outputs, 2)
        let y = try eval(f, 0.25)
        near(0.25, y[0])
        near(0.75, y[1])
    }

    func test_unknownTypeIsUnsupported() {
        assertProblem(.unsupported, try parse("<< /FunctionType 1 /Domain [0 1] >>"))
    }

    func test_malformedFunctionsAreDamaged() {
        for text in ["<< /FunctionType 2 >>", "<< /FunctionType 2 /Domain [0] >>", "<< /FunctionType 2 /Domain [/a /b] >>", "42", "[]"] {
            assertProblem(.damaged, try parse(text))
        }
    }
}
