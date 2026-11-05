import Foundation

// The writing side of Flate, which the C# gets from ZLibStream. A zlib stream (RFC 1950) of deflate blocks
// (RFC 1951): stored blocks for NoCompression, otherwise hashed matches over a 32 KB window with a fixed or
// a dynamic code per block, whichever is shorter. Its bytes differ from zlib's; the decoders agree.

/// The twin of System.IO.Compression.CompressionLevel, in the same order.
public enum CompressionLevel {
    case optimal
    case fastest
    case noCompression
    case smallestSize
}

enum Deflate {
    private static let window = 1 << 15
    private static let blockTokens = 1 << 15
    private static let matchFlag: UInt32 = 1 << 31

    private static let lengthSlot: [Int] = {
        var slots = [Int](repeating: 0, count: 259)
        for slot in 0..<Flate.lengthBase.count {
            let top = slot + 1 < Flate.lengthBase.count ? Flate.lengthBase[slot + 1] : 259
            for length in Flate.lengthBase[slot]..<top { slots[length] = slot }
        }
        return slots
    }()

    private static let distanceSlot: [UInt8] = {
        var slots = [UInt8](repeating: 0, count: window + 1)
        for slot in 0..<Flate.distanceBase.count {
            let top = slot + 1 < Flate.distanceBase.count ? Flate.distanceBase[slot + 1] : window + 1
            for distance in Flate.distanceBase[slot]..<top { slots[distance] = UInt8(slot) }
        }
        return slots
    }()

    private static let fixedLiteralLengths: [UInt8] = Array(repeating: 8, count: 144) + Array(repeating: 9, count: 112)
        + Array(repeating: 7, count: 24) + Array(repeating: 8, count: 8)

    /// Nothing in gives nothing out, as ZLibStream does when nothing was written.
    static func zlib(_ data: [UInt8], _ level: CompressionLevel) -> [UInt8] {
        if data.isEmpty { return [] }
        var writer = BitWriter()
        switch level {
        case .noCompression, .fastest: writer.bytes = [0x78, 0x01]
        case .optimal: writer.bytes = [0x78, 0x9C]
        case .smallestSize: writer.bytes = [0x78, 0xDA]
        }
        if level == .noCompression {
            storedBlocks(data, &writer)
        } else {
            let search: Search
            switch level {
            case .fastest: search = Search(chain: 8, lazy: false)
            case .smallestSize: search = Search(chain: 256, lazy: true)
            default: search = Search(chain: 48, lazy: true)
            }
            blocks(data, search, &writer)
        }
        let sum = adler32(data)
        writer.bytes += [UInt8(truncatingIfNeeded: sum >> 24), UInt8(truncatingIfNeeded: sum >> 16),
                         UInt8(truncatingIfNeeded: sum >> 8), UInt8(truncatingIfNeeded: sum)]
        return writer.bytes
    }

    static func adler32(_ data: [UInt8]) -> UInt32 {
        var a: UInt32 = 1, b: UInt32 = 0
        var at = 0
        while at < data.count {
            let end = min(at + 5552, data.count)
            while at < end {
                a &+= UInt32(data[at])
                b &+= a
                at += 1
            }
            a %= 65521
            b %= 65521
        }
        return b << 16 | a
    }

    private struct BitWriter {
        var bytes: [UInt8] = []
        var hold: UInt64 = 0
        var count = 0

        mutating func write(_ value: Int, _ bits: Int) {
            hold |= UInt64(value) << UInt64(count)
            count += bits
            while count >= 8 {
                bytes.append(UInt8(truncatingIfNeeded: hold))
                hold >>= 8
                count -= 8
            }
        }

        mutating func flush() {
            if count > 0 { bytes.append(UInt8(truncatingIfNeeded: hold)) }
            hold = 0
            count = 0
        }
    }

    private struct Search {
        let chain: Int
        let lazy: Bool
    }

    private static func storedBlocks(_ data: [UInt8], _ writer: inout BitWriter) {
        var at = 0
        repeat {
            let n = min(65535, data.count - at)
            let final = at + n >= data.count
            writer.bytes += [final ? 1 : 0, UInt8(n & 0xFF), UInt8(n >> 8), UInt8(~n & 0xFF), UInt8((~n >> 8) & 0xFF)]
            writer.bytes += data[at..<at + n]
            at += n
        } while at < data.count
    }

