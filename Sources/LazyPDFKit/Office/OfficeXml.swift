import Foundation

// Twin of windows/LazyPDF.Core/Office/XmlTree.cs. The parse works on UTF-16 units and compares names unit by unit, as the
// C# does, since Swift's String equality treats canonically equivalent text as equal.

/// What an XML part may hold. Counts include namespace declarations; a document over a limit is refused, not cut.
struct OfficeXmlLimits {
    var maxDepth = 128
    var maxElements = 1_000_000
    var maxAttributes = 128

    static let standard = OfficeXmlLimits()
}

enum OfficeXmlNode {
    case element(OfficeXmlElement)
    case text(String)
}

struct OfficeXmlAttribute {
    let uri: String
    let name: String
    let value: String
}

/// An element with its namespace resolved: `uri` and the local `name`. Namespace declarations are not attributes.
final class OfficeXmlElement {
    let uri: String
    let name: String
    let attributes: [OfficeXmlAttribute]
    fileprivate(set) var children: [OfficeXmlNode] = []

    init(uri: String, name: String, attributes: [OfficeXmlAttribute]) {
        self.uri = uri
        self.name = name
        self.attributes = attributes
    }

    var elements: [OfficeXmlElement] {
        children.compactMap { if case .element(let e) = $0 { return e } else { return nil } }
    }

    func elements(_ uri: String, _ name: String) -> [OfficeXmlElement] { elements.filter { $0.uri == uri && $0.name == name } }

    func child(_ uri: String, _ name: String) -> OfficeXmlElement? { elements.first { $0.uri == uri && $0.name == name } }

    func attribute(_ uri: String, _ name: String) -> String? { attributes.first { $0.uri == uri && $0.name == name }?.value }

    /// An attribute with no namespace, which is how most of them are written.
    func attribute(_ name: String) -> String? { attribute("", name) }

    /// The text directly inside the element, CDATA included, without that of its children.
    var text: String {
        children.reduce(into: "") { if case .text(let t) = $1 { $0 += t } }
    }
}

/// A small non-validating XML reader for OOXML parts, written so that the C# and Swift engines read a part alike (the platform
/// parsers differ on the odd cases, Foundation's on Linux and Apple included). CONTRACTS.md has the rules.
enum OfficeXml {
    private static let xmlUri = Array("http://www.w3.org/XML/1998/namespace".utf16)

    static func parse(_ data: [UInt8], _ limits: OfficeXmlLimits = .standard) throws -> OfficeXmlElement {
        var parser = Parser(try decode(data), limits)
        return try parser.run()
    }

    private static func decode(_ d: [UInt8]) throws -> [UInt16] {
        var skip = 0
        var bigEndian: Bool?
        if d.count >= 3 && d[0] == 0xEF && d[1] == 0xBB && d[2] == 0xBF {
            skip = 3
        } else if d.count >= 2 && ((d[0] == 0xFE && d[1] == 0xFF) || (d[0] == 0 && d[1] == 0x3C)) {
            bigEndian = true
            skip = d[0] == 0xFE ? 2 : 0
        } else if d.count >= 2 && ((d[0] == 0xFF && d[1] == 0xFE) || (d[0] == 0x3C && d[1] == 0)) {
            bigEndian = false
            skip = d[0] == 0xFF ? 2 : 0
        }
        if let big = bigEndian { return try utf16(d, skip, big) }
        return try utf8(d, skip)
    }

    private static func unit(_ d: [UInt8], _ i: Int, _ big: Bool) -> UInt16 {
        big ? UInt16(d[i]) << 8 | UInt16(d[i + 1]) : UInt16(d[i + 1]) << 8 | UInt16(d[i])
    }

    private static func utf16(_ d: [UInt8], _ from: Int, _ big: Bool) throws -> [UInt16] {
        if (d.count - from) % 2 != 0 { throw notText() }
        var out: [UInt16] = []
        out.reserveCapacity((d.count - from) / 2)
        var i = from
        while i < d.count {
            let u = unit(d, i, big)
            i += 2
            if u >= 0xD800 && u < 0xDC00 {
                guard i < d.count else { throw notText() }
                let low = unit(d, i, big)
                guard low >= 0xDC00 && low < 0xE000 else { throw notText() }
                i += 2
                out.append(u)
                out.append(low)
            } else if u >= 0xDC00 && u < 0xE000 {
                throw notText()
            } else {
                out.append(u)
            }
        }
        return out
    }

