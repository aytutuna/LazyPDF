import Foundation

// Twin of windows/LazyPDF.Core/Syntax/PdfLexer.cs, made more forgiving than Lazy Scan's: numbers, unclosed
// arrays and dictionaries, stray keys and stray hex digits read as a viewer would read them.

private func ch(_ c: Unicode.Scalar) -> Int {
    Int(c.value)
}

private func isDigit(_ b: UInt8) -> Bool {
    b >= 0x30 && b <= 0x39
}

/// Tokens and objects from PDF bytes (ISO 32000-1 7.2, 7.3): white space and comments skipped,
/// names with #xx escapes, literal strings with their escapes and nested parentheses, hex
/// strings, numbers, "n g R" references, arrays, dictionaries and the start of a stream's data.
public final class PdfLexer {
    /// Deeper nesting than this is refused rather than risking the stack.
    private static let maxDepth = 200

    public let bytes: any PdfBytes
    public var position: Int

    public init(_ bytes: any PdfBytes, position: Int = 0) {
        self.bytes = bytes
        self.position = position
    }

    public static func isWhiteSpace(_ b: Int) -> Bool {
        b == 0 || b == 9 || b == 10 || b == 12 || b == 13 || b == 32
    }

    public static func isDelimiter(_ b: Int) -> Bool {
        switch b {
        case ch("("), ch(")"), ch("<"), ch(">"), ch("["), ch("]"), ch("{"), ch("}"), ch("/"), ch("%"): return true
        default: return false
        }
    }

    private static func isRegular(_ b: Int) -> Bool {
        b >= 0 && !isWhiteSpace(b) && !isDelimiter(b)
    }

    // A position from the file can be anywhere in an Int; the sum wraps to a negative one, which reads as -1.
    private func peek(_ offset: Int = 0) -> Int {
        bytes[position &+ offset]
    }

    /// Skips white space and comments.
    public func skipWhiteSpace() {
        while true {
            let b = peek()
            if Self.isWhiteSpace(b) {
                position += 1
            } else if b == ch("%") {
                while peek() != -1 && peek() != 10 && peek() != 13 { position += 1 }
            } else {
                return
            }
        }
    }

    /// The next run of regular characters ("obj", "123", "true"); empty at a delimiter or the end.
    public func readKeyword() -> String {
        Latin1.string(readKeywordBytes())
    }

    private func readKeywordBytes() -> [UInt8] {
        skipWhiteSpace()
        var token: [UInt8] = []
        while Self.isRegular(peek()) {
            token.append(UInt8(truncatingIfNeeded: peek()))
            position += 1
        }
        return token
    }

    /// A non-negative integer token, or nil (the position is then where it was).
    public func tryReadUnsigned() -> Int? {
        let start = position
        skipWhiteSpace()
        var value = 0
        var digits = 0
        while peek() >= ch("0") && peek() <= ch("9") {
            if value > (Int.max - 9) / 10 {
                position = start
                return nil
            }
            value = value * 10 + (peek() - ch("0"))
            position += 1
            digits += 1
        }
        if digits == 0 || Self.isRegular(peek()) {
            position = start
            return nil
        }
        return value
    }

    /// "n g obj" at the current position; the object's number and generation.
    public func readObjectHeader() throws -> (number: Int, generation: Int) {
        let number = tryReadUnsigned()
        let generation = number == nil ? nil : tryReadUnsigned()
        guard let n = number, let g = generation, n <= Int(Int32.max), g <= 65535, readKeyword() == "obj" else {
            throw PdfReadException.damaged("No object header at byte \(position).")
        }
        return (n, g)
    }

    /// One object; a dictionary followed by "stream" becomes a `PdfStream` whose data
    /// starts after the keyword's end of line.
    public func readObject(allowStream: Bool = true) throws -> PdfObject {
        try readObject(0, allowStream)
    }

    private func readObject(_ depth: Int, _ allowStream: Bool) throws -> PdfObject {
        if depth > Self.maxDepth { throw PdfReadException(.unsupported, "Objects are nested too deeply.") }
        skipWhiteSpace()
        let b = peek()
        switch b {
        case -1:
            throw PdfReadException.damaged("The file ends inside an object.")
        case ch("/"):
            position += 1
            return PdfName(readNameBody())
        case ch("("):
            position += 1
            return PdfString(bytes: try readLiteralBody(), isHex: false)
        case ch("["):
            position += 1
            return try readArray(depth)
        case ch("<") where peek(1) == ch("<"):
            position += 2
            return try readDictionary(depth, allowStream)
        case ch("<"):
            position += 1
            return PdfString(bytes: try readHexBody(), isHex: true)
        case ch("0")...ch("9"), ch("+"), ch("-"), ch("."):
            return readNumber()
        default:
            return try readKeywordObject(b)
        }
    }

