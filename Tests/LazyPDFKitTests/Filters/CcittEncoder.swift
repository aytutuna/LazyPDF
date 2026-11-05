import Foundation

// Mirrors windows/LazyPDF.Core.Tests/Filters/CcittEncoder.cs, from Lazy Scan's CcittG4Encoder.cs, with Group 3
// rows added. A second, independent way to make CCITT data for the decoder tests.

/// CCITT Group 4 (ITU-T T.6) encoding of a black & white image: the two-dimensional coding of each row against
/// the row above it (an imaginary white row above the first), with pass, horizontal and vertical modes, ending
/// in EOFB and zero bits up to a byte boundary. No EOLs, no byte alignment of rows, bits written most
/// significant first (TIFF FillOrder 1). Rows are coded as libtiff codes them, mode for mode.
enum CcittEncoder {
    /// The image (packed rows, (width + 7) / 8 bytes each, most significant bit first, 0 = black) as G4 data.
    static func encode(_ packed: [UInt8], _ width: Int, _ height: Int) -> [UInt8] {
        precondition(width >= 1, "width")
        precondition(height >= 0, "height")
        let stride = (width + 7) / 8
        precondition(packed.count >= stride * height, "Packed buffer must be \(stride * height) bytes, got \(packed.count).")

        var bits = BitWriter()
        // The changing elements of the reference row and the coding row: each position where a
        // pixel's color differs from the pixel before it (white before the first). Even entries
        // start black runs, odd entries white ones.
        var reference = [Int](repeating: 0, count: width + 1)
        var coding = [Int](repeating: 0, count: width + 1)
        var referenceCount = 0
        for y in 0..<height {
            let codingCount = changingElements(packed, y * stride, width, &coding)
            encodeRow(&bits, coding, codingCount, reference, referenceCount, width)
            swap(&reference, &coding)
            referenceCount = codingCount
        }
        // EOFB: two EOLs.
        bits.write(0x001, 12)
        bits.write(0x001, 12)
        return bits.toArray()
    }

    /// Group 3: K 0 codes every row alone, K above 0 codes a row alone, then K - 1 rows against the one above.
    /// With `eol` an EOL (and for K above 0 the tag bit) goes before each row and six at the end; with `align`
    /// rows (or the EOLs, which end on a byte) are byte aligned.
    static func encodeG3(_ packed: [UInt8], _ width: Int, _ height: Int, _ k: Int, eol: Bool, align: Bool) -> [UInt8] {
        let stride = (width + 7) / 8
        var bits = BitWriter()
        var reference = [Int](repeating: 0, count: width + 1)
        var coding = [Int](repeating: 0, count: width + 1)
        var referenceCount = 0
        for y in 0..<height {
            let oneD = k == 0 || y % k == 0
            if eol {
                if align { bits.padTo(k > 0 ? 13 : 12) }
                bits.write(0x001, 12)
                if k > 0 { bits.write(oneD ? 1 : 0, 1) }
            } else if align {
                bits.padTo(0)
            }
            let codingCount = changingElements(packed, y * stride, width, &coding)
            if oneD {
                var position = 0
                var black = false
                for i in 0..<codingCount {
                    writeRun(&bits, coding[i] - position, black)
                    position = coding[i]
                    black.toggle()
                }
                writeRun(&bits, width - position, black)
            } else {
                encodeRow(&bits, coding, codingCount, reference, referenceCount, width)
            }
            swap(&reference, &coding)
            referenceCount = codingCount
        }
        if eol {
            for _ in 0..<6 {
                bits.write(0x001, 12)
                if k > 0 { bits.write(1, 1) }
            }
        }
        return bits.toArray()
    }

    /// Fills `changes` with the row's changing elements; returns how many.
    private static func changingElements(_ packed: [UInt8], _ start: Int, _ width: Int, _ changes: inout [Int]) -> Int {
        var count = 0
        var black = false
        for x in 0..<width {
            let pixel = (Int(packed[start + (x >> 3)]) & (0x80 >> (x & 7))) == 0
            if pixel != black {
                changes[count] = x
                count += 1
                black = pixel
            }
        }
        return count
    }