    private static func utf8(_ d: [UInt8], _ from: Int) throws -> [UInt16] {
        var out: [UInt16] = []
        out.reserveCapacity(d.count - from)
        var i = from
        while i < d.count {
            let b = d[i]
            i += 1
            if b < 0x80 {
                out.append(UInt16(b))
                continue
            }
            let need: Int
            var scalar: UInt32
            var low: UInt8 = 0x80
            var high: UInt8 = 0xBF
            switch b {
            case 0xC2...0xDF:
                need = 1
                scalar = UInt32(b & 0x1F)
            case 0xE0...0xEF:
                need = 2
                scalar = UInt32(b & 0x0F)
                if b == 0xE0 { low = 0xA0 }
                if b == 0xED { high = 0x9F }
            case 0xF0...0xF4:
                need = 3
                scalar = UInt32(b & 0x07)
                if b == 0xF0 { low = 0x90 }
                if b == 0xF4 { high = 0x8F }
            default: throw notText()
            }
            for k in 0..<need {
                guard i < d.count else { throw notText() }
                let c = d[i]
                if c < (k == 0 ? low : 0x80) || c > (k == 0 ? high : 0xBF) { throw notText() }
                scalar = scalar << 6 | UInt32(c & 0x3F)
                i += 1
            }
            if scalar >= 0x10000 {
                let v = scalar - 0x10000
                out.append(UInt16(0xD800 + (v >> 10)))
                out.append(UInt16(0xDC00 + (v & 0x3FF)))
            } else {
                out.append(UInt16(scalar))
            }
        }
        return out
    }

    private static func notText() -> PdfReadException { bad("the text is not valid UTF-8 or UTF-16.") }

    fileprivate static func bad(_ what: String) -> PdfReadException { .damaged("The XML is damaged: \(what)") }

    fileprivate static func refused(_ what: String) -> PdfReadException {
        PdfReadException(.unsupported, "The XML is refused: \(what).")
    }

    fileprivate static func str<S: Sequence>(_ units: S) -> String where S.Element == UInt16 {
        String(decoding: Array(units), as: UTF16.self)
    }

    private final class Frame {
        let element: OfficeXmlElement
        let qname: [UInt16]
        let declared: [[UInt16]]

        init(_ element: OfficeXmlElement, _ qname: [UInt16], _ declared: [[UInt16]]) {
            self.element = element
            self.qname = qname
            self.declared = declared
        }
    }

    private struct Parser {
        let s: [UInt16]
        let limits: OfficeXmlLimits
        var i = 0
        var elements = 0
        var stack: [Frame] = []
        var bound: [[UInt16]: [[UInt16]]] = [Array("xml".utf16): [OfficeXml.xmlUri]]
        var text: [UInt16] = []
        var root: OfficeXmlElement?

        init(_ units: [UInt16], _ limits: OfficeXmlLimits) {
            s = units
            self.limits = limits
        }

        mutating func run() throws -> OfficeXmlElement {
            while i < s.count {
                if s[i] != 0x3C { try charData() }
                else if starts("<?") { try instruction() }
                else if starts("<!--") { try comment() }
                else if starts("<![CDATA[") { try cdata() }
                else if starts("<!DOCTYPE") { throw OfficeXml.refused("a document type is not allowed") }
                else if starts("<!") { throw OfficeXml.bad("unknown markup declaration.") }
                else if starts("</") { try endTag() }
                else { try startTag() }
            }
            if !stack.isEmpty { throw OfficeXml.bad("an element is not closed.") }
            guard let root else { throw OfficeXml.bad("there is no root element.") }
            return root
        }

        func starts(_ t: String) -> Bool {
            let u = Array(t.utf16)
            if s.count - i < u.count { return false }
            for k in 0..<u.count where s[i + k] != u[k] { return false }
            return true
        }