    private func readArray(_ depth: Int) throws -> PdfObject {
        var items: [PdfObject] = []
        while true {
            skipWhiteSpace()
            if peek() == ch("]") {
                position += 1
                break
            }
            if peek() == -1 { throw PdfReadException.damaged("An array is not closed.") }
            if atObjectEnd() { break } // a missing ] is made up for
            items.append(try readObject(depth + 1, false))
        }
        return PdfArray(items)
    }

    private func readDictionary(_ depth: Int, _ allowStream: Bool) throws -> PdfObject {
        let dictionary = PdfDictionary()
        while true {
            skipWhiteSpace()
            if peek() == ch(">") && peek(1) == ch(">") {
                position += 2
                break
            }
            if atObjectEnd() { break } // so is a missing >>
            if peek() == -1 { throw PdfReadException.damaged("A dictionary is not closed.") }
            if peek() != ch("/") {
                // Something that is not a key (seen in the wild): read past it.
                _ = try readObject(depth + 1, false)
                continue
            }
            position += 1
            let key = readNameBody()
            skipWhiteSpace()
            // A key without a value before the end (seen in the wild) reads as null.
            if peek() == ch(">") && peek(1) == ch(">") {
                dictionary.add(key, PdfNull.instance)
            } else {
                dictionary.add(key, try readObject(depth + 1, false))
            }
        }
        if allowStream, let dataStart = atStreamKeyword() { return PdfStream(dictionary, dataOffset: dataStart) }
        return dictionary
    }

    private func readNumber() -> PdfObject {
        var token = readKeywordBytes()
        if !Self.isNumber(token) { token = Self.normalize(token) }
        // "n g R": an integer, another, then R.
        if token.allSatisfy(isDigit) {
            let save = position
            if let generation = tryReadUnsigned(), readKeyword() == "R", let n = Int32(Latin1.string(token)), generation <= 65535 {
                return PdfReference(Int(n), generation)
            }
            position = save
        }
        return PdfNumber(Latin1.string(token))
    }

    private func readKeywordObject(_ b: Int) throws -> PdfObject {
        let keyword = readKeyword()
        switch keyword {
        case "true": return PdfBoolean(true)
        case "false": return PdfBoolean(false)
        case "null": return PdfNull.instance
        case "": throw PdfReadException.damaged("Unexpected '\(Latin1.string([UInt8(truncatingIfNeeded: b)]))' at byte \(position).")
        default: throw PdfReadException.damaged("Unexpected \"\(keyword)\" at byte \(position).")
        }
    }

    private static func isNumber(_ text: [UInt8]) -> Bool {
        if text.isEmpty { return false }
        var i = text[0] == UInt8(ascii: "+") || text[0] == UInt8(ascii: "-") ? 1 : 0
        var digits = false
        var dot = false
        while i < text.count {
            if isDigit(text[i]) {
                digits = true
            } else if text[i] == UInt8(ascii: ".") && !dot {
                dot = true
            } else {
                return false
            }
            i += 1
        }
        return digits
    }

    /// The number a token means when it is not quite one ("--5", "1.2.3", "5-3"): its sign, digits and first point.
    private static func normalize(_ token: [UInt8]) -> [UInt8] {
        var i = 0
        while i < token.count && (token[i] == UInt8(ascii: "+") || token[i] == UInt8(ascii: "-")) { i += 1 }
        var result: [UInt8] = []
        if i > 0 && token[0] == UInt8(ascii: "-") { result.append(UInt8(ascii: "-")) }
        var dot = false
        while i < token.count {
            if token[i] == UInt8(ascii: ".") && !dot {
                dot = true
            } else if !isDigit(token[i]) {
                break
            }
            result.append(token[i])
            i += 1
        }
        return result.contains(where: isDigit) ? result : [UInt8(ascii: "0")]
    }

