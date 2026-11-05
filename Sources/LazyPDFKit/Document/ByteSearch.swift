import Foundation

// What ReadOnlySpan<byte>.IndexOf, LastIndexOf and StartsWith are in the C# engine.

extension Array where Element == UInt8 {
    /// The first place at or after `start` where `pattern` occurs, or nil.
    func indexOf(_ pattern: [UInt8], from start: Int = 0) -> Int? {
        guard let first = pattern.first, start >= 0, count >= pattern.count else { return nil }
        var i = start
        let last = count - pattern.count
        while i <= last {
            if self[i] == first && hasPattern(pattern, at: i) { return i }
            i += 1
        }
        return nil
    }

    /// The last place where `pattern` occurs, or nil.
    func lastIndexOf(_ pattern: [UInt8]) -> Int? {
        guard let first = pattern.first, count >= pattern.count else { return nil }
        var i = count - pattern.count
        while i >= 0 {
            if self[i] == first && hasPattern(pattern, at: i) { return i }
            i -= 1
        }
        return nil
    }

    /// Whether `pattern` is there at `position`; false when the bytes end first.
    func hasPattern(_ pattern: [UInt8], at position: Int) -> Bool {
        guard position >= 0, position <= count - pattern.count else { return false }
        for k in 0..<pattern.count where self[position + k] != pattern[k] { return false }
        return true
    }
}

extension String {
    /// The bytes of an ASCII keyword, for the searches above.
    var keywordBytes: [UInt8] { Array(utf8) }
}
