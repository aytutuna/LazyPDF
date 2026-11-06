import Foundation

// No C# twin: what XmlDocument is to RedactionMetadata.cs, as far as the XMP packets need it. The C# reads a packet with an
// XmlTextReader that has Namespaces off, DTDs prohibited and white space kept, so a name is the whole qualified name and a
// prefix nobody declared is fine (producers leave them undeclared). The reader of the Structure layer resolves prefixes and
// refuses those, so it cannot stand in.
//
// The parser refuses a DOCTYPE, an undeclared entity, a duplicate attribute, a name or character XML does not allow, text
// outside the root, more than one root and nesting past `maxDepth`. The writer refuses the namespace bindings XmlTextWriter
// refuses (xmlns:xmlns, and a prefix bound to nothing), which the reader took, and the caller then drops the packet.

class DomNode {}

final class DomAttribute {
    let name: String
    var value: String

    init(_ name: String, _ value: String) {
        self.name = name
        self.value = value
    }
}

final class DomElement: DomNode {
    let name: String
    var attributes: [DomAttribute] = []
    var children: [DomNode] = []
    // <a/> as read; false once the element has content.
    var isEmpty = false

    init(_ name: String) {
        self.name = name
    }

    func removeAll() {
        attributes = []
        children = []
    }

    func append(_ child: DomNode) {
        children.append(child)
        isEmpty = false
    }
}

final class DomText: DomNode {
    var value: String
    let isCData: Bool

    init(_ value: String, isCData: Bool = false) {
        self.value = value
        self.isCData = isCData
    }
}

/// White space between nodes, which XmlDocument keeps as a node of its own when PreserveWhitespace is set.
final class DomWhitespace: DomNode {
    let value: String

    init(_ value: String) {
        self.value = value
    }
}

final class DomComment: DomNode {
    var value: String

    init(_ value: String) {
        self.value = value
    }
}

final class DomInstruction: DomNode {
    let target: String
    let data: String

    init(_ target: String, _ data: String) {
        self.target = target
        self.data = data
    }
}

final class DomDeclaration: DomNode {
    var version: String
    var encoding: String
    var standalone: String

    init(_ version: String, _ encoding: String, _ standalone: String) {
        self.version = version
        self.encoding = encoding
        self.standalone = standalone
    }
}

struct DomError: Error {}

final class DomDocument {
    static let maxDepth = 128

    var children: [DomNode] = []

    /// Nil when the text is not well-formed XML of the kind described at the top of this file.
    static func parse(_ text: String) -> DomDocument? {
        var parser = DomParser(Array(text.unicodeScalars))
        return try? parser.parseDocument()
    }

    /// Every node under `roots`, themselves first, in document order. The children of a node are read when the node comes up.
    static func walk(_ roots: [DomNode], _ visit: (DomNode) -> Void) {
        var pending: [DomNode] = roots.reversed()
        while let node = pending.popLast() {
            visit(node)
            if let element = node as? DomElement { pending.append(contentsOf: element.children.reversed()) }
        }
    }

    /// Every element of the document, in document order.
    var elements: [DomElement] {
        var found: [DomElement] = []
        DomDocument.walk(children) { if let e = $0 as? DomElement { found.append(e) } }
        return found
    }

    /// The document as text; throws what XmlTextWriter refuses.
    func outerXml() throws -> String {
        var out = ""
        for child in children { try DomDocument.write(child, &out) }
        return out
    }

    private static func write(_ node: DomNode, _ out: inout String) throws {
        switch node {
        case let e as DomElement:
            out += "<" + e.name
            for a in e.attributes {
                if a.name == "xmlns:xmlns" || (a.name.hasPrefix("xmlns:") && a.value.isEmpty) { throw DomError() }
                if a.name == "xmlns:xml" && a.value != "http://www.w3.org/XML/1998/namespace" { throw DomError() }
                out += " " + a.name + "=\"" + escape(a.value, attribute: true) + "\""
            }
            if e.children.isEmpty && e.isEmpty {
                out += " />"
            } else {
                out += ">"
                for child in e.children { try write(child, &out) }
                out += "</" + e.name + ">"
            }
        case let t as DomText:
            out += t.isCData ? "<![CDATA[" + t.value.replacingOccurrences(of: "]]>", with: "]]]]><![CDATA[>") + "]]>" : escape(t.value, attribute: false)
        case let w as DomWhitespace:
            out += w.value
        case let c as DomComment:
            out += "<!--" + c.value + "-->"
        case let p as DomInstruction:
            out += "<?" + p.target + (p.data.isEmpty ? "" : " " + p.data) + "?>"
        case let d as DomDeclaration:
            out += "<?xml version=\"" + d.version + "\"" + (d.encoding.isEmpty ? "" : " encoding=\"" + d.encoding + "\"")
                + (d.standalone.isEmpty ? "" : " standalone=\"" + d.standalone + "\"") + "?>"
        default:
            break
        }
    }

