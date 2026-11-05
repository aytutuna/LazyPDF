import Foundation

// Twin of windows/LazyPDF.Core/Ocr/OcrVisualOrder.cs: a word with Hebrew or Arabic letters is written to the page in
// the order it shows, left to right, as every other producer does: the text extraction in Text/ puts it back in logical
// order. Applying `flip` twice gives the word back.

enum OcrVisualOrder {
    static func flip(_ text: String) -> String {
        var runes = Array(text.unicodeScalars)
        var classes = runes.map { TextBidi.classOf(String($0)) }
        if !classes.contains(.r) { return text }
        runes.reverse()
        classes.reverse()

        // Letters and numbers that read left to right keep their own order inside the reversed word.
        let n = runes.count
        var i = 0
        while i < n {
            if !inRun(runes, classes, i) {
                runes[i] = mirror(runes[i])
                i += 1
                continue
            }
            var j = i
            while j < n && inRun(runes, classes, j) { j += 1 }
            runes[i..<j].reverse()
            i = j
        }
        return String(String.UnicodeScalarView(runes))
    }

    private static func inRun(_ runes: [Unicode.Scalar], _ classes: [BidiClass], _ i: Int) -> Bool {
        if classes[i] == .l || classes[i] == .en || classes[i] == .an { return true }
        // 3.14 and 1,000 stay whole.
        guard i > 0, i + 1 < runes.count else { return false }
        let joins: Set<UInt32> = [0x2E, 0x2C, 0x3A, 0x2F, 0x2B, 0x2D]
        let number: (BidiClass) -> Bool = { $0 == .en || $0 == .an }
        return joins.contains(runes[i].value) && number(classes[i - 1]) && number(classes[i + 1])
    }

    private static func mirror(_ rune: Unicode.Scalar) -> Unicode.Scalar {
        switch rune {
        case "(": return ")"
        case ")": return "("
        case "[": return "]"
        case "]": return "["
        case "{": return "}"
        case "}": return "{"
        case "<": return ">"
        case ">": return "<"
        case "\u{AB}": return "\u{BB}"
        case "\u{BB}": return "\u{AB}"
        default: return rune
        }
    }
}
