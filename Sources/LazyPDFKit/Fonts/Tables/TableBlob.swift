import Foundation

// Twin of windows/LazyPDF.Core/Fonts/Tables/TableBlob.cs: the embedded tables are raw-deflated and base64
// encoded; this undoes both. The C# gets the deflate from System.IO.Compression. Foundation has none on
// Linux and the Filters layer is not a dependency of this one, so the few lines of inflate are here. The
// input is compiled in, never a file's.
enum TableBlob {
    static func inflate(_ base64: String) -> [UInt8] {
        guard let packed = Data(base64Encoded: base64, options: .ignoreUnknownCharacters) else {
            preconditionFailure("The embedded table is not base64.")
        }
        var inflater = Inflater(input: [UInt8](packed))
        inflater.run()
        return inflater.output
    }

    static func inflateText(_ base64: String) -> String {
        String(decoding: inflate(base64), as: UTF8.self)
    }
}

private struct Huffman {
    var counts = [Int](repeating: 0, count: 16)
    var symbols: [Int]

    init(lengths: [Int]) {
        symbols = [Int](repeating: 0, count: lengths.count)
        for length in lengths { counts[length] += 1 }
        counts[0] = 0
        var offsets = [Int](repeating: 0, count: 16)
        for length in 1..<15 { offsets[length + 1] = offsets[length] + counts[length] }
        for (symbol, length) in lengths.enumerated() where length != 0 {
            symbols[offsets[length]] = symbol
            offsets[length] += 1
        }
    }
}

// RFC 1951, a bit at a time: the tables are small and read once.
private struct Inflater {
    private static let lengthBase = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
    private static let lengthExtra = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
    private static let distanceBase = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577]
    private static let distanceExtra = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]
    private static let codeLengthOrder = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]

    let input: [UInt8]
    var output: [UInt8] = []
    private var position = 0
    private var bitBuffer = 0
    private var bitCount = 0
    private var failed = false

    init(input: [UInt8]) {
        self.input = input
    }

    mutating func run() {
        var last = false
        while !last && !failed {
            last = bits(1) == 1
            switch bits(2) {
            case 0: stored()
            case 1: block(Self.fixedLiterals, Self.fixedDistances)
            case 2: dynamic()
            default: failed = true
            }
        }
    }

    private mutating func bits(_ count: Int) -> Int {
        while bitCount < count {
            guard position < input.count else {
                failed = true
                return 0
            }
            bitBuffer |= Int(input[position]) << bitCount
            position += 1
            bitCount += 8
        }
        let value = bitBuffer & ((1 << count) - 1)
        bitBuffer >>= count
        bitCount -= count
        return value
    }

    private mutating func stored() {
        bitBuffer = 0
        bitCount = 0
        guard position + 4 <= input.count else {
            failed = true
            return
        }
        let length = Int(input[position]) | Int(input[position + 1]) << 8
        position += 4
        guard position + length <= input.count else {
            failed = true
            return
        }
        output.append(contentsOf: input[position..<position + length])
        position += length
    }

    private mutating func decode(_ table: Huffman) -> Int? {
        var code = 0, first = 0, index = 0
        for length in 1...15 {
            code |= bits(1)
            if failed { return nil }
            let count = table.counts[length]
            if code - count < first { return table.symbols[index + (code - first)] }
            index += count
            first = (first + count) << 1
            code <<= 1
        }
        return nil
    }

    private mutating func block(_ literals: Huffman, _ distances: Huffman) {
        while !failed {
            guard let symbol = decode(literals) else {
                failed = true
                return
            }
            if symbol < 256 {
                output.append(UInt8(symbol))
            } else if symbol == 256 {
                return
            } else {
                let lengthIndex = symbol - 257
                guard lengthIndex < Self.lengthBase.count else {
                    failed = true
                    return
                }
                let length = Self.lengthBase[lengthIndex] + bits(Self.lengthExtra[lengthIndex])
                guard let distanceSymbol = decode(distances), distanceSymbol < Self.distanceBase.count else {
                    failed = true
                    return
                }
                let distance = Self.distanceBase[distanceSymbol] + bits(Self.distanceExtra[distanceSymbol])
                guard !failed, distance <= output.count else {
                    failed = true
                    return
                }
                for _ in 0..<length { output.append(output[output.count - distance]) }
            }
        }
    }

    private mutating func dynamic() {
        let literalCount = bits(5) + 257
        let distanceCount = bits(5) + 1
        let codeLengthCount = bits(4) + 4
        guard !failed, literalCount <= 286, distanceCount <= 30 else {
            failed = true
            return
        }
        var lengths = [Int](repeating: 0, count: 19)
        for i in 0..<codeLengthCount { lengths[Self.codeLengthOrder[i]] = bits(3) }
        let codeLengths = Huffman(lengths: lengths)
        lengths = []
        while lengths.count < literalCount + distanceCount {
            guard let symbol = decode(codeLengths) else {
                failed = true
                return
            }
            if symbol < 16 {
                lengths.append(symbol)
                continue
            }
            var repeated = 0
            var count = 0
            if symbol == 16 {
                guard let previous = lengths.last else {
                    failed = true
                    return
                }
                repeated = previous
                count = 3 + bits(2)
            } else if symbol == 17 {
                count = 3 + bits(3)
            } else {
                count = 11 + bits(7)
            }
            guard !failed, lengths.count + count <= literalCount + distanceCount else {
                failed = true
                return
            }
            lengths.append(contentsOf: [Int](repeating: repeated, count: count))
        }
        block(Huffman(lengths: Array(lengths[..<literalCount])), Huffman(lengths: Array(lengths[literalCount...])))
    }

    private static let fixedLiterals = Huffman(lengths:
        [Int](repeating: 8, count: 144) + [Int](repeating: 9, count: 112)
        + [Int](repeating: 7, count: 24) + [Int](repeating: 8, count: 8))
    private static let fixedDistances = Huffman(lengths: [Int](repeating: 5, count: 30))
}