    private static func escape(_ text: String, attribute: Bool) -> String {
        var out = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": out.append(contentsOf: "&amp;".unicodeScalars)
            case "<": out.append(contentsOf: "&lt;".unicodeScalars)
            case ">": out.append(contentsOf: "&gt;".unicodeScalars)
            case "\"" where attribute: out.append(contentsOf: "&quot;".unicodeScalars)
            case "\r": out.append(contentsOf: "&#xD;".unicodeScalars)
            case "\n" where attribute: out.append(contentsOf: "&#xA;".unicodeScalars)
            case "\t" where attribute: out.append(contentsOf: "&#x9;".unicodeScalars)
            default: out.append(scalar)
            }
        }
        return String(out)
    }
}

private struct DomParser {
    private let s: [Unicode.Scalar]
    private var i = 0

    init(_ scalars: [Unicode.Scalar]) {
        var chars = scalars
        if chars.first == "\u{FEFF}" { chars.removeFirst() }
        // Line ends read as LF.
        var normal: [Unicode.Scalar] = []
        normal.reserveCapacity(chars.count)
        var k = 0
        while k < chars.count {
            if chars[k] == "\r" {
                normal.append("\n")
                if k + 1 < chars.count && chars[k + 1] == "\n" { k += 1 }
            } else {
                normal.append(chars[k])
            }
            k += 1
        }
        s = normal
    }

    private static func isSpace(_ c: Unicode.Scalar) -> Bool { c == " " || c == "\t" || c == "\n" || c == "\r" }

    private static func isChar(_ c: Unicode.Scalar) -> Bool {
        let v = c.value
        return v == 9 || v == 10 || v == 13 || (v >= 0x20 && v <= 0xD7FF) || (v >= 0xE000 && v <= 0xFFFD) || (v >= 0x10000 && v <= 0x10FFFF)
    }

    private func starts(_ text: String) -> Bool {
        var at = i
        for c in text.unicodeScalars {
            if at >= s.count || s[at] != c { return false }
            at += 1
        }
        return true
    }

    private mutating func skipSpace() -> Bool {
        let before = i
        while i < s.count && Self.isSpace(s[i]) { i += 1 }
        return i > before
    }

    // A name, colons allowed (Namespaces is off).
    private mutating func readName() throws -> String {
        guard i < s.count, s[i] == ":" || XmlNameTables.isStart(s[i].value) else { throw DomError() }
        var name = String.UnicodeScalarView()
        while i < s.count, s[i] == ":" || XmlNameTables.isPart(s[i].value) {
            name.append(s[i])
            i += 1
        }
        return String(name)
    }

    private mutating func readQuoted() throws -> String {
        guard i < s.count, s[i] == "\"" || s[i] == "'" else { throw DomError() }
        let quote = s[i]
        i += 1
        var value = String.UnicodeScalarView()
        while i < s.count && s[i] != quote {
            guard Self.isChar(s[i]) else { throw DomError() }
            value.append(s[i])
            i += 1
        }
        guard i < s.count else { throw DomError() }
        i += 1
        return String(value)
    }

    private mutating func skipEquals() throws {
        _ = skipSpace()
        guard i < s.count, s[i] == "=" else { throw DomError() }
        i += 1
        _ = skipSpace()
    }

    mutating func parseDocument() throws -> DomDocument {
        let document = DomDocument()
        if starts("<?xml") && i + 5 < s.count && Self.isSpace(s[i + 5]) {
            i += 5
            _ = skipSpace()
            guard try readName() == "version" else { throw DomError() }
            try skipEquals()
            let version = try readQuoted()
            guard version == "1.0" else { throw DomError() }
            var encoding = "", standalone = ""
            while true {
                let spaced = skipSpace()
                if starts("?>") {
                    i += 2
                    break
                }
                guard spaced else { throw DomError() }
                let key = try readName()
                try skipEquals()
                let value = try readQuoted()
                if key == "encoding" && encoding.isEmpty && standalone.isEmpty {
                    encoding = value
                } else if key == "standalone" && standalone.isEmpty && (value == "yes" || value == "no") {
                    standalone = value
                } else {
                    throw DomError()
                }
            }
            document.children.append(DomDeclaration(version, encoding, standalone))
        }
        var open: [DomElement] = []
        var rooted = false
        while i < s.count {
            if s[i] == "<" {
                if starts("<!--") {
                    try add(DomComment(try readComment()), document, open)
                } else if starts("<![CDATA[") {
                    if open.isEmpty { throw DomError() }
                    try add(DomText(try readCData(), isCData: true), document, open)
                } else if starts("<?") {
                    try add(try readInstruction(), document, open)
                } else if starts("<!") {
                    throw DomError()
                } else if starts("</") {
                    i += 2
                    let name = try readName()
                    _ = skipSpace()
                    guard let element = open.last, element.name == name, i < s.count, s[i] == ">" else { throw DomError() }
                    i += 1
                    open.removeLast()
                } else {
                    if open.isEmpty && rooted { throw DomError() }
                    if open.count > DomDocument.maxDepth { throw DomError() }
                    let element = try readStartTag()
                    try add(element.node, document, open)
                    rooted = true
                    if !element.closed { open.append(element.node) }
                }
            } else {
                var literal = true
                var text = String.UnicodeScalarView()
                while i < s.count && s[i] != "<" {
                    if s[i] == "&" {
                        text.append(try readReference())
                        literal = false
                        continue
                    }
                    if s[i] == "]" && starts("]]>") { throw DomError() }
                    guard Self.isChar(s[i]) else { throw DomError() }
                    if !Self.isSpace(s[i]) { literal = false }
                    text.append(s[i])
                    i += 1
                }
                if open.isEmpty {
                    if !literal { throw DomError() }
                    try add(DomWhitespace(String(text)), document, open)
                } else {
                    try add(literal ? DomWhitespace(String(text)) : DomText(String(text)), document, open)
                }
            }
        }
        if !open.isEmpty || !rooted { throw DomError() }
        return document
    }

