import Foundation

// The reader half of XmlTree.swift: bytes to an XmlDocument, refusing what XmlReader refuses with DtdProcessing.Prohibit.

enum XmlEncoding {
    // What XmlTextReaderImpl does with the first bytes: a byte order mark, or a "<" in UTF-16 or UCS-4, picks that
    // encoding; anything else is UTF-8 unless the declaration names Latin-1 or ASCII. Bytes that are not valid in the
    // encoding are refused, as XmlReader refuses them.
    static func scalars(_ bytes: [UInt8]) -> [Unicode.Scalar]? {
        if let wide = Wide(bytes) {
            guard let text = wide.decode(bytes) else { return nil }
            if let declared = declaredEncoding(text), !wideNames.contains(declared.lowercased()) { return nil }
            return text
        }
        let body = bytes.starts(with: [0xEF, 0xBB, 0xBF]) ? bytes.dropFirst(3) : bytes[...]
        guard let declared = declaredEncoding(header(body))?.lowercased() else { return utf8(body) }
        if declared == "utf-8" { return utf8(body) }
        if latin1Names.contains(declared) { return body.map { Unicode.Scalar($0) } }
        if asciiNames.contains(declared) { return body.map { $0 < 0x80 ? Unicode.Scalar($0) : "?" } }
        return nil
    }

    private static let wideNames: Set<String> = ["ucs-2", "utf-16", "iso-10646-ucs-2", "ucs-4", "utf-32", "iso-10646-ucs-4"]
    private static let latin1Names: Set<String> = [
        "iso-8859-1", "iso_8859-1", "iso_8859-1:1987", "iso-ir-100", "latin1", "l1", "ibm819", "cp819", "csisolatin1", "iso8859-1",
    ]
    private static let asciiNames: Set<String> = [
        "us-ascii", "ascii", "ansi_x3.4-1968", "ansi_x3.4-1986", "cp367", "csascii", "ibm367", "iso-ir-6", "iso646-us", "us", "iso_646.irv:1991",
    ]

    // A 16-bit or 32-bit encoding found from the first four bytes (XmlTextReaderImpl.DetectEncoding).
    private struct Wide {
        // The place of each byte of a unit in the file, most significant first: two for UTF-16, four for UCS-4.
        let order: [Int]
        // The bytes of the mark.
        let skip: Int

        init?(_ b: [UInt8]) {
            guard b.count >= 2 else { return nil }
            let first = Int(b[0]) << 8 | Int(b[1])
            let rest = b.count >= 4 ? Int(b[2]) << 8 | Int(b[3]) : -1
            switch (first, rest) {
            case (0x0000, 0x003C): self.init([0, 1, 2, 3], 0)
            case (0x0000, 0xFEFF): self.init([0, 1, 2, 3], 4)
            case (0x0000, 0x3C00): self.init([1, 0, 3, 2], 0)
            case (0x0000, 0xFFFE): self.init([1, 0, 3, 2], 4)
            case (0xFEFF, 0): self.init([2, 3, 0, 1], 4)
            case (0xFEFF, _): self.init([0, 1], 2)
            case (0xFFFE, 0): self.init([3, 2, 1, 0], 4)
            case (0xFFFE, _): self.init([1, 0], 2)
            case (0x3C00, 0): self.init([3, 2, 1, 0], 0)
            case (0x3C00, _): self.init([1, 0], 0)
            case (0x003C, 0): self.init([2, 3, 0, 1], 0)
            case (0x003C, _): self.init([0, 1], 0)
            default: return nil
            }
        }

        private init(_ order: [Int], _ skip: Int) {
            self.order = order
            self.skip = skip
        }

        // A unit cut short at the end is left out.
        func decode(_ bytes: [UInt8]) -> [Unicode.Scalar]? {
            let size = order.count
            var scalars: [Unicode.Scalar] = []
            scalars.reserveCapacity((bytes.count - skip) / size)
            var high: UInt32?
            for n in 0..<((bytes.count - skip) / size) {
                let at = skip + n * size
                var value: UInt32 = 0
                for place in order { value = value << 8 | UInt32(bytes[at + place]) }
                if size == 4 {
                    guard let scalar = Unicode.Scalar(value) else { return nil }
                    scalars.append(scalar)
                } else if let lead = high {
                    guard value >= 0xDC00 && value <= 0xDFFF, let scalar = Unicode.Scalar(0x10000 + (lead - 0xD800) << 10 + (value - 0xDC00)) else { return nil }
                    scalars.append(scalar)
                    high = nil
                } else if value >= 0xD800 && value <= 0xDBFF {
                    high = value
                } else {
                    guard let scalar = Unicode.Scalar(value) else { return nil }
                    scalars.append(scalar)
                }
            }
            return high == nil ? scalars : nil
        }
    }

