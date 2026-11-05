import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Filters/PredictorTests.cs: the same cases. Assert.Same on a byte array
// (the data comes back untouched) is an equality check here: an array is a value.

final class PredictorTests: XCTestCase {
    private func parms(_ predictor: Int, _ colors: Int, _ bits: Int, _ columns: Int) throws -> PdfDictionary {
        try FilterFixtures.dict("<< /Predictor \(predictor) /Colors \(colors) /BitsPerComponent \(bits) /Columns \(columns) >>")
    }

    private func rowLength(_ colors: Int, _ bits: Int, _ columns: Int) -> Int { (colors * bits * columns + 7) / 8 }

    /// The PNG filters applied the way an encoder does, row type cycling through 0 to 4.
    private func pngEncode(_ raw: [UInt8], _ rowLength: Int, _ bpp: Int, _ typeOf: (Int) -> Int) -> [UInt8] {
        let rows = raw.count / rowLength
        var output = [UInt8](repeating: 0, count: rows * (rowLength + 1))
        for y in 0..<rows {
            let type = typeOf(y)
            output[y * (rowLength + 1)] = UInt8(type)
            for i in 0..<rowLength {
                let a = i >= bpp ? Int(raw[y * rowLength + i - bpp]) : 0
                let b = y > 0 ? Int(raw[(y - 1) * rowLength + i]) : 0
                let c = i >= bpp && y > 0 ? Int(raw[(y - 1) * rowLength + i - bpp]) : 0
                let p = a + b - c
                let pa = abs(p - a), pb = abs(p - b), pc = abs(p - c)
                let paeth = pa <= pb && pa <= pc ? a : pb <= pc ? b : c
                let x = Int(raw[y * rowLength + i])
                let value: Int
                switch type {
                case 0: value = x
                case 1: value = x - a
                case 2: value = x - b
                case 3: value = x - (a + b) / 2
                default: value = x - paeth
                }
                output[y * (rowLength + 1) + 1 + i] = UInt8(truncatingIfNeeded: value)
            }
        }
        return output
    }

    func test_pngPredictorUndoesEveryRowFilter() throws {
        let cases = [(1, 1, 37), (1, 2, 21), (1, 4, 13), (1, 8, 30), (1, 16, 9), (3, 1, 11), (3, 4, 7), (3, 8, 20), (3, 16, 5), (4, 8, 16), (4, 2, 9)]
        for (colors, bits, columns) in cases {
            let length = rowLength(colors, bits, columns)
            let raw = FilterFixtures.randomBytes(length * 11, colors * 100 + bits)
            let encoded = pngEncode(raw, length, max(1, (colors * bits + 7) / 8)) { $0 % 5 }
            XCTAssertEqual(try PdfFilters.predict(encoded, try parms(15, colors, bits, columns)), raw, "\(colors) \(bits) \(columns)")
        }
    }

    func test_predictorOneAndAbsentLeaveDataAlone() throws {
        let data: [UInt8] = [1, 2, 3]
        XCTAssertEqual(try PdfFilters.predict(data, nil), data)
        XCTAssertEqual(try PdfFilters.predict(data, try FilterFixtures.dict("<< /Predictor 1 >>")), data)
    }

    func test_lastPngRowCutShortIsKeptAsFarAsItGoes() throws {
        let length = rowLength(3, 8, 10)
        let raw = FilterFixtures.randomBytes(length * 4, 5)
        let encoded = pngEncode(raw, length, 3) { _ in 2 }
        let cut = Array(encoded.dropLast(7))
        XCTAssertEqual(try PdfFilters.predict(cut, try parms(12, 3, 8, 10)), Array(raw.dropLast(7)))
        XCTAssertEqual(try PdfFilters.predict(Array(encoded.dropLast(length - 1)), try parms(12, 3, 8, 10)), Array(raw.dropLast(length - 1)))
    }

