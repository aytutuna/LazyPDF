import Foundation

// Twin of windows/LazyPDF.Core/Filters/Ccitt.cs: CCITTFaxDecode (ISO 32000-1 7.4.6; ITU-T T.4 and T.6).
// K below zero is Group 4, zero is Group 3 one-dimensional, above zero is Group 3 with a tag bit after each
// EOL choosing one or two dimensions for the next row. EOLs are accepted whether or not /EndOfLine says
// they are there.

enum Ccitt {
    /// Rows of packed pixels, each starting on a byte boundary, white 1 unless `blackIs1`.
    /// A bad code ends a Group 4 stream; Group 3 skips to the next EOL. With `rows` known, missing rows are white.
    static func decode(_ data: [UInt8], _ k: Int, _ columns: Int, _ rows: Int, _ byteAlign: Bool, _ endOfLine: Bool, _ blackIs1: Bool, _ maxSize: Int) throws -> [UInt8] {
        let stride = (columns + 7) / 8
        if rows > 0 && rows * stride > maxSize { throw FilterBuffer.tooBig() }
        let output = FilterBuffer(maxSize, capacity: rows > 0 ? rows * stride : data.count * 4)
        let white: UInt8 = blackIs1 ? 0 : 0xFF
        var rowBytes = [UInt8](repeating: 0, count: stride)
        var reference = [Int](repeating: 0, count: columns + 2)
        var coding = [Int](repeating: 0, count: columns + 2)
        var referenceCount = 0, done = 0
        var bits = BitReader(data)
        var resynced = false

        while rows == 0 || done < rows {
            // With EOLs the fill bits that align the row sit in front of the EOL, which then ends on the boundary.
            let aligned = byteAlign && !resynced
            if aligned && !endOfLine { bits.align() }
            resynced = false
            var eols = 0, tag = -1
            while bits.tryEol() {
                eols += 1
                if k > 0 { tag = bits.read1() }
            }
            if eols == 0 && aligned && endOfLine { bits.align() }
            if bits.atEnd || eols >= 2 || (k < 0 && eols > 0) { break }

            let twoD = k < 0 || (k > 0 && (tag >= 0 ? tag == 0 : done > 0))
            let start = bits.position
            var count = 0
            let ok = twoD
                ? decodeRow2D(&bits, reference, referenceCount, &coding, &count, columns)
                : decodeRow1D(&bits, &coding, &count, columns)
            // Padding bits after the last row are not a row.
            if !ok && bits.position == start && bits.restIsZero() { break }

            rowBytes = [UInt8](repeating: white, count: stride)
            var i = 0
            while i < count {
                fillBlack(&rowBytes, coding[i], i + 1 < count ? coding[i + 1] : columns, blackIs1)
                i += 2
            }
            try output.add(rowBytes)
            done += 1
            swap(&reference, &coding)
            referenceCount = count

            if ok { continue }
            if k < 0 { break }
            bits.skipToEol()
            resynced = true
            // Nothing sound to predict the next row from.
            referenceCount = 0
        }
        if rows > done { try output.append((rows - done) * stride, filling: white) }
        return output.toArray()
    }

    /// One-dimensional row: alternating white and black runs. The changing elements go to `changes`.
    private static func decodeRow1D(_ bits: inout BitReader, _ changes: inout [Int], _ count: inout Int, _ columns: Int) -> Bool {
        var position = 0
        var black = false
        while position < columns {
            let run = readRun(&bits, black, columns)
            if run < 0 || count >= changes.count - 1 { return false }
            position = min(position + run, columns)
            if position < columns {
                changes[count] = position
                count += 1
            }
            black.toggle()
        }
        return true
    }