    private static func utf8(_ body: ArraySlice<UInt8>) -> [Unicode.Scalar]? {
        var decoder = UTF8()
        var iterator = body.makeIterator()
        var scalars: [Unicode.Scalar] = []
        scalars.reserveCapacity(body.count)
        while true {
            switch decoder.decode(&iterator) {
            case .scalarValue(let scalar): scalars.append(scalar)
            case .emptyInput: return scalars
            case .error: return nil
            }
        }
    }

    // The declaration, if there is one, as far as its closing ?>; ASCII is all it can hold in the encodings read this way.
    private static func header(_ body: ArraySlice<UInt8>) -> [Unicode.Scalar] {
        guard body.starts(with: Array("<?xml".utf8)) else { return [] }
        var scalars: [Unicode.Scalar] = []
        var previous: UInt8 = 0
        for b in body {
            scalars.append(Unicode.Scalar(b))
            if previous == 0x3F && b == 0x3E { break }
            previous = b
        }
        return scalars
    }

    // The encoding named in the declaration at the start of the text; nil when there is none or it is not well-formed (the
    // parser refuses that again).
    private static func declaredEncoding(_ s: [Unicode.Scalar]) -> String? {
        var parser = XmlParser(s)
        return (try? parser.readDeclaration()) ?? nil
    }

    static func normalizeLineEnds(_ s: [Unicode.Scalar]) -> [Unicode.Scalar] {
        var result: [Unicode.Scalar] = []
        result.reserveCapacity(s.count)
        var i = 0
        while i < s.count {
            if s[i] == "\r" {
                result.append("\n")
                if i + 1 < s.count && s[i + 1] == "\n" { i += 1 }
            } else {
                result.append(s[i])
            }
            i += 1
        }
        return result
    }
}

struct XmlError: Error {}

struct XmlParser {
    private static let maxDepth = 1000

    private let s: [Unicode.Scalar]
    private var i = 0
    private let document = XmlDocument()
    private var open: [XmlElement] = []
    private var rawNames: [String] = []
    // The namespace each prefix has in the open elements, innermost last, and what each open element declared, so that a
    // prefix is found without walking the open elements.
    private var bindings: [OrdinalString: [String]] = [:]
    private var declarations: [[OrdinalString]] = []

    init(_ scalars: [Unicode.Scalar]) {
        s = scalars
    }

    mutating func parseDocument() throws -> XmlDocument {
        _ = try readDeclaration()
        while i < s.count {
            if starts("<!--") {
                try add(readComment())
            } else if starts("<?") {
                try add(readInstruction())
            } else if starts("<![CDATA[") {
                guard !open.isEmpty else { throw XmlError() }
                try add(readCData())
            } else if starts("<!") {
                throw XmlError()
            } else if starts("</") {
                try readEndTag()
            } else if s[i] == "<" {
                if open.isEmpty && document.root != nil { throw XmlError() }
                try readStartTag()
            } else {
                try add(readText())
            }
        }
        guard open.isEmpty, document.root != nil else { throw XmlError() }
        return document
    }

    private mutating func add(_ node: XmlNode) throws {
        if let parent = open.last {
            parent.append(node)
        } else {
            if let text = node as? XmlText, !text.value.unicodeScalars.allSatisfy({ XmlParser.isSpace($0) }) { throw XmlError() }
            document.append(node)
        }
    }

    private static func isSpace(_ c: Unicode.Scalar) -> Bool {
        c == " " || c == "\t" || c == "\n" || c == "\r"
    }

    private func starts(_ text: String) -> Bool {
        var at = i
        for c in text.unicodeScalars {
            if at >= s.count || s[at] != c { return false }
            at += 1
        }
        return true
    }

