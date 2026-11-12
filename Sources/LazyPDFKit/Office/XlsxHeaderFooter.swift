import Foundation

// Twin of windows/LazyPDF.Core/Office/Xlsx/XlsxHeaderFooter.cs.

/// A piece of header or footer text in one style.
struct HfRun {
    let text: String
    let bold: Bool
    let italic: Bool
}

/// What the fields of a header or footer stand for.
struct HfContext {
    let page: Int
    let pages: Int
    let date: String
    let time: String
    let file: String
    let sheet: String
}

/// Reads the & codes of a header or footer string into its left, centre and right sections, each a list of lines of runs.
enum XlsxHeaderFooter {
    static let maxLines = 100

    // Only A-Z fold, so both engines agree for any input.
    private static func fold(_ units: ArraySlice<UInt16>) -> [UInt16] {
        units.map { $0 >= 0x41 && $0 <= 0x5A ? $0 + 32 : $0 }
    }

    private static func contains(_ text: [UInt16], _ word: String) -> Bool {
        let w = Array(word.utf16)
        if text.count < w.count { return false }
        for i in 0...(text.count - w.count) where Array(text[i..<(i + w.count)]) == w { return true }
        return false
    }

    private static func isHex(_ c: UInt16) -> Bool { (c >= 0x30 && c <= 0x39) || (c >= 0x61 && c <= 0x66) || (c >= 0x41 && c <= 0x46) }

    static func parse(_ source: String, _ context: HfContext) -> [[[HfRun]]] {
        var sections: [[[HfRun]]] = [[[]], [[]], [[]]]
        var section = 1
        var bold = false, italic = false
        var text: [UInt16] = []
        let s = Array(source.utf16)

        func flush() {
            if text.isEmpty { return }
            sections[section][sections[section].count - 1].append(HfRun(text: String(decoding: text, as: UTF16.self), bold: bold, italic: italic))
            text = []
        }

        func append(_ string: String) { text.append(contentsOf: string.utf16) }

        var i = 0
        while i < s.count {
            defer { i += 1 }
            let c = s[i]
            if c == 0x0D { continue }
            if c == 0x0A {
                flush()
                if sections[section].count < maxLines { sections[section].append([]) }
                continue
            }
            if c != 0x26 || i + 1 >= s.count {
                if c != 0x26 { text.append(c) }
                continue
            }
            i += 1
            let code = s[i]
            switch code {
            case 0x26: text.append(0x26)
            case 0x4C: flush(); section = 0
            case 0x43: flush(); section = 1
            case 0x52: flush(); section = 2
            case 0x42: flush(); bold.toggle()
            case 0x49: flush(); italic.toggle()
            case 0x50: append(String(context.page))
            case 0x4E: append(String(context.pages))
            case 0x44: append(context.date)
            case 0x54: append(context.time)
            case 0x46: append(context.file)
            case 0x41: append(context.sheet)
            case 0x22:
                var close = s.count
                var k = i + 1
                while k < s.count {
                    if s[k] == 0x22 {
                        close = k
                        break
                    }
                    k += 1
                }
                let font = Array(s[(i + 1)..<close])
                i = close
                guard let comma = font.firstIndex(of: 0x2C) else { break }
                flush()
                let style = fold(font[(comma + 1)...])
                if contains(style, "regular") || contains(style, "normal") { bold = false; italic = false }
                if contains(style, "bold") { bold = true }
                if contains(style, "italic") { italic = true }
            case 0x4B:
                var run = 0
                while run < 6 && i + 1 + run < s.count && (isHex(s[i + 1 + run]) || s[i + 1 + run] == 0x2B || s[i + 1 + run] == 0x2D) { run += 1 }
                if run == 6 { i += 6 }
            default:
                if code >= 0x30 && code <= 0x39 && i + 1 < s.count && s[i + 1] >= 0x30 && s[i + 1] <= 0x39 { i += 1 }
            }
        }
        flush()
        return sections
    }
}