        func find(_ t: String, from: Int) -> Int? {
            let u = Array(t.utf16)
            var p = from
            while p <= s.count - u.count {
                if s[p] == u[0] {
                    var k = 1
                    while k < u.count && s[p + k] == u[k] { k += 1 }
                    if k == u.count { return p }
                }
                p += 1
            }
            return nil
        }

        static func isSpace(_ c: UInt16) -> Bool { c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D }

        static func isNameStart(_ c: UInt16) -> Bool {
            (c >= 0x61 && c <= 0x7A) || (c >= 0x41 && c <= 0x5A) || c == 0x5F || c == 0x3A || c >= 0x80
        }

        static func isNameChar(_ c: UInt16) -> Bool {
            isNameStart(c) || (c >= 0x30 && c <= 0x39) || c == 0x2D || c == 0x2E
        }

        mutating func skipSpace() {
            while i < s.count && Parser.isSpace(s[i]) { i += 1 }
        }

        mutating func name() throws -> [UInt16] {
            let start = i
            if i >= s.count || !Parser.isNameStart(s[i]) { throw OfficeXml.bad("a name was expected.") }
            while i < s.count && Parser.isNameChar(s[i]) { i += 1 }
            return Array(s[start..<i])
        }

        mutating func charData() throws {
            let inside = !stack.isEmpty
            while i < s.count && s[i] != 0x3C {
                let c = s[i]
                if !inside {
                    if !Parser.isSpace(c) { throw OfficeXml.bad("text outside the root element.") }
                    i += 1
                } else if c == 0x26 {
                    i += 1
                    text += try reference()
                } else if c == 0x0D {
                    i += 1
                    if i < s.count && s[i] == 0x0A { i += 1 }
                    text.append(0x0A)
                } else {
                    text.append(c)
                    i += 1
                }
            }
        }

        mutating func reference() throws -> [UInt16] {
            if i < s.count && s[i] == 0x23 {
                i += 1
                let hex = i < s.count && s[i] == 0x78
                if hex { i += 1 }
                let start = i
                var value = 0
                while i < s.count && s[i] != 0x3B {
                    let digit = Parser.digit(s[i], hex)
                    if digit < 0 || i - start >= 8 { throw OfficeXml.bad("a character reference is not a number.") }
                    value = value * (hex ? 16 : 10) + digit
                    i += 1
                }
                if i >= s.count || i == start { throw OfficeXml.bad("a character reference is not closed.") }
                i += 1
                let ok = value == 9 || value == 10 || value == 13 || (value >= 0x20 && value <= 0xD7FF)
                    || (value >= 0xE000 && value <= 0xFFFD) || (value >= 0x10000 && value <= 0x10FFFF)
                if !ok { throw OfficeXml.bad("a character reference is not a legal character.") }
                if value >= 0x10000 {
                    let v = value - 0x10000
                    return [UInt16(0xD800 + (v >> 10)), UInt16(0xDC00 + (v & 0x3FF))]
                }
                return [UInt16(value)]
            }
            var end = -1
            var p = i
            while p < min(i + 5, s.count) {
                if s[p] == 0x3B {
                    end = p
                    break
                }
                p += 1
            }
            if end < 0 { throw OfficeXml.bad("an entity is not closed or not known.") }
            let name = OfficeXml.str(s[i..<end])
            let c: UInt16
            switch name {
            case "lt": c = 0x3C
            case "gt": c = 0x3E
            case "amp": c = 0x26
            case "quot": c = 0x22
            case "apos": c = 0x27
            default: throw OfficeXml.bad("the entity &\(name); is not defined.")
            }
            i = end + 1
            return [c]
        }

        static func digit(_ c: UInt16, _ hex: Bool) -> Int {
            switch c {
            case 0x30...0x39: return Int(c) - 0x30
            case 0x61...0x66 where hex: return Int(c) - 0x61 + 10
            case 0x41...0x46 where hex: return Int(c) - 0x41 + 10
            default: return -1
            }
        }

        mutating func comment() throws {
            guard let end = find("-->", from: i + 4) else { throw OfficeXml.bad("a comment is not closed.") }
            i = end + 3
        }