    // XMLDecl (XML 1.0 2.8): version, then encoding, then standalone, each after a space. Returns the encoding it names.
    mutating func readDeclaration() throws -> String? {
        guard starts("<?xml"), i + 5 < s.count, XmlParser.isSpace(s[i + 5]) else { return nil }
        i += 5
        skipSpace()
        guard XmlParser.same(try readName(), "version") else { throw XmlError() }
        try skipEquals()
        guard XmlParser.same(try readQuoted(), "1.0") else { throw XmlError() }
        var encoding: String?
        var stage = 0
        while true {
            let spaced = skipSpace()
            if starts("?>") {
                i += 2
                return encoding
            }
            guard spaced else { throw XmlError() }
            let key = try readName()
            try skipEquals()
            let value = try readQuoted()
            if XmlParser.same(key, "encoding") && stage == 0 {
                guard XmlParser.isEncodingName(value) else { throw XmlError() }
                encoding = value
                stage = 1
            } else if XmlParser.same(key, "standalone") && stage < 2 {
                guard XmlParser.same(value, "yes") || XmlParser.same(value, "no") else { throw XmlError() }
                stage = 2
            } else {
                throw XmlError()
            }
        }
    }

    // EncName (XML 1.0 4.3.3): a letter, then letters, digits, dots, underscores and hyphens.
    private static func isEncodingName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, first.isASCII, first.properties.isAlphabetic else { return false }
        return name.unicodeScalars.allSatisfy { c in
            switch c.value {
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0x2D, 0x2E, 0x5F: return true
            default: return false
            }
        }
    }

    // Names are equal when their scalars are; String's own == also equates canonical equivalents, which .NET does not.
    static func same(_ a: String, _ b: String) -> Bool {
        a.utf8.elementsEqual(b.utf8)
    }

    @discardableResult
    private mutating func skipSpace() -> Bool {
        let before = i
        while i < s.count && XmlParser.isSpace(s[i]) { i += 1 }
        return i > before
    }

    private mutating func skipEquals() throws {
        skipSpace()
        guard i < s.count, s[i] == "=" else { throw XmlError() }
        i += 1
        skipSpace()
    }

    private mutating func readQuoted() throws -> String {
        guard i < s.count, s[i] == "\"" || s[i] == "'" else { throw XmlError() }
        let quote = s[i]
        i += 1
        var text = String.UnicodeScalarView()
        while i < s.count && s[i] != quote {
            text.append(s[i])
            i += 1
        }
        guard i < s.count else { throw XmlError() }
        i += 1
        return String(text)
    }

    private mutating func readComment() throws -> XmlNode {
        i += 4
        var text = String.UnicodeScalarView()
        while true {
            guard i < s.count else { throw XmlError() }
            if starts("-->") {
                i += 3
                break
            }
            if starts("--") { throw XmlError() }
            guard XmlParser.isChar(s[i]) else { throw XmlError() }
            text.append(s[i])
            i += 1
        }
        return XmlComment(String(text))
    }

    private mutating func readInstruction() throws -> XmlNode {
        i += 2
        let target = try readName()
        guard !target.unicodeScalars.contains(":"), target.lowercased() != "xml" else { throw XmlError() }
        var data = String.UnicodeScalarView()
        if starts("?>") {
            i += 2
            return XmlInstruction(target, "")
        }
        guard i < s.count, XmlParser.isSpace(s[i]) else { throw XmlError() }
        skipSpace()
        while true {
            guard i < s.count else { throw XmlError() }
            if starts("?>") {
                i += 2
                break
            }
            guard XmlParser.isChar(s[i]) else { throw XmlError() }
            data.append(s[i])
            i += 1
        }
        return XmlInstruction(target, String(data))
    }

    private mutating func readCData() throws -> XmlNode {
        i += 9
        var text = String.UnicodeScalarView()
        while true {
            guard i < s.count else { throw XmlError() }
            if starts("]]>") {
                i += 3
                break
            }
            guard XmlParser.isChar(s[i]) else { throw XmlError() }
            text.append(s[i])
            i += 1
        }
        return XmlText(String(text), isCData: true)
    }

    private mutating func readText() throws -> XmlNode {
        var text = String.UnicodeScalarView()
        while i < s.count && s[i] != "<" {
            if s[i] == "&" {
                text.append(try readReference())
            } else {
                if starts("]]>") { throw XmlError() }
                guard XmlParser.isChar(s[i]) else { throw XmlError() }
                text.append(s[i])
                i += 1
            }
        }
        return XmlText(String(text))
    }

    // &amp; &lt; &gt; &quot; &apos; and character references; any other entity needs a DTD.
    private mutating func readReference() throws -> Unicode.Scalar {
        i += 1
        let named: [(String, Unicode.Scalar)] = [("amp;", "&"), ("lt;", "<"), ("gt;", ">"), ("quot;", "\""), ("apos;", "'")]
        for (name, value) in named where starts(name) {
            i += name.unicodeScalars.count
            return value
        }
        guard i < s.count, s[i] == "#" else { throw XmlError() }
        i += 1
        var radix: UInt32 = 10
        if i < s.count && s[i] == "x" {
            radix = 16
            i += 1
        }
        var code: UInt32 = 0
        var digits = 0
        while i < s.count, let digit = XmlParser.digit(s[i], radix) {
            code = code * radix + digit
            guard code <= 0x10FFFF else { throw XmlError() }
            digits += 1
            i += 1
        }
        guard digits > 0, i < s.count, s[i] == ";", let scalar = Unicode.Scalar(code), XmlParser.isChar(scalar) else { throw XmlError() }
        i += 1
        return scalar
    }

    private static func digit(_ c: Unicode.Scalar, _ radix: UInt32) -> UInt32? {
        let v = c.value
        let d: UInt32
        switch v {
        case 0x30...0x39: d = v - 0x30
        case 0x41...0x46: d = v - 0x41 + 10
        case 0x61...0x66: d = v - 0x61 + 10
        default: return nil
        }
        return d < radix ? d : nil
    }

    private mutating func readStartTag() throws {
        i += 1
        let raw = try readName()
        var attributes: [(raw: String, value: String)] = []
        var names = Set<OrdinalString>()
        var selfClosing = false
        while true {
            let before = i
            skipSpace()
            guard i < s.count else { throw XmlError() }
            if s[i] == ">" {
                i += 1
                break
            }
            if starts("/>") {
                i += 2
                selfClosing = true
                break
            }
            guard i > before else { throw XmlError() }
            let key = try readName()
            skipSpace()
            guard i < s.count, s[i] == "=" else { throw XmlError() }
            i += 1
            skipSpace()
            guard names.insert(OrdinalString(key)).inserted else { throw XmlError() }
            attributes.append((key, try readAttributeValue()))
        }
        let (element, declared) = try makeElement(raw, attributes)
        try add(element)
        if !selfClosing {
            guard open.count < XmlParser.maxDepth else { throw XmlError() }
            element.markHasContent()
            open.append(element)
            rawNames.append(raw)
            for (prefix, uri) in declared { bindings[prefix, default: []].append(uri) }
            declarations.append(declared.map { $0.prefix })
        }
    }

    private mutating func readAttributeValue() throws -> String {
        guard i < s.count, s[i] == "\"" || s[i] == "'" else { throw XmlError() }
        let quote = s[i]
        i += 1
        var text = String.UnicodeScalarView()
        while true {
            guard i < s.count, s[i] != "<" else { throw XmlError() }
            if s[i] == quote {
                i += 1
                break
            }
            if s[i] == "&" {
                text.append(try readReference())
            } else if s[i] == "\t" || s[i] == "\n" {
                text.append(" ")
                i += 1
            } else {
                guard XmlParser.isChar(s[i]) else { throw XmlError() }
                text.append(s[i])
                i += 1
            }
        }
        return String(text)
    }

    private mutating func readEndTag() throws {
        i += 2
        let raw = try readName()
        skipSpace()
        guard i < s.count, s[i] == ">", let last = rawNames.last, XmlParser.same(last, raw) else { throw XmlError() }
        i += 1
        open.removeLast()
        rawNames.removeLast()
        for prefix in declarations.removeLast() { bindings[prefix]?.removeLast() }
    }

    // The prefix an xmlns attribute declares: empty for xmlns itself, nil for any other attribute.
    private static func declaredPrefix(_ raw: String) -> String? {
        if same(raw, "xmlns") { return "" }
        guard raw.unicodeScalars.starts(with: "xmlns:".unicodeScalars) else { return nil }
        return String(String.UnicodeScalarView(raw.unicodeScalars.dropFirst(6)))
    }

    private func makeElement(_ raw: String, _ attributes: [(raw: String, value: String)]) throws -> (XmlElement, [(prefix: OrdinalString, uri: String)]) {
        var declared: [OrdinalString: String] = [:]
        var declarations: [(prefix: OrdinalString, uri: String)] = []
        for a in attributes {
            guard let p = XmlParser.declaredPrefix(a.raw) else { continue }
            if p.isEmpty {
                guard !XmlParser.same(a.value, XmlNamespaces.xml), !XmlParser.same(a.value, XmlNamespaces.xmlns) else { throw XmlError() }
            } else {
                guard !p.unicodeScalars.contains(":"), !XmlParser.same(p, "xmlns"), !a.value.isEmpty, !XmlParser.same(a.value, XmlNamespaces.xmlns) else { throw XmlError() }
                guard XmlParser.same(p, "xml") == XmlParser.same(a.value, XmlNamespaces.xml) else { throw XmlError() }
            }
            declared[OrdinalString(p)] = a.value
            declarations.append((OrdinalString(p), a.value))
        }
        func lookUp(_ prefix: String) -> String? {
            let key = OrdinalString(prefix)
            if let uri = declared[key] { return uri }
            if XmlParser.same(prefix, "xml") { return XmlNamespaces.xml }
            return bindings[key]?.last
        }
        var made: [XmlAttribute] = []
        made.reserveCapacity(attributes.count)
        var seen = Set<XmlName>()
        for a in attributes {
            if let p = XmlParser.declaredPrefix(a.raw) {
                made.append(p.isEmpty ? XmlAttribute(XmlName("", "xmlns"), a.value, prefix: "") : XmlAttribute(XmlName(XmlNamespaces.xmlns, p), a.value, prefix: "xmlns"))
            } else {
                let (prefix, local) = try XmlParser.split(a.raw)
                var uri = ""
                if let prefix {
                    guard let found = lookUp(prefix) else { throw XmlError() }
                    uri = found
                }
                let name = XmlName(uri, local)
                guard seen.insert(name).inserted else { throw XmlError() }
                made.append(XmlAttribute(name, a.value, prefix: prefix))
            }
        }
        let (prefix, local) = try XmlParser.split(raw)
        var uri = ""
        if let prefix {
            guard let found = lookUp(prefix) else { throw XmlError() }
            uri = found
        } else if let found = lookUp("") {
            uri = found
        }
        let element = XmlElement(XmlName(uri, local), prefix: prefix ?? "")
        element.attributes = made
        return (element, declarations)
    }

    // A qualified name into prefix and local part, each an NCName.
    private static func split(_ raw: String) throws -> (String?, String) {
        let parts = raw.unicodeScalars.split(separator: ":", omittingEmptySubsequences: false)
        switch parts.count {
        case 1: return (nil, raw)
        case 2:
            guard !parts[0].isEmpty, !parts[1].isEmpty, isNameStart(parts[1][parts[1].startIndex]), isNameStart(parts[0][parts[0].startIndex]) else { throw XmlError() }
            return (String(String.UnicodeScalarView(parts[0])), String(String.UnicodeScalarView(parts[1])))
        default: throw XmlError()
        }
    }

    private mutating func readName() throws -> String {
        guard i < s.count, XmlParser.isNameStart(s[i]) else { throw XmlError() }
        var name = String.UnicodeScalarView()
        while i < s.count && XmlParser.isNameChar(s[i]) {
            name.append(s[i])
            i += 1
        }
        return String(name)
    }

    static func isChar(_ c: Unicode.Scalar) -> Bool {
        let v = c.value
        return v == 9 || v == 10 || v == 13 || (v >= 0x20 && v <= 0xD7FF) || (v >= 0xE000 && v <= 0xFFFD) || v >= 0x10000
    }

    static func isNameStart(_ c: Unicode.Scalar) -> Bool {
        c == ":" || XmlNameTables.isStart(c.value)
    }

    static func isNameChar(_ c: Unicode.Scalar) -> Bool {
        c == ":" || XmlNameTables.isPart(c.value)
    }
}
