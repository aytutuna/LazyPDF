import Foundation

// Twin of windows/LazyPDF.Core/Filters/LzwCodec.cs: LZWDecode (ISO 32000-1 7.4.4), codes of 9 to 12 bits,
// most significant first, 256 clears the table, 257 ends the data.

enum LzwCodec {
    private static let clear = 256, end = 257, first = 258, tableSize = 4096

    /// Corrupt data (a code beyond the table) ends the output where it is.
    static func decode(_ data: [UInt8], _ earlyChange: Bool, _ maxSize: Int) throws -> [UInt8] {
        let output = FilterBuffer(maxSize, capacity: data.count * 3)
        var prefix = [Int](repeating: 0, count: tableSize)
        var suffix = [UInt8](repeating: 0, count: tableSize)
        var head = [UInt8](repeating: 0, count: tableSize)
        var length = [Int](repeating: 0, count: tableSize)
        for i in 0..<256 {
            suffix[i] = UInt8(i)
            head[i] = UInt8(i)
            length[i] = 1
        }
        let early = earlyChange ? 1 : 0
        var bits = 9, next = first, previous = -1
        var pending: UInt32 = 0
        var pendingBits = 0
        for b in data {
            pending = pending << 8 | UInt32(b)
            pendingBits += 8
            while pendingBits >= bits {
                let code = Int(pending >> UInt32(pendingBits - bits)) & ((1 << bits) - 1)
                pendingBits -= bits
                pending &= (1 << UInt32(pendingBits)) - 1
                if code == clear {
                    bits = 9
                    next = first
                    previous = -1
                    continue
                }
                if code == end { return output.toArray() }
                if previous < 0 {
                    if code > 255 { return output.toArray() }
                    try output.add(UInt8(code))
                    previous = code
                    continue
                }
                let start: UInt8
                if code < next && (code < 256 || code >= first) {
                    start = head[code]
                    try write(output, code, prefix, suffix, length)
                } else if code == next && next < tableSize {
                    start = head[previous]
                    entry(next, previous, start, &prefix, &suffix, &head, &length)
                    try write(output, code, prefix, suffix, length)
                    next += 1
                    previous = code
                    if next + early >= 1 << bits && bits < 12 { bits += 1 }
                    continue
                } else {
                    return output.toArray()
                }
                if next < tableSize {
                    entry(next, previous, start, &prefix, &suffix, &head, &length)
                    next += 1
                    if next + early >= 1 << bits && bits < 12 { bits += 1 }
                }
                previous = code
            }
        }
        return output.toArray()
    }

    private static func entry(_ index: Int, _ previous: Int, _ start: UInt8, _ prefix: inout [Int], _ suffix: inout [UInt8],
                              _ head: inout [UInt8], _ length: inout [Int]) {
        prefix[index] = previous
        suffix[index] = start
        head[index] = head[previous]
        length[index] = length[previous] + 1
    }

    private static func write(_ output: FilterBuffer, _ code: Int, _ prefix: [Int], _ suffix: [UInt8], _ length: [Int]) throws {
        let at = try output.append(length[code])
        var code = code
        var i = length[code] - 1
        while i >= 0 {
            output[at + i] = suffix[code]
            code = prefix[code]
            i -= 1
        }
    }

    static func encode(_ data: [UInt8], _ earlyChange: Bool) -> [UInt8] {
        var output: [UInt8] = []
        output.reserveCapacity(data.count / 2)
        var table: [Int: Int] = [:]
        let early = earlyChange ? 1 : 0
        var bits = 9, next = first
        var pending: UInt32 = 0
        var pendingBits = 0

        func put(_ code: Int) {
            pending = pending << UInt32(bits) | UInt32(code)
            pendingBits += bits
            while pendingBits >= 8 {
                pendingBits -= 8
                output.append(UInt8(truncatingIfNeeded: pending >> UInt32(pendingBits)))
            }
            pending &= (1 << UInt32(pendingBits)) - 1
        }

        // The encoder's table runs one entry ahead of the decoder's, hence the minus one.
        func grow() {
            next += 1
            if next + early - 1 >= 1 << bits && bits < 12 { bits += 1 }
        }

        put(clear)
        var current = -1
        for b in data {
            if current < 0 {
                current = Int(b)
                continue
            }
            let key = current << 8 | Int(b)
            if let found = table[key] {
                current = found
                continue
            }
            put(current)
            table[key] = next
            grow()
            if next >= tableSize - 2 {
                put(clear)
                table.removeAll()
                next = first
                bits = 9
            }
            current = Int(b)
        }
        if current >= 0 {
            put(current)
            grow()
        }
        put(end)
        if pendingBits > 0 { output.append(UInt8(truncatingIfNeeded: pending << UInt32(8 - pendingBits))) }
        return output
    }
}
