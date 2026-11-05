import Foundation

// The C# reads Flate through System.IO.Compression.DeflateStream (PdfFilters.InflateFrom); there is no such
// type here, so this is the inflater it stands on (RFC 1951), with the behaviour PdfFilters relies on:
// - the stream is read bare, past any zlib header, and whatever follows the final block is ignored;
// - output is counted into the FilterBuffer as it is made, so the size cap stops a bomb while it grows;
// - data that ends early gives what was decoded;
// - data that is invalid gives what was decoded before the stretch DeflateStream was working on: it hands
//   its output back after each 8 KB of input or 64 KB of output, and a data error throws away the stretch
//   in progress. A damaged file therefore gives the same bytes as on Windows.
// The tables follow zlib's rules: an over-subscribed code is invalid, an incomplete one only when it is
// a single code of one bit, and the symbols 286, 287 and the distances 30 and 31 are invalid.

enum Flate {
    static let lengthBase = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
    static let lengthExtra = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
    static let distanceBase = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073,
                               4097, 6145, 8193, 12289, 16385, 24577]
    static let distanceExtra = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]
    static let codeLengthOrder = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]

    private static let inputChunk = 8192
    private static let outputCall = 1 << 16

    private static let fixedLiterals = Huffman(lengths: Array(repeating: 8, count: 144) + Array(repeating: 9, count: 112)
        + Array(repeating: 7, count: 24) + Array(repeating: 8, count: 8), codeLengths: false)
    private static let fixedDistances = Huffman(lengths: Array(repeating: 5, count: 32), codeLengths: false)

    /// Inflates the deflate stream that starts at `data[start]` into `output`. True when its final block was
    /// read, false when the data ended early or is invalid; a stream that expands past the cap throws.
    static func inflate(_ data: [UInt8], _ start: Int, _ output: FilterBuffer) throws -> Bool {
        var reader = Reader(data: data, start: start, output: output)
        do {
            try reader.blocks()
            return true
        } catch Failure.truncated {
            return false
        } catch Failure.invalid {
            output.truncate(to: reader.callStart)
            return false
        }
    }

    private enum Failure: Error {
        case truncated
        case invalid
    }

    /// A canonical code as a lookup table over the next `maxBits` bits (the first bit read is the low one):
    /// the symbol shifted left by 4 or'd with the code length, zero for no code.
    private struct Huffman {
        let maxBits: Int
        let mask: UInt64
        let table: [UInt16]

        init?(lengths: [UInt8], codeLengths: Bool) {
            var count = [Int](repeating: 0, count: 16)
            for length in lengths { count[Int(length)] += 1 }
            count[0] = 0
            var longest = 15
            while longest > 0 && count[longest] == 0 { longest -= 1 }
            if longest == 0 {
                maxBits = 0
                mask = 0
                table = [0]
                return
            }
            var left = 1
            for length in 1...15 {
                left = left * 2 - count[length]
                if left < 0 { return nil }
            }
            if left > 0 && (codeLengths || longest != 1) { return nil }
            var next = [Int](repeating: 0, count: 16)
            var code = 0
            for length in 1...15 {
                code = (code + count[length - 1]) << 1
                next[length] = code
            }
            let size = 1 << longest
            var slots = [UInt16](repeating: 0, count: size)
            for (symbol, length) in lengths.enumerated() where length > 0 {
                let bits = Int(length)
                var reversed = 0
                for i in 0..<bits where next[bits] >> i & 1 == 1 { reversed |= 1 << (bits - 1 - i) }
                next[bits] += 1
                var at = reversed
                while at < size {
                    slots[at] = UInt16(symbol << 4 | bits)
                    at += 1 << bits
                }
            }
            maxBits = longest
            mask = UInt64(size - 1)
            table = slots
        }
    }

    private struct Reader {
        let data: [UInt8]
        let start: Int
        let output: FilterBuffer
        var position: Int
        var hold: UInt64 = 0
        var bits = 0
        /// Where the stretch DeflateStream would be working on begins in the output.
        var callStart = 0

        init(data: [UInt8], start: Int, output: FilterBuffer) {
            self.data = data
            self.start = start
            self.output = output
            position = start
            callStart = output.count
        }

        mutating func fetch() {
            let offset = position - start
            if offset > 0 && offset % Flate.inputChunk == 0 { callStart = output.count }
            hold |= UInt64(data[position]) << UInt64(bits)
            position += 1
            bits += 8
        }

        mutating func take(_ count: Int) throws -> Int {
            if count == 0 { return 0 }
            while bits < count {
                if position >= data.count { throw Failure.truncated }
                fetch()
            }
            let value = Int(hold & ((1 << UInt64(count)) - 1))
            hold >>= UInt64(count)
            bits -= count
            return value
        }

        // Bytes are pulled only as the code needs them, as zlib does: a byte taken early could start a new
        // 8 KB stretch before a symbol that zlib has already delivered.
        mutating func read(_ code: Huffman) throws -> Int {
            while true {
                let entry = code.table[Int(hold & code.mask)]
                if entry != 0 {
                    let length = Int(entry & 15)
                    if length <= bits {
                        hold >>= UInt64(length)
                        bits -= length
                        return Int(entry >> 4)
                    }
                } else if bits >= max(code.maxBits, 1) {
                    throw Failure.invalid
                }
                if position >= data.count { throw Failure.truncated }
                fetch()
            }
        }

        // zlib hands back a full 64 KB of output only when it has another byte to write, so a call that ended
        // exactly full is still the one in progress until then.
        mutating func nextCall() {
            while output.count - callStart >= Flate.outputCall { callStart += Flate.outputCall }
        }

        mutating func blocks() throws {
            while true {
                let final = try take(1)
                switch try take(2) {
                case 0: try stored()
                case 1:
                    guard let literals = Flate.fixedLiterals, let distances = Flate.fixedDistances else { throw Failure.invalid }
                    try codes(literals, distances)
                case 2:
                    let (literals, distances) = try dynamicTables()
                    try codes(literals, distances)
                default: throw Failure.invalid
                }
                if final == 1 { return }
            }
        }

        mutating func stored() throws {
            let drop = bits % 8
            hold >>= UInt64(drop)
            bits -= drop
            let length = try take(16)
            let complement = try take(16)
            if length != complement ^ 0xFFFF { throw Failure.invalid }
            var remaining = length
            while remaining > 0 && bits >= 8 {
                nextCall()
                try output.add(UInt8(truncatingIfNeeded: hold))
                hold >>= 8
                bits -= 8
                remaining -= 1
            }
            while remaining > 0 {
                if position >= data.count { throw Failure.truncated }
                let offset = position - start
                if offset > 0 && offset % Flate.inputChunk == 0 { callStart = output.count }
                nextCall()
                let room = Flate.outputCall - (output.count - callStart)
                let n = min(remaining, data.count - position, Flate.inputChunk - offset % Flate.inputChunk, room)
                try output.add(data[position..<position + n])
                position += n
                remaining -= n
            }
        }

        mutating func dynamicTables() throws -> (Huffman, Huffman) {
            let literalCount = try take(5) + 257
            let distanceCount = try take(5) + 1
            let codeCount = try take(4) + 4
            if literalCount > 286 || distanceCount > 30 { throw Failure.invalid }
            var codeLengths = [UInt8](repeating: 0, count: 19)
            for i in 0..<codeCount { codeLengths[Flate.codeLengthOrder[i]] = UInt8(try take(3)) }
            guard let lengthCode = Huffman(lengths: codeLengths, codeLengths: true) else { throw Failure.invalid }
            let total = literalCount + distanceCount
            var lengths = [UInt8](repeating: 0, count: total)
            var at = 0
            while at < total {
                let symbol = try read(lengthCode)
                if symbol < 16 {
                    lengths[at] = UInt8(symbol)
                    at += 1
                    continue
                }
                var value: UInt8 = 0
                let repeats: Int
                switch symbol {
                case 16:
                    if at == 0 { throw Failure.invalid }
                    value = lengths[at - 1]
                    repeats = try 3 + take(2)
                case 17: repeats = try 3 + take(3)
                default: repeats = try 11 + take(7)
                }
                if at + repeats > total { throw Failure.invalid }
                for i in at..<at + repeats { lengths[i] = value }
                at += repeats
            }
            if lengths[256] == 0 { throw Failure.invalid }
            guard let literals = Huffman(lengths: Array(lengths[..<literalCount]), codeLengths: false),
                  let distances = Huffman(lengths: Array(lengths[literalCount...]), codeLengths: false) else { throw Failure.invalid }
            return (literals, distances)
        }

        mutating func codes(_ literals: Huffman, _ distances: Huffman) throws {
            while true {
                let symbol = try read(literals)
                if symbol < 256 {
                    nextCall()
                    try output.add(UInt8(symbol))
                    continue
                }
                if symbol == 256 { return }
                if symbol > 285 { throw Failure.invalid }
                let length = try Flate.lengthBase[symbol - 257] + take(Flate.lengthExtra[symbol - 257])
                let slot = try read(distances)
                if slot > 29 { throw Failure.invalid }
                let distance = try Flate.distanceBase[slot] + take(Flate.distanceExtra[slot])
                if distance > output.count { throw Failure.invalid }
                nextCall()
                let at = try output.append(length)
                for i in at..<at + length { output[i] = output[i - distance] }
                while output.count - callStart > Flate.outputCall { callStart += Flate.outputCall }
            }
        }
    }
}