    /// At "endobj" or "endstream": where an array or dictionary that was never closed has to stop.
    private func atObjectEnd() -> Bool {
        peek() == ch("e") && (atWord("endobj") || atWord("endstream"))
    }

    private func atWord(_ word: String) -> Bool {
        for (i, c) in word.unicodeScalars.enumerated() where peek(i) != ch(c) {
            return false
        }
        return !Self.isRegular(peek(word.unicodeScalars.count))
    }

    /// After a dictionary: "stream" and its end of line (CRLF or LF; a lone CR is tolerated). The
    /// offset where the data starts, or nil when there is no such keyword (the position is then unchanged).
    private func atStreamKeyword() -> Int? {
        let save = position
        skipWhiteSpace()
        if readKeyword() != "stream" {
            position = save
            return nil
        }
        // Spaces between the keyword and its line break are not data.
        var spaces = 0
        while peek(spaces) == 32 || peek(spaces) == 9 { spaces += 1 }
        if peek(spaces) == 10 || peek(spaces) == 13 { position += spaces }
        if peek() == 13 && peek(1) == 10 {
            position += 2
        } else if peek() == 10 || peek() == 13 {
            position += 1
        }
        return position
    }

    private func readNameBody() -> String {
        var scalars = String.UnicodeScalarView()
        while Self.isRegular(peek()) {
            let c = peek()
            if c == ch("#"), let high = Self.hexValue(peek(1)), let low = Self.hexValue(peek(2)) {
                scalars.append(Unicode.Scalar(UInt8(truncatingIfNeeded: high * 16 + low)))
                position += 3
                continue
            }
            scalars.append(Unicode.Scalar(UInt8(truncatingIfNeeded: c)))
            position += 1
        }
        return String(scalars)
    }

    private func readLiteralBody() throws -> [UInt8] {
        var result: [UInt8] = []
        var depth = 1
        while true {
            let c = peek()
            if c == -1 { throw PdfReadException.damaged("A string is not closed.") }
            position += 1
            if c == ch("\\") {
                let e = peek()
                if e == -1 { throw PdfReadException.damaged("A string is not closed.") }
                position += 1
                switch e {
                case ch("n"): result.append(10)
                case ch("r"): result.append(13)
                case ch("t"): result.append(9)
                case ch("b"): result.append(8)
                case ch("f"): result.append(12)
                case 13:
                    if peek() == 10 { position += 1 } // a line continued: nothing
                case 10:
                    break
                case ch("0")...ch("7"):
                    var value = e - ch("0")
                    var k = 0
                    while k < 2 && peek() >= ch("0") && peek() <= ch("7") {
                        value = value * 8 + (peek() - ch("0"))
                        position += 1
                        k += 1
                    }
                    result.append(UInt8(truncatingIfNeeded: value)) // \777 is 511: the high bit is dropped (7.3.4.2)
                default:
                    result.append(UInt8(truncatingIfNeeded: e)) // \( \) \\ and any other character stand for themselves
                }
                continue
            }
            if c == ch("(") { depth += 1 }
            if c == ch(")") {
                depth -= 1
                if depth == 0 { break }
            }
            // An end of line inside a string reads as LF (7.3.4.2).
            if c == 13 {
                if peek() == 10 { position += 1 }
                result.append(10)
                continue
            }
            result.append(UInt8(truncatingIfNeeded: c))
        }
        return result
    }

    private func readHexBody() throws -> [UInt8] {
        var result: [UInt8] = []
        var high: Int?
        while true {
            let c = peek()
            if c == -1 { throw PdfReadException.damaged("A hex string is not closed.") }
            position += 1
            if c == ch(">") { break }
            if Self.isWhiteSpace(c) { continue }
            guard let digit = Self.hexValue(c) else { continue } // stray characters are ignored
            if let h = high {
                result.append(UInt8(truncatingIfNeeded: h * 16 + digit))
                high = nil
            } else {
                high = digit
            }
        }
        if let last = high { result.append(UInt8(truncatingIfNeeded: last * 16)) } // an odd last digit is followed by 0
        return result
    }

    private static func hexValue(_ c: Int) -> Int? {
        switch c {
        case ch("0")...ch("9"): return c - ch("0")
        case ch("A")...ch("F"): return c - ch("A") + 10
        case ch("a")...ch("f"): return c - ch("a") + 10
        default: return nil
        }
    }
}
