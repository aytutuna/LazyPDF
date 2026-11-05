import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Filters/FilterFixtures.cs: the same helpers. Random bytes come from a
// port of System.Random(seed), so a test reads the bytes the Windows test reads.

/// System.Random with a seed: the subtractive generator of Knuth's, as .NET keeps it for seeded instances.
struct DotNetRandom {
    private var seeds = [Int32](repeating: 0, count: 56)
    private var inext = 0
    private var inextp = 21

    init(_ seed: Int) {
        let subtraction: Int32 = seed == Int(Int32.min) ? Int32.max : Int32(abs(seed))
        var mj: Int32 = 161_803_398 &- subtraction
        seeds[55] = mj
        var mk: Int32 = 1
        var ii = 0
        for _ in 1..<55 {
            ii += 21
            if ii >= 55 { ii -= 55 }
            seeds[ii] = mk
            mk = mj &- mk
            if mk < 0 { mk = mk &+ Int32.max }
            mj = seeds[ii]
        }
        for _ in 1..<5 {
            for i in 1..<56 {
                var n = i + 30
                if n >= 55 { n -= 55 }
                seeds[i] = seeds[i] &- seeds[1 + n]
                if seeds[i] < 0 { seeds[i] = seeds[i] &+ Int32.max }
            }
        }
    }

    private mutating func internalSample() -> Int32 {
        var a = inext + 1
        if a >= 56 { a = 1 }
        var b = inextp + 1
        if b >= 56 { b = 1 }
        var result = seeds[a] &- seeds[b]
        if result == Int32.max { result -= 1 }
        if result < 0 { result = result &+ Int32.max }
        seeds[a] = result
        inext = a
        inextp = b
        return result
    }

    mutating func next(_ maxValue: Int) -> Int {
        Int(Double(internalSample()) * (1.0 / Double(Int32.max)) * Double(maxValue))
    }

    mutating func nextBytes(_ count: Int) -> [UInt8] {
        (0..<count).map { _ in UInt8(truncatingIfNeeded: internalSample()) }
    }
}

enum FilterFixtures {
    static func parse(_ text: String) throws -> PdfObject {
        try PdfLexer(PdfArrayBytes(Latin1.bytes(text))).readObject()
    }

    static func dict(_ text: String) throws -> PdfDictionary {
        let object = try parse(text)
        return try XCTUnwrap(object as? PdfDictionary)
    }

    static func resolve(_ value: PdfObject?) -> PdfObject? { value }

    /// Streams made for a test with the data a decoder would give back for them.
    final class Streams {
        private var data: [ObjectIdentifier: [UInt8]] = [:]

        func add(_ dictionary: String, _ bytes: [UInt8]) throws -> PdfStream {
            let stream = PdfStream(try dict(dictionary), dataOffset: 0)
            data[ObjectIdentifier(stream)] = bytes
            return stream
        }

        func decode(_ stream: PdfStream) -> [UInt8] {
            guard let bytes = data[ObjectIdentifier(stream)] else {
                XCTFail("a stream this test did not make")
                return []
            }
            return bytes
        }
    }

    static func randomBytes(_ length: Int, _ seed: Int = 1) -> [UInt8] {
        var random = DotNetRandom(seed)
        return random.nextBytes(length)
    }

    /// Bytes that compress and still vary.
    static func text(_ length: Int) -> [UInt8] {
        var random = DotNetRandom(7)
        return (0..<length).map { _ in UInt8(ascii: "a") + UInt8(random.next(6)) }
    }
}

/// Assert.Throws<PdfReadException> and a check of its Problem.
func assertProblem<T>(_ problem: PdfReadProblem, _ expression: @autoclosure () throws -> T, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertThrowsError(try expression(), file: file, line: line) { error in
        XCTAssertEqual((error as? PdfReadException)?.problem, problem, file: file, line: line)
    }
}