    /// One row in T.6's two-dimensional coding. a0 starts on an imaginary white pixel before the
    /// row; a1 and a2 are the next changing elements of the coding row, b1 the first changing
    /// element of the reference row right of a0 and of the color opposite a0's, b2 the next one.
    private static func encodeRow(_ bits: inout BitWriter, _ coding: [Int], _ codingCount: Int,
                                  _ reference: [Int], _ referenceCount: Int, _ width: Int) {
        var a0 = -1
        var black = false // the color of a0
        var ia = 0, ib = 0
        while true {
            while ia < codingCount && coding[ia] <= a0 { ia += 1 }
            let a1 = ia < codingCount ? coding[ia] : width

            // Changing elements alternate in color, so b1 is the first one right of a0 or the
            // one after it. Only those at or left of a0 are skipped for good: one of the wrong
            // color can be b1 again once a vertical mode has changed a0's color.
            while ib < referenceCount && reference[ib] <= a0 { ib += 1 }
            var k = ib
            // Even entries are black; b1 has the color opposite a0's.
            if k < referenceCount && (k % 2 == 0) == black { k += 1 }
            let b1 = k < referenceCount ? reference[k] : width
            let b2 = k + 1 < referenceCount ? reference[k + 1] : width

            if b2 < a1 {
                // Pass mode: a0 moves under b2 and keeps its color.
                bits.write(passCode, passLength)
                a0 = b2
            } else if abs(a1 - b1) <= 3 {
                // Vertical mode: a1 is coded by its distance from b1.
                let (code, length) = vertical[a1 - b1 + 3]
                bits.write(code, length)
                a0 = a1
                black.toggle()
            } else {
                // Horizontal mode: the run from a0 to a1 in a0's color, then a1 to a2 in the other.
                let a2 = ia + 1 < codingCount ? coding[ia + 1] : width
                let start = max(a0, 0)
                bits.write(horizontalCode, horizontalLength)
                writeRun(&bits, a1 - start, black)
                writeRun(&bits, a2 - a1, !black)
                a0 = a2
            }
            if a0 >= width { return }
        }
    }

    /// One run as Modified Huffman codes: 2560 extended make-up codes while 2624 or more remain,
    /// then one make-up code for a remaining multiple of 64, then the terminating code (as libtiff).
    private static func writeRun(_ bits: inout BitWriter, _ run: Int, _ black: Bool) {
        var run = run
        let terminating = black ? blackTerminating : whiteTerminating
        let makeUp = black ? blackMakeUp : whiteMakeUp
        while run >= 2624 {
            let last = extendedMakeUp[extendedMakeUp.count - 1]
            bits.write(last.code, last.length)
            run -= 2560
        }
        if run >= 64 {
            let index = run / 64 - 1 // 64 -> 0 ... 2560 -> 39
            let (code, length) = index < makeUp.count ? makeUp[index] : extendedMakeUp[index - makeUp.count]
            bits.write(code, length)
            run -= (index + 1) * 64
        }
        bits.write(terminating[run].code, terminating[run].length)
    }

    // MARK: Code tables

    private static let passCode = 0b0001, passLength = 4
    private static let horizontalCode = 0b001, horizontalLength = 3

    /// Vertical mode codes by a1 - b1 + 3: VL3, VL2, VL1, V0, VR1, VR2, VR3.
    private static let vertical = codes(["0000010", "000010", "010", "1", "011", "000011", "0000011"])

    /// White terminating codes, runs 0-63 (T.4 table 2).
    private static let whiteTerminating = codes([
        "00110101", "000111", "0111", "1000", "1011", "1100", "1110", "1111",
        "10011", "10100", "00111", "01000", "001000", "000011", "110100", "110101",
        "101010", "101011", "0100111", "0001100", "0001000", "0010111", "0000011", "0000100",
        "0101000", "0101011", "0010011", "0100100", "0011000", "00000010", "00000011", "00011010",
        "00011011", "00010010", "00010011", "00010100", "00010101", "00010110", "00010111", "00101000",
        "00101001", "00101010", "00101011", "00101100", "00101101", "00000100", "00000101", "00001010",
        "00001011", "01010010", "01010011", "01010100", "01010101", "00100100", "00100101", "01011000",
        "01011001", "01011010", "01011011", "01001010", "01001011", "00110010", "00110011", "00110100",
    ])