    private func add(_ node: DomNode, _ document: DomDocument, _ open: [DomElement]) throws {
        if let parent = open.last {
            // A node inside an element is as deep as the elements around it.
            if open.count > DomDocument.maxDepth { throw DomError() }
            parent.append(node)
        } else {
            document.children.append(node)
        }
    }

    private mutating func readStartTag() throws -> (node: DomElement, closed: Bool) {
        i += 1
        let element = DomElement(try readName())
        var seen = Set<OrdinalString>()
        while true {
            let spaced = skipSpace()
            guard i < s.count else { throw DomError() }
            if s[i] == ">" {
                i += 1
                return (element, false)
            }
            if s[i] == "/" {
                guard i + 1 < s.count, s[i + 1] == ">" else { throw DomError() }
                i += 2
                element.isEmpty = true
                return (element, true)
            }
            guard spaced else { throw DomError() }
            let name = try readName()
            guard seen.insert(OrdinalString(name)).inserted else { throw DomError() }
            try skipEquals()
            element.attributes.append(DomAttribute(name, try readAttributeValue()))
        }
    }

    private mutating func readAttributeValue() throws -> String {
        guard i < s.count, s[i] == "\"" || s[i] == "'" else { throw DomError() }
        let quote = s[i]
        i += 1
        var value = String.UnicodeScalarView()
        while i < s.count && s[i] != quote {
            if s[i] == "&" {
                value.append(try readReference())
                continue
            }
            guard s[i] != "<", Self.isChar(s[i]) else { throw DomError() }
            value.append(s[i])
            i += 1
        }
        guard i < s.count else { throw DomError() }
        i += 1
        return String(value)
    }

    // The five entities and character references; anything else is undeclared.
    private mutating func readReference() throws -> Unicode.Scalar {
        i += 1
        var name = ""
        while i < s.count && s[i] != ";" && name.unicodeScalars.count < 12 {
            name.unicodeScalars.append(s[i])
            i += 1
        }
        guard i < s.count, s[i] == ";" else { throw DomError() }
        i += 1
        switch name {
        case "lt": return "<"
        case "gt": return ">"
        case "amp": return "&"
        case "quot": return "\""
        case "apos": return "'"
        default: break
        }
        guard name.hasPrefix("#") else { throw DomError() }
        let hex = name.hasPrefix("#x")
        let digits = String(name.dropFirst(hex ? 2 : 1))
        guard !digits.isEmpty, digits.unicodeScalars.allSatisfy({ hex ? $0.properties.isASCIIHexDigit : ($0.value >= 0x30 && $0.value <= 0x39) }),
              let code = UInt32(digits, radix: hex ? 16 : 10), let scalar = Unicode.Scalar(code), Self.isChar(scalar) else { throw DomError() }
        return scalar
    }

    private mutating func readComment() throws -> String {
        i += 4
        var value = String.UnicodeScalarView()
        while i < s.count {
            if starts("-->") {
                i += 3
                return String(value)
            }
            if starts("--") { throw DomError() }
            guard Self.isChar(s[i]) else { throw DomError() }
            value.append(s[i])
            i += 1
        }
        throw DomError()
    }

    private mutating func readCData() throws -> String {
        i += 9
        var value = String.UnicodeScalarView()
        while i < s.count {
            if starts("]]>") {
                i += 3
                return String(value)
            }
            guard Self.isChar(s[i]) else { throw DomError() }
            value.append(s[i])
            i += 1
        }
        throw DomError()
    }

    private mutating func readInstruction() throws -> DomInstruction {
        i += 2
        let target = try readName()
        // The target xml in any case is reserved for the declaration.
        if target.lowercased() == "xml" { throw DomError() }
        var data = String.UnicodeScalarView()
        let spaced = skipSpace()
        while i < s.count {
            if starts("?>") {
                i += 2
                return DomInstruction(target, String(data))
            }
            guard spaced, Self.isChar(s[i]) else { throw DomError() }
            data.append(s[i])
            i += 1
        }
        throw DomError()
    }
}
