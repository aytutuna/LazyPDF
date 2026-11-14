/* Copyright 2012 Mozilla Foundation
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import Foundation

// Twin of windows/LazyPDF.Core/Filters/Jbig2Huffman.cs. Ported to Swift from pdf.js (src/core/jbig2.js: Reader,
// HuffmanTable, decodeTablesSegment, getStandardTable) and changed: codes are assigned by B.3 for the standard
// tables too and decoded by length instead of through a tree, and prefix lengths, range lengths and line counts
// are checked.

/// Bits of a segment's data, most significant first; reading past its end is damage.
final class Jbig2Reader {
    private var shift = -1
    private var current = 0

    let data: [UInt8]

    /// The next byte to start on; with a byte only partly read it is the one after it.
    var position: Int

    var end: Int

    init(_ data: [UInt8], _ start: Int, _ end: Int) {
        self.data = data
        position = start
        self.end = min(end, data.count)
    }

    func readBit() throws -> Int {
        if shift < 0 {
            if position >= end { throw PdfReadException.damaged("A JBIG2 segment ends in the middle of its data.") }
            current = Int(data[position])
            position += 1
            shift = 7
        }
        let bit = (current >> shift) & 1
        shift -= 1
        return bit
    }

    /// Up to 32 bits as one number.
    func readBits(_ count: Int) throws -> Int {
        var result = 0
        for _ in 0..<count { result = (result << 1) | (try readBit()) }
        return result
    }

    func byteAlign() { shift = -1 }
}

/// One line of a table: the low end of a range, the length of its prefix, the offset bits after it, and the kind.
typealias Jbig2Line = (low: Int, prefixLength: Int, rangeLength: Int, kind: Int)

/// A prefix code table (Annex B) of values with a range of offset bits each, and maybe an out-of-band value.
final class Jbig2Huffman {
    private static let normal = 0, lower = 1, outOfBand = 3

    private static let maxPrefixLength = 32

    private static let maxCustomLines = 1 << 12

    private var low: [Int]
    private var rangeLength: [Int]
    private var kind: [Int]
    private var byLength: [Int]
    private var first: [Int]
    private var count: [Int]
    private var start: [Int]
    private var longest = 0

    /// The prefix code B.3 gives each line, for tests.
    private(set) var codes: [Int]

    /// Lines of (range low, prefix length, range length, kind); a line with prefix length 0 is not used.
    init(_ lines: [Jbig2Line]) throws {
        let n = lines.count
        let maxPrefix = Jbig2Huffman.maxPrefixLength
        low = [Int](repeating: 0, count: n)
        rangeLength = [Int](repeating: 0, count: n)
        kind = [Int](repeating: 0, count: n)
        var counts = [Int](repeating: 0, count: maxPrefix + 1)
        for i in 0..<n {
            if lines[i].prefixLength < 0 || lines[i].prefixLength > maxPrefix || lines[i].rangeLength < 0 || lines[i].rangeLength > 32 {
                throw PdfReadException.damaged("A JBIG2 Huffman table has a code length out of range.")
            }
            low[i] = lines[i].low
            rangeLength[i] = lines[i].rangeLength
            kind[i] = lines[i].kind
            counts[lines[i].prefixLength] += 1
            longest = max(longest, lines[i].prefixLength)
        }
        counts[0] = 0
        count = counts
        first = [Int](repeating: 0, count: maxPrefix + 1)
        start = [Int](repeating: 0, count: maxPrefix + 1)
        // B.3: codes of one length are consecutive, in the order of the lines.
        var firstCode = 0
        var at = 0
        if longest >= 1 {
            for length in 1...longest {
                firstCode = (firstCode + counts[length - 1]) << 1
                if firstCode + counts[length] > 1 << length { throw PdfReadException.damaged("A JBIG2 Huffman table has more codes than fit.") }
                first[length] = firstCode
                start[length] = at
                at += counts[length]
            }
        }
        byLength = [Int](repeating: 0, count: at)
        codes = [Int](repeating: 0, count: n)
        var next = [Int](repeating: 0, count: maxPrefix + 1)
        for i in 0..<n {
            let length = lines[i].prefixLength
            if length == 0 { continue }
            byLength[start[length] + next[length]] = i
            codes[i] = first[length] + next[length]
            next[length] += 1
        }
    }

    /// A value, or nil for the out-of-band value.
    func decode(_ reader: Jbig2Reader) throws -> Int? {
        var code = 0
        var length = 1
        while length <= longest {
            code = (code << 1) | (try reader.readBit())
            let index = code - first[length]
            if index >= 0 && index < count[length] {
                let line = byLength[start[length] + index]
                if kind[line] == Jbig2Huffman.outOfBand { return nil }
                let offset = try reader.readBits(rangeLength[line])
                let result = kind[line] == Jbig2Huffman.lower ? low[line] - offset : low[line] + offset
                if result < Int(Int32.min) || result > Int(Int32.max) { throw PdfReadException.damaged("A JBIG2 Huffman value is out of range.") }
                return result
            }
            length += 1
        }
        throw PdfReadException.damaged("A JBIG2 Huffman code is not in its table.")
    }

    /// B.2: the table a tables segment holds.
    static func custom(_ data: [UInt8], _ start: Int, _ end: Int) throws -> Jbig2Huffman {
        if end - start < 9 { throw PdfReadException.damaged("A JBIG2 tables segment is cut off.") }
        let flags = Int(data[start])
        func signed(_ at: Int) -> Int {
            Int(Int32(bitPattern: UInt32(data[at]) << 24 | UInt32(data[at + 1]) << 16 | UInt32(data[at + 2]) << 8 | UInt32(data[at + 3])))
        }
        let lowest = signed(start + 1)
        let highest = signed(start + 5)
        let reader = Jbig2Reader(data, start + 9, end)
        let prefixBits = ((flags >> 1) & 7) + 1
        let rangeBits = ((flags >> 4) & 7) + 1
        var lines: [Jbig2Line] = []
        var current = lowest
        repeat {
            let prefix = try reader.readBits(prefixBits)
            let range = try reader.readBits(rangeBits)
            if range > 32 { throw PdfReadException.damaged("A JBIG2 Huffman table has a range out of range.") }
            lines.append((current, prefix, range, normal))
            if lines.count > maxCustomLines { throw Jbig2Budget.tooBig() }
            current += 1 << range
        } while current < highest
        let lowerPrefix = try reader.readBits(prefixBits)
        lines.append((lowest - 1, lowerPrefix, 32, lower))
        let upperPrefix = try reader.readBits(prefixBits)
        lines.append((highest, upperPrefix, 32, normal))
        if flags & 1 != 0 { lines.append((0, try reader.readBits(prefixBits), 0, outOfBand)) }
        return try Jbig2Huffman(lines)
    }

    /// The table of the symbol ids of a text region (7.4.3.1.7): symbol i has a code of `lengths[i]` bits.
    static func forLengths(_ lengths: [Int]) throws -> Jbig2Huffman {
        var lines: [Jbig2Line] = []
        lines.reserveCapacity(lengths.count)
        for i in 0..<lengths.count { lines.append((i, lengths[i], 0, normal)) }
        return try Jbig2Huffman(lines)
    }

    private static let standardTables: [Jbig2Huffman] = standardLines.map { lines in
        // The lines are fixed and valid.
        try! Jbig2Huffman(lines)
    }

    /// Table B.`number`, 1 to 15.
    static func standard(_ number: Int) -> Jbig2Huffman { standardTables[number - 1] }

    /// The lines of a standard table, for tests.
    static func standardTable(_ number: Int) -> [Jbig2Line] { standardLines[number - 1] }

    // Annex B.5: (range low, prefix length, range length, kind) for each line in the order of the standard, with the
    // lower range line as kind 1 and the out-of-band line as kind 3. The last range of a table has 32 offset bits.
    private static let standardLines: [[Jbig2Line]] = [
        // B.1
        [
            (0, 1, 4, 0), (16, 2, 8, 0), (272, 3, 16, 0), (65808, 3, 32, 0),
        ],
        // B.2
        [
            (0, 1, 0, 0), (1, 2, 0, 0), (2, 3, 0, 0), (3, 4, 3, 0), (11, 5, 6, 0), (75, 6, 32, 0), (0, 6, 0, 3),
        ],
        // B.3
        [
            (-256, 8, 8, 0), (0, 1, 0, 0), (1, 2, 0, 0), (2, 3, 0, 0), (3, 4, 3, 0), (11, 5, 6, 0), (-257, 8, 32, 1),
            (75, 7, 32, 0), (0, 6, 0, 3),
        ],
        // B.4
        [
            (1, 1, 0, 0), (2, 2, 0, 0), (3, 3, 0, 0), (4, 4, 3, 0), (12, 5, 6, 0), (76, 5, 32, 0),
        ],
        // B.5
        [
            (-255, 7, 8, 0), (1, 1, 0, 0), (2, 2, 0, 0), (3, 3, 0, 0), (4, 4, 3, 0), (12, 5, 6, 0), (-256, 7, 32, 1),
            (76, 6, 32, 0),
        ],
        // B.6
        [
            (-2048, 5, 10, 0), (-1024, 4, 9, 0), (-512, 4, 8, 0), (-256, 4, 7, 0), (-128, 5, 6, 0), (-64, 5, 5, 0),
            (-32, 4, 5, 0), (0, 2, 7, 0), (128, 3, 7, 0), (256, 3, 8, 0), (512, 4, 9, 0), (1024, 4, 10, 0),
            (-2049, 6, 32, 1), (2048, 6, 32, 0),
        ],
        // B.7
        [
            (-1024, 4, 9, 0), (-512, 3, 8, 0), (-256, 4, 7, 0), (-128, 5, 6, 0), (-64, 5, 5, 0), (-32, 4, 5, 0),
            (0, 4, 5, 0), (32, 5, 5, 0), (64, 5, 6, 0), (128, 4, 7, 0), (256, 3, 8, 0), (512, 3, 9, 0),
            (1024, 3, 10, 0), (-1025, 5, 32, 1), (2048, 5, 32, 0),
        ],
        // B.8
        [
            (-15, 8, 3, 0), (-7, 9, 1, 0), (-5, 8, 1, 0), (-3, 9, 0, 0), (-2, 7, 0, 0), (-1, 4, 0, 0), (0, 2, 1, 0),
            (2, 5, 0, 0), (3, 6, 0, 0), (4, 3, 4, 0), (20, 6, 1, 0), (22, 4, 4, 0), (38, 4, 5, 0), (70, 5, 6, 0),
            (134, 5, 7, 0), (262, 6, 7, 0), (390, 7, 8, 0), (646, 6, 10, 0), (-16, 9, 32, 1), (1670, 9, 32, 0),
            (0, 2, 0, 3),
        ],
        // B.9
        [
            (-31, 8, 4, 0), (-15, 9, 2, 0), (-11, 8, 2, 0), (-7, 9, 1, 0), (-5, 7, 1, 0), (-3, 4, 1, 0),
            (-1, 3, 1, 0), (1, 3, 1, 0), (3, 5, 1, 0), (5, 6, 1, 0), (7, 3, 5, 0), (39, 6, 2, 0), (43, 4, 5, 0),
            (75, 4, 6, 0), (139, 5, 7, 0), (267, 5, 8, 0), (523, 6, 8, 0), (779, 7, 9, 0), (1291, 6, 11, 0),
            (-32, 9, 32, 1), (3339, 9, 32, 0), (0, 2, 0, 3),
        ],
        // B.10
        [
            (-21, 7, 4, 0), (-5, 8, 0, 0), (-4, 7, 0, 0), (-3, 5, 0, 0), (-2, 2, 2, 0), (2, 5, 0, 0), (3, 6, 0, 0),
            (4, 7, 0, 0), (5, 8, 0, 0), (6, 2, 6, 0), (70, 5, 5, 0), (102, 6, 5, 0), (134, 6, 6, 0), (198, 6, 7, 0),
            (326, 6, 8, 0), (582, 6, 9, 0), (1094, 6, 10, 0), (2118, 7, 11, 0), (-22, 8, 32, 1), (4166, 8, 32, 0),
            (0, 2, 0, 3),
        ],
        // B.11
        [
            (1, 1, 0, 0), (2, 2, 1, 0), (4, 4, 0, 0), (5, 4, 1, 0), (7, 5, 1, 0), (9, 5, 2, 0), (13, 6, 2, 0),
            (17, 7, 2, 0), (21, 7, 3, 0), (29, 7, 4, 0), (45, 7, 5, 0), (77, 7, 6, 0), (141, 7, 32, 0),
        ],
        // B.12
        [
            (1, 1, 0, 0), (2, 2, 0, 0), (3, 3, 1, 0), (5, 5, 0, 0), (6, 5, 1, 0), (8, 6, 1, 0), (10, 7, 0, 0),
            (11, 7, 1, 0), (13, 7, 2, 0), (17, 7, 3, 0), (25, 7, 4, 0), (41, 8, 5, 0), (73, 8, 32, 0),
        ],
        // B.13
        [
            (1, 1, 0, 0), (2, 3, 0, 0), (3, 4, 0, 0), (4, 5, 0, 0), (5, 4, 1, 0), (7, 3, 3, 0), (15, 6, 1, 0),
            (17, 6, 2, 0), (21, 6, 3, 0), (29, 6, 4, 0), (45, 6, 5, 0), (77, 7, 6, 0), (141, 7, 32, 0),
        ],
        // B.14
        [
            (-2, 3, 0, 0), (-1, 3, 0, 0), (0, 1, 0, 0), (1, 3, 0, 0), (2, 3, 0, 0),
        ],
        // B.15
        [
            (-24, 7, 4, 0), (-8, 6, 2, 0), (-4, 5, 1, 0), (-2, 4, 0, 0), (-1, 3, 0, 0), (0, 1, 0, 0), (1, 3, 0, 0),
            (2, 4, 0, 0), (3, 5, 1, 0), (5, 6, 2, 0), (9, 7, 4, 0), (-25, 7, 32, 1), (25, 7, 32, 0),
        ],
    ]
}