    /// Two-dimensional row (T.6): a0 is the last coded position, b1 the first changing element of
    /// the reference row right of a0 and of the colour opposite a0's, b2 the one after it.
    private static func decodeRow2D(_ bits: inout BitReader, _ reference: [Int], _ referenceCount: Int, _ changes: inout [Int], _ count: inout Int, _ columns: Int) -> Bool {
        var a0 = -1, ib = 0
        var black = false
        while a0 < columns {
            while ib < referenceCount && reference[ib] <= a0 { ib += 1 }
            var index = ib
            if index < referenceCount && (index % 2 == 0) == black { index += 1 }
            let b1 = index < referenceCount ? reference[index] : columns
            let b2 = index + 1 < referenceCount ? reference[index + 1] : columns

            let mode = bits.peek(7)
            let offset: Int
            if mode >> 6 == 1 {
                bits.skip(1)
                offset = 0
            } else if mode >> 4 == 0b011 {
                bits.skip(3)
                offset = 1
            } else if mode >> 4 == 0b010 {
                bits.skip(3)
                offset = -1
            } else if mode >> 4 == 0b001 {
                bits.skip(3)
                let first = readRun(&bits, black, columns)
                let second = first < 0 ? -1 : readRun(&bits, !black, columns)
                if second < 0 || count >= changes.count - 2 { return false }
                let a1 = min(max(a0, 0) + first, columns)
                let a2 = min(a1 + second, columns)
                if a1 < columns {
                    changes[count] = a1
                    count += 1
                }
                if a2 < columns {
                    changes[count] = a2
                    count += 1
                }
                a0 = a2
                continue
            } else if mode >> 3 == 0b0001 {
                bits.skip(4)
                a0 = b2
                continue
            } else if mode >> 1 == 0b000011 {
                bits.skip(6)
                offset = 2
            } else if mode >> 1 == 0b000010 {
                bits.skip(6)
                offset = -2
            } else if mode == 0b0000011 {
                bits.skip(7)
                offset = 3
            } else if mode == 0b0000010 {
                bits.skip(7)
                offset = -3
            } else {
                return false
            }

            let a1 = b1 + offset
            if a1 > columns || a1 < max(a0, 0) || (a1 == a0 && a0 >= 0) { return false }
            if a1 < columns {
                if count >= changes.count - 2 { return false }
                changes[count] = a1
                count += 1
            }
            a0 = a1
            black.toggle()
        }
        return true
    }

    /// A run of one colour: make-up codes then a terminating code. -1 for a code that does not exist.
    private static func readRun(_ bits: inout BitReader, _ black: Bool, _ columns: Int) -> Int {
        let table = black ? CcittCodes.black : CcittCodes.white
        var total = 0
        while true {
            let entry = table[bits.peek(13)]
            if entry == 0 { return -1 }
            bits.skip(entry & 15)
            let run = entry >> 4
            total += run
            if run < 64 { return total }
            if total > columns { return -1 }
        }
    }

    private static func fillBlack(_ row: inout [UInt8], _ from: Int, _ to: Int, _ blackIs1: Bool) {
        var x = from
        while x < to {
            if x & 7 == 0 && to - x >= 8 {
                row[x >> 3] = blackIs1 ? 0xFF : 0
                x += 8
                continue
            }
            let bit = UInt8(0x80 >> (x & 7))
            if blackIs1 { row[x >> 3] |= bit } else { row[x >> 3] &= ~bit }
            x += 1
        }
    }

    private struct BitReader {
        private let data: [UInt8]
        private let end: Int
        private(set) var position = 0

        init(_ data: [UInt8]) {
            self.data = data
            end = data.count * 8
        }

        var atEnd: Bool { position >= end }

        mutating func skip(_ count: Int) { position += count }

        mutating func align() { position = (position + 7) & ~7 }

        /// The next `count` bits (24 at most); zeros past the end.
        func peek(_ count: Int) -> Int {
            let index = position >> 3
            var value: UInt32 = 0
            for i in 0..<4 { value = value << 8 | (index + i < data.count ? UInt32(data[index + i]) : 0) }
            return Int((value >> UInt32(32 - (position & 7) - count)) & ((1 << UInt32(count)) - 1))
        }

        mutating func read1() -> Int {
            let bit = peek(1)
            position += 1
            return bit
        }

        private func bit(_ at: Int) -> Int {
            Int(data[at >> 3] >> UInt8(7 - (at & 7))) & 1
        }

        /// Takes an EOL: at least 11 zeros, fill bits included, then a one. Anything else is left alone.
        mutating func tryEol() -> Bool {
            var at = position
            while at < end && bit(at) == 0 { at += 1 }
            if at - position < 11 { return false }
            if at >= end {
                position = end
                return false
            }
            position = at + 1
            return true
        }

        func restIsZero() -> Bool {
            var at = position
            while at < end {
                if bit(at) != 0 { return false }
                at += 1
            }
            return true
        }

        /// Moves to the next EOL, or the end.
        mutating func skipToEol() {
            while !atEnd && peek(12) != 1 { position += 1 }
        }
    }
}
