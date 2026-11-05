import Foundation

// What System.Version is in the C# engine: two to four dot-separated numbers, compared part by part with a
// missing part below 0. The header's version and the catalog's /Version are read and compared with it.

struct SystemVersion: Comparable {
    private let parts: [Int]

    private init(_ parts: [Int]) {
        self.parts = parts + Array(repeating: -1, count: 4 - parts.count)
    }

    init?(_ text: String) {
        let pieces = text.unicodeScalars.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count >= 2 && pieces.count <= 4 else { return nil }
        var parts: [Int] = []
        for piece in pieces {
            guard let number = SystemVersion.number(Array(piece)) else { return nil }
            parts.append(number)
        }
        self.init(parts)
    }

    /// A part as int.Parse reads it: white space around it and a sign allowed, a value up to int.MaxValue.
    private static func number(_ scalars: [Unicode.Scalar]) -> Int? {
        func blank(_ s: Unicode.Scalar) -> Bool { s == " " || (s.value >= 9 && s.value <= 13) }
        var digits = scalars[...]
        while let first = digits.first, blank(first) { digits.removeFirst() }
        while let last = digits.last, blank(last) { digits.removeLast() }
        if digits.first == "+" { digits.removeFirst() }
        guard !digits.isEmpty, digits.allSatisfy({ $0.value >= 0x30 && $0.value <= 0x39 }),
              let value = Int(String(String.UnicodeScalarView(digits))), value <= Int(Int32.max) else { return nil }
        return value
    }

    static func < (a: SystemVersion, b: SystemVersion) -> Bool {
        a.parts.lexicographicallyPrecedes(b.parts)
    }
}