    func test_unknownPngRowFilterLeavesTheRowAsItIs() throws {
        let encoded: [UInt8] = [9, 5, 6, 7]
        XCTAssertEqual(try PdfFilters.predict(encoded, try parms(15, 1, 8, 3)), [5, 6, 7])
    }

    func test_columnsLargerThanTheDataDoNotAllocateTheirSize() throws {
        let encoded: [UInt8] = [1, 5, 6, 7]
        XCTAssertEqual(try PdfFilters.predict(encoded, try parms(15, 1, 16, 1 << 30)), [5, 6, 12])
    }

    func test_tiffPredictorUndoesHorizontalDifferencing() throws {
        let cases = [(1, 1, 50), (1, 2, 19), (1, 4, 15), (1, 8, 20), (1, 16, 9), (3, 1, 13), (3, 2, 10), (3, 4, 9), (3, 8, 17), (4, 16, 6)]
        for (colors, bits, columns) in cases {
            let length = rowLength(colors, bits, columns)
            let raw = FilterFixtures.randomBytes(length * 6, bits * 10 + colors)
            var encoded = raw
            for y in 0..<6 {
                for j in stride(from: columns * colors - 1, through: colors, by: -1) {
                    let diff = get(raw, y * length, j, bits) - get(raw, y * length, j - colors, bits)
                    set(&encoded, y * length, j, bits, diff)
                }
            }
            // Trailing pad bits of a row are not components and stay as they were.
            XCTAssertEqual(try PdfFilters.predict(encoded, try parms(2, colors, bits, columns)), raw, "\(colors) \(bits) \(columns)")
        }
    }

    private func get(_ data: [UInt8], _ start: Int, _ index: Int, _ bits: Int) -> Int {
        if bits == 16 { return Int(data[start + index * 2]) << 8 | Int(data[start + index * 2 + 1]) }
        if bits == 8 { return Int(data[start + index]) }
        let bit = index * bits
        return Int(data[start + bit / 8]) >> (8 - bits - bit % 8) & ((1 << bits) - 1)
    }

    private func set(_ data: inout [UInt8], _ start: Int, _ index: Int, _ bits: Int, _ value: Int) {
        if bits == 16 {
            data[start + index * 2] = UInt8(truncatingIfNeeded: value >> 8)
            data[start + index * 2 + 1] = UInt8(truncatingIfNeeded: value)
        } else if bits == 8 {
            data[start + index] = UInt8(truncatingIfNeeded: value)
        } else {
            let bit = index * bits, shift = 8 - bits - bit % 8, mask = (1 << bits) - 1
            data[start + bit / 8] = UInt8(truncatingIfNeeded: Int(data[start + bit / 8]) & ~(mask << shift) | (value & mask) << shift)
        }
    }

    func test_bitsPerComponentOutsideTheSetIsDamaged() throws {
        assertProblem(.damaged, try PdfFilters.predict([1, 2, 3], try parms(15, 1, 3, 1)))
    }

    func test_predictorsBetweenThreeAndNineAreUnsupported() throws {
        assertProblem(.unsupported, try PdfFilters.predict([1, 2, 3], try parms(5, 1, 8, 1)))
    }

    func test_predictorRunsAfterFlateInAChain() throws {
        let length = rowLength(3, 8, 8)
        let raw = FilterFixtures.randomBytes(length * 8, 12)
        let stored = PdfFilterEncoders.flate(pngEncode(raw, length, 3) { _ in 4 })
        XCTAssertEqual(try PdfFilters.decode(stored, try FilterFixtures.parse("/FlateDecode"), try parms(15, 3, 8, 8)), raw)
    }

    func test_parametersThatOverflowAreDamagedNotArithmeticErrors() throws {
        for (predictor, colors, bits, columns) in [(2, 1073741824, 16, 1), (12, 1073741823, 16, 1073741825)] {
            assertProblem(.damaged, try PdfFilters.predict([1, 2, 3, 4], try parms(predictor, colors, bits, columns)))
        }
    }
}