    // A token is a literal's byte, or a match: `matchFlag | length << 16 | distance`.
    private static func blocks(_ data: [UInt8], _ search: Search, _ writer: inout BitWriter) {
        let n = data.count
        var head = [Int32](repeating: -1, count: window)
        var previous = [Int32](repeating: -1, count: window)
        var tokens: [UInt32] = []
        tokens.reserveCapacity(blockTokens)

        func hash(_ i: Int) -> Int {
            (Int(data[i]) << 10 ^ Int(data[i + 1]) << 5 ^ Int(data[i + 2])) & (window - 1)
        }
        func insert(_ i: Int) {
            if i + 2 >= n { return }
            let h = hash(i)
            previous[i & (window - 1)] = head[h]
            head[h] = Int32(i)
        }
        func find(_ i: Int) -> (length: Int, distance: Int) {
            if i + 3 > n { return (0, 0) }
            let limit = min(258, n - i)
            var best = 0, bestDistance = 0
            var candidate = Int(head[hash(i)])
            var chain = search.chain
            while candidate >= 0 && candidate < i && chain > 0 {
                let distance = i - candidate
                if distance > window { break }
                if data[candidate + best] == data[i + best] {
                    var length = 0
                    while length < limit && data[candidate + length] == data[i + length] { length += 1 }
                    if length > best && !(length == 3 && distance > 4096) {
                        best = length
                        bestDistance = distance
                        if length >= limit { break }
                    }
                }
                candidate = Int(previous[candidate & (window - 1)])
                chain -= 1
            }
            return (best, bestDistance)
        }

        var i = 0
        var pending: (length: Int, distance: Int)?
        while i < n {
            if tokens.count >= blockTokens {
                block(tokens, final: false, &writer)
                tokens.removeAll(keepingCapacity: true)
            }
            let found = pending ?? find(i)
            pending = nil
            insert(i)
            if found.length >= 3 && search.lazy && found.length < 32 && i + 1 < n {
                let next = find(i + 1)
                if next.length > found.length {
                    tokens.append(UInt32(data[i]))
                    i += 1
                    pending = next
                    continue
                }
            }
            if found.length >= 3 {
                tokens.append(matchFlag | UInt32(found.length) << 16 | UInt32(found.distance))
                for k in 1..<found.length { insert(i + k) }
                i += found.length
            } else {
                tokens.append(UInt32(data[i]))
                i += 1
            }
        }
        block(tokens, final: true, &writer)
        writer.flush()
    }

    private static func block(_ tokens: [UInt32], final: Bool, _ writer: inout BitWriter) {
        var literalCounts = [Int](repeating: 0, count: 286)
        var distanceCounts = [Int](repeating: 0, count: 30)
        var extraBits = 0
        for token in tokens {
            if token & matchFlag == 0 {
                literalCounts[Int(token)] += 1
                continue
            }
            let length = Int(token >> 16) & 0x1FF
            let distance = Int(token & 0xFFFF)
            let l = lengthSlot[length], d = Int(distanceSlot[distance])
            literalCounts[257 + l] += 1
            distanceCounts[d] += 1
            extraBits += Flate.lengthExtra[l] + Flate.distanceExtra[d]
        }
        literalCounts[256] = 1

        var literalLengths = huffmanLengths(literalCounts, limit: 15)
        var distanceLengths = huffmanLengths(distanceCounts, limit: 15)
        if distanceLengths.allSatisfy({ $0 == 0 }) { distanceLengths[0] = 1 }
        var literalUsed = 286
        while literalUsed > 257 && literalLengths[literalUsed - 1] == 0 { literalUsed -= 1 }
        var distanceUsed = 30
        while distanceUsed > 1 && distanceLengths[distanceUsed - 1] == 0 { distanceUsed -= 1 }
        literalLengths = Array(literalLengths[..<literalUsed])
        distanceLengths = Array(distanceLengths[..<distanceUsed])

        // The code lengths themselves, run length coded as RFC 1951 3.2.7 says.
        let combined = literalLengths + distanceLengths
        var items: [(symbol: Int, bits: Int, value: Int)] = []
        var at = 0
        while at < combined.count {
            let v = combined[at]
            var run = 1
            while at + run < combined.count && combined[at + run] == v { run += 1 }
            at += run
            if v == 0 {
                while run >= 11 {
                    let k = min(run, 138)
                    items.append((18, 7, k - 11))
                    run -= k
                }
                if run >= 3 {
                    items.append((17, 3, run - 3))
                    run = 0
                }
                for _ in 0..<run { items.append((0, 0, 0)) }
            } else {
                items.append((Int(v), 0, 0))
                run -= 1
                while run >= 3 {
                    let k = min(run, 6)
                    items.append((16, 2, k - 3))
                    run -= k
                }
                for _ in 0..<run { items.append((Int(v), 0, 0)) }
            }
        }
        var codeCounts = [Int](repeating: 0, count: 19)
        for item in items { codeCounts[item.symbol] += 1 }
        // A code that is one symbol long is not complete, and the decoders refuse it for code lengths.
        if codeCounts.filter({ $0 > 0 }).count == 1 { codeCounts[codeCounts[0] > 0 ? 1 : 0] = 1 }
        let codeLengths = huffmanLengths(codeCounts, limit: 7)
        var codeUsed = 19
        while codeUsed > 4 && codeLengths[Flate.codeLengthOrder[codeUsed - 1]] == 0 { codeUsed -= 1 }

        var dynamicBits = 14 + 3 * codeUsed
        for item in items { dynamicBits += Int(codeLengths[item.symbol]) + item.bits }
        var fixedBits = 0
        for (symbol, count) in literalCounts.enumerated() {
            dynamicBits += count * Int(symbol < literalLengths.count ? literalLengths[symbol] : 0)
            fixedBits += count * Int(fixedLiteralLengths[symbol])
        }
        for (symbol, count) in distanceCounts.enumerated() {
            dynamicBits += count * Int(symbol < distanceLengths.count ? distanceLengths[symbol] : 0)
            fixedBits += count * 5
        }

        let useFixed = fixedBits <= dynamicBits
        let literalCodes: [Int], distanceCodes: [Int]
        var literalSizes: [UInt8], distanceSizes: [UInt8]
        writer.write(final ? 1 : 0, 1)
        if useFixed {
            writer.write(1, 2)
            literalSizes = fixedLiteralLengths
            distanceSizes = Array(repeating: 5, count: 30)
        } else {
            writer.write(2, 2)
            writer.write(literalLengths.count - 257, 5)
            writer.write(distanceLengths.count - 1, 5)
            writer.write(codeUsed - 4, 4)
            for i in 0..<codeUsed { writer.write(Int(codeLengths[Flate.codeLengthOrder[i]]), 3) }
            let codeCodes = canonicalCodes(codeLengths)
            for item in items {
                writer.write(codeCodes[item.symbol], Int(codeLengths[item.symbol]))
                if item.bits > 0 { writer.write(item.value, item.bits) }
            }
            literalSizes = literalLengths
            distanceSizes = distanceLengths
        }
        literalCodes = canonicalCodes(literalSizes)
        distanceCodes = canonicalCodes(distanceSizes)
        for token in tokens {
            if token & matchFlag == 0 {
                writer.write(literalCodes[Int(token)], Int(literalSizes[Int(token)]))
                continue
            }
            let length = Int(token >> 16) & 0x1FF
            let distance = Int(token & 0xFFFF)
            let l = lengthSlot[length], d = Int(distanceSlot[distance])
            writer.write(literalCodes[257 + l], Int(literalSizes[257 + l]))
            writer.write(length - Flate.lengthBase[l], Flate.lengthExtra[l])
            writer.write(distanceCodes[d], Int(distanceSizes[d]))
            writer.write(distance - Flate.distanceBase[d], Flate.distanceExtra[d])
        }
        writer.write(literalCodes[256], Int(literalSizes[256]))
    }