    /// Black terminating codes, runs 0-63 (T.4 table 2).
    private static let blackTerminating = codes([
        "0000110111", "010", "11", "10", "011", "0011", "0010", "00011",
        "000101", "000100", "0000100", "0000101", "0000111", "00000100", "00000111", "000011000",
        "0000010111", "0000011000", "0000001000", "00001100111", "00001101000", "00001101100", "00000110111", "00000101000",
        "00000010111", "00000011000", "000011001010", "000011001011", "000011001100", "000011001101", "000001101000", "000001101001",
        "000001101010", "000001101011", "000011010010", "000011010011", "000011010100", "000011010101", "000011010110", "000011010111",
        "000001101100", "000001101101", "000011011010", "000011011011", "000001010100", "000001010101", "000001010110", "000001010111",
        "000001100100", "000001100101", "000001010010", "000001010011", "000000100100", "000000110111", "000000111000", "000000100111",
        "000000101000", "000001011000", "000001011001", "000000101011", "000000101100", "000001011010", "000001100110", "000001100111",
    ])

    /// White make-up codes, runs 64-1728 in steps of 64 (T.4 table 3).
    private static let whiteMakeUp = codes([
        "11011", "10010", "010111", "0110111", "00110110", "00110111", "01100100", "01100101",
        "01101000", "01100111", "011001100", "011001101", "011010010", "011010011", "011010100", "011010101",
        "011010110", "011010111", "011011000", "011011001", "011011010", "011011011", "010011000", "010011001",
        "010011010", "011000", "010011011",
    ])

    /// Black make-up codes, runs 64-1728 in steps of 64 (T.4 table 3).
    private static let blackMakeUp = codes([
        "0000001111", "000011001000", "000011001001", "000001011011", "000000110011", "000000110100", "000000110101", "0000001101100",
        "0000001101101", "0000001001010", "0000001001011", "0000001001100", "0000001001101", "0000001110010", "0000001110011", "0000001110100",
        "0000001110101", "0000001110110", "0000001110111", "0000001010010", "0000001010011", "0000001010100", "0000001010101", "0000001011010",
        "0000001011011", "0000001100100", "0000001100101",
    ])

    /// Extended make-up codes for both colors, runs 1792-2560 in steps of 64 (T.4 table 3).
    private static let extendedMakeUp = codes([
        "00000001000", "00000001100", "00000001101", "000000010010", "000000010011", "000000010100", "000000010101",
        "000000010110", "000000010111", "000000011100", "000000011101", "000000011110", "000000011111",
    ])

    private static func codes(_ bitStrings: [String]) -> [(code: Int, length: Int)] {
        bitStrings.map { (Int($0, radix: 2) ?? 0, $0.count) }
    }

    // MARK: Bits

    /// Bits most significant first; the last byte is filled up with zero bits.
    private struct BitWriter {
        private var bytes: [UInt8] = []
        private var pending: UInt32 = 0
        private var pendingBits = 0

        mutating func write(_ code: Int, _ length: Int) {
            // length is 13 at most, and fewer than 8 bits wait: at most 20 bits are held.
            pending = (pending << UInt32(length)) | (UInt32(truncatingIfNeeded: code) & ((1 << UInt32(length)) - 1))
            pendingBits += length
            while pendingBits >= 8 {
                pendingBits -= 8
                bytes.append(UInt8(truncatingIfNeeded: pending >> UInt32(pendingBits)))
            }
            pending &= (1 << UInt32(pendingBits)) - 1
        }

        /// Zero bits until the bits written plus `following` more end on a byte boundary.
        mutating func padTo(_ following: Int) {
            while (bytes.count * 8 + pendingBits + following) % 8 != 0 { write(0, 1) }
        }

        mutating func toArray() -> [UInt8] {
            if pendingBits > 0 {
                bytes.append(UInt8(truncatingIfNeeded: pending << UInt32(8 - pendingBits)))
                pending = 0
                pendingBits = 0
            }
            return bytes
        }
    }
}