        mutating func cdata() throws {
            if stack.isEmpty { throw OfficeXml.bad("CDATA outside the root element.") }
            guard let end = find("]]>", from: i + 9) else { throw OfficeXml.bad("a CDATA section is not closed.") }
            var k = i + 9
            while k < end {
                if !(s[k] == 0x0D && k + 1 < end && s[k + 1] == 0x0A) {
                    text.append(s[k] == 0x0D ? 0x0A : s[k])
                }
                k += 1
            }
            i = end + 3
        }

        static func lowered(_ units: [UInt16]) -> [UInt16] {
            units.map { $0 >= 0x41 && $0 <= 0x5A ? $0 + 0x20 : $0 }
        }

        mutating func instruction() throws {
            let first = i == 0
            i += 2
            let target = try name()
            guard let end = find("?>", from: i) else { throw OfficeXml.bad("a processing instruction is not closed.") }
            let lower = Parser.lowered(target)
            if lower == Array("xml".utf16) {
                if !first || target != lower { throw OfficeXml.bad("the XML declaration is not at the start.") }
                try Parser.checkEncoding(Array(s[i..<end]))
            }
            i = end + 2
        }

        static func checkEncoding(_ declaration: [UInt16]) throws {
            let word = Array("encoding".utf16)
            var at = -1
            var p = 0
            while p + word.count <= declaration.count {
                if Array(declaration[p..<(p + word.count)]) == word {
                    at = p
                    break
                }
                p += 1
            }
            if at < 0 { return }
            guard let q = declaration[at...].firstIndex(where: { $0 == 0x22 || $0 == 0x27 }),
                  let close = declaration[(q + 1)...].firstIndex(of: declaration[q])
            else { throw OfficeXml.bad("the encoding in the declaration is not quoted.") }
            let name = OfficeXml.str(lowered(Array(declaration[(q + 1)..<close])))
            if name != "utf-8" && name != "utf-16" && name != "us-ascii" {
                throw OfficeXml.refused("the encoding \(name) is not supported")
            }
        }

        mutating func flush() {
            if text.isEmpty { return }
            stack[stack.count - 1].element.children.append(.text(OfficeXml.str(text)))
            text.removeAll(keepingCapacity: true)
        }

        mutating func startTag() throws {
            i += 1
            let qname = try name()
            var raw: [(name: [UInt16], value: [UInt16])] = []
            var empty = false
            while true {
                let before = i
                skipSpace()
                if i >= s.count { throw OfficeXml.bad("a tag is not closed.") }
                if s[i] == 0x3E {
                    i += 1
                    break
                }
                if s[i] == 0x2F {
                    if i + 1 >= s.count || s[i + 1] != 0x3E { throw OfficeXml.bad("a tag is not closed.") }
                    i += 2
                    empty = true
                    break
                }
                if i == before { throw OfficeXml.bad("attributes need a space before them.") }
                let attrName = try name()
                skipSpace()
                if i >= s.count || s[i] != 0x3D { throw OfficeXml.bad("an attribute has no value.") }
                i += 1
                skipSpace()
                if i >= s.count || (s[i] != 0x22 && s[i] != 0x27) { throw OfficeXml.bad("an attribute value is not quoted.") }
                if raw.contains(where: { $0.name == attrName }) {
                    throw OfficeXml.bad("the attribute \(OfficeXml.str(attrName)) is given twice.")
                }
                raw.append((attrName, try attributeValue()))
                if raw.count > limits.maxAttributes { throw OfficeXml.refused("an element has too many attributes") }
            }
            if root != nil && stack.isEmpty { throw OfficeXml.bad("there is more than one root element.") }
            elements += 1
            if elements > limits.maxElements { throw OfficeXml.refused("the part has too many elements") }
            if stack.count >= limits.maxDepth { throw OfficeXml.refused("the elements are nested too deep") }
            if !stack.isEmpty { flush() }

            let xmlns = Array("xmlns".utf16)
            let xmlnsColon = Array("xmlns:".utf16)
            let xml = Array("xml".utf16)
            var declared: [[UInt16]] = []
            for (attrName, value) in raw {
                let prefix: [UInt16]
                if attrName == xmlns { prefix = [] }
                else if attrName.starts(with: xmlnsColon) { prefix = Array(attrName[xmlnsColon.count...]) }
                else { continue }
                if prefix == xmlns || (prefix == xml && value != OfficeXml.xmlUri) || (!prefix.isEmpty && value.isEmpty) {
                    throw OfficeXml.bad("a namespace declaration is not allowed.")
                }
                if prefix != xml { try bind(prefix, value, &declared) }
            }
            let (uri, local) = try resolve(qname, true)
            var attributes: [OfficeXmlAttribute] = []
            var seen: [([UInt16], [UInt16])] = []
            for (attrName, value) in raw {
                if attrName == xmlns || attrName.starts(with: xmlnsColon) { continue }
                let (auri, alocal) = try resolve(attrName, false)
                if seen.contains(where: { $0.0 == auri && $0.1 == alocal }) {
                    throw OfficeXml.bad("the attribute \(OfficeXml.str(attrName)) is given twice.")
                }
                seen.append((auri, alocal))
                attributes.append(OfficeXmlAttribute(uri: OfficeXml.str(auri), name: OfficeXml.str(alocal), value: OfficeXml.str(value)))
            }
            let el = OfficeXmlElement(uri: OfficeXml.str(uri), name: OfficeXml.str(local), attributes: attributes)
            if let top = stack.last { top.element.children.append(.element(el)) } else { root = el }
            if empty { unbind(declared) } else { stack.append(Frame(el, qname, declared)) }
        }