    /// Code lengths for the counts, none above `limit`. Counts are halved until the tree is shallow enough.
    private static func huffmanLengths(_ counts: [Int], limit: Int) -> [UInt8] {
        var counts = counts
        while true {
            var lengths = [UInt8](repeating: 0, count: counts.count)
            let used = counts.indices.filter { counts[$0] > 0 }.sorted { counts[$0] != counts[$1] ? counts[$0] < counts[$1] : $0 < $1 }
            if used.isEmpty { return lengths }
            if used.count == 1 {
                lengths[used[0]] = 1
                return lengths
            }
            // Leaves first, then the nodes made from them in order, so each queue stays sorted.
            var weight = used.map { counts[$0] }
            var parent = [Int](repeating: -1, count: used.count * 2 - 1)
            var leaf = 0, node = used.count
            func smallest() -> Int {
                if leaf < used.count && (node >= weight.count || weight[leaf] <= weight[node]) {
                    leaf += 1
                    return leaf - 1
                }
                node += 1
                return node - 1
            }
            for made in used.count..<used.count * 2 - 1 {
                let a = smallest(), b = smallest()
                weight.append(weight[a] + weight[b])
                parent[a] = made
                parent[b] = made
            }
            var depth = [Int](repeating: 0, count: parent.count)
            var deepest = 0
            for i in stride(from: parent.count - 2, through: 0, by: -1) {
                depth[i] = depth[parent[i]] + 1
                if i < used.count {
                    lengths[used[i]] = UInt8(depth[i])
                    deepest = max(deepest, depth[i])
                }
            }
            if deepest <= limit { return lengths }
            counts = counts.map { $0 > 0 ? ($0 + 1) / 2 : 0 }
        }
    }

    /// Canonical codes (RFC 1951 3.2.2) with their bits turned around, ready for a writer that puts the low bit first.
    private static func canonicalCodes(_ lengths: [UInt8]) -> [Int] {
        var count = [Int](repeating: 0, count: 16)
        for length in lengths { count[Int(length)] += 1 }
        count[0] = 0
        var next = [Int](repeating: 0, count: 16)
        var code = 0
        for length in 1...15 {
            code = (code + count[length - 1]) << 1
            next[length] = code
        }
        var codes = [Int](repeating: 0, count: lengths.count)
        for (symbol, length) in lengths.enumerated() where length > 0 {
            let bits = Int(length)
            var reversed = 0
            for i in 0..<bits where next[bits] >> i & 1 == 1 { reversed |= 1 << (bits - 1 - i) }
            next[bits] += 1
            codes[symbol] = reversed
        }
        return codes
    }
}
