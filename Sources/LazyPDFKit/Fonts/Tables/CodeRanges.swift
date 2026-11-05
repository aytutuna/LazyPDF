import Foundation

// Twin of windows/LazyPDF.Core/Fonts/Tables/CodeRanges.cs: ranges of character codes with a value, searched by
// binary search. A code is keyed with its byte length, since <41> and <0041> are different codes in a CMap with
// mixed code lengths.
final class CodeRanges<Value> {
    // Overlapping ranges are a defect of the file; looking a few back finds the one nested in a wider one.
    private static var overlapProbe: Int { 4 }

    private struct Range {
        var lo: UInt64
        var hi: UInt64
        var order: Int
        var value: Value
    }

    private var added: [Range] = []
    private var sorted: [Range] = []

    var count: Int { added.count + sorted.count }

    private(set) var lengthMask = 0

    func add(_ length: Int, _ lo: UInt32, _ hi: UInt32, _ value: Value) {
        let key = UInt64(length) << 32
        added.append(Range(lo: key | UInt64(lo), hi: key | UInt64(hi), order: added.count, value: value))
        lengthMask |= 1 << length
    }

    /// Sorts what was added. Later additions win over earlier ones that cover the same code.
    func freeze() {
        sorted = added.sorted { $0.lo != $1.lo ? $0.lo < $1.lo : $0.order < $1.order }
        added.removeAll()
    }

    func tryFind(_ length: Int, _ code: UInt32) -> (lo: UInt32, value: Value)? {
        let key = UInt64(length) << 32 | UInt64(code)
        var low = 0, high = sorted.count - 1, at = -1
        while low <= high {
            let mid = (low + high) >> 1
            if sorted[mid].lo <= key {
                at = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        var i = at
        while i >= 0 && i > at - Self.overlapProbe {
            let r = sorted[i]
            if r.hi >= key {
                return (UInt32(truncatingIfNeeded: r.lo), r.value)
            }
            i -= 1
        }
        return nil
    }
}