        static func isLocalName(_ n: [UInt16]) -> Bool {
            !n.isEmpty && isNameStart(n[0]) && n[0] != 0x3A && !n.contains(0x3A)
        }

        mutating func bind(_ prefix: [UInt16], _ uri: [UInt16], _ declared: inout [[UInt16]]) throws {
            if !prefix.isEmpty && !Parser.isLocalName(prefix) { throw OfficeXml.bad("a namespace prefix is not a name.") }
            bound[prefix, default: []].append(uri)
            declared.append(prefix)
        }

        mutating func unbind(_ declared: [[UInt16]]) {
            for prefix in declared { bound[prefix]!.removeLast() }
        }

        func resolve(_ qname: [UInt16], _ isElement: Bool) throws -> ([UInt16], [UInt16]) {
            guard let colon = qname.firstIndex(of: 0x3A) else {
                if isElement, let last = bound[[UInt16]()]?.last { return (last, qname) }
                return ([], qname)
            }
            let prefix = Array(qname[..<colon])
            let local = Array(qname[(colon + 1)...])
            if !Parser.isLocalName(local) || !Parser.isLocalName(prefix) {
                throw OfficeXml.bad("the name \(OfficeXml.str(qname)) is not a qualified name.")
            }
            guard let last = bound[prefix]?.last else {
                throw OfficeXml.bad("the prefix \(OfficeXml.str(prefix)) is not declared.")
            }
            return (last, local)
        }

        mutating func attributeValue() throws -> [UInt16] {
            let quote = s[i]
            i += 1
            var sb: [UInt16] = []
            while true {
                if i >= s.count { throw OfficeXml.bad("an attribute value is not closed.") }
                let c = s[i]
                if c == quote {
                    i += 1
                    return sb
                }
                if c == 0x3C { throw OfficeXml.bad("an attribute value has a <.") }
                i += 1
                if c == 0x26 {
                    sb += try reference()
                } else if c == 0x0D {
                    if i < s.count && s[i] == 0x0A { i += 1 }
                    sb.append(0x20)
                } else {
                    sb.append(c == 0x0A || c == 0x09 ? 0x20 : c)
                }
            }
        }

        mutating func endTag() throws {
            i += 2
            let qname = try name()
            skipSpace()
            if i >= s.count || s[i] != 0x3E { throw OfficeXml.bad("an end tag is not closed.") }
            i += 1
            guard let top = stack.last, top.qname == qname else {
                throw OfficeXml.bad("the end tag \(OfficeXml.str(qname)) does not match.")
            }
            flush()
            unbind(top.declared)
            stack.removeLast()
        }
    }
}
