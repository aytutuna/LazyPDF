import Foundation

// What System.Xml.Linq is to Xmp.cs, as far as the XMP packet needs it: a reader for well-formed XML with namespaces, a
// tree that keeps the order of attributes and children, and a writer for it. Not part of the C# engine's files; the
// C# gets all of it from the .NET libraries.
//
// The reader refuses what XmlReader refuses with DtdProcessing.Prohibit: a DOCTYPE, an undeclared entity or prefix, a
// duplicate attribute, a name or character XML does not allow, bytes that are not valid in the encoding, text outside the
// root, more than one root. Nesting deeper than 1000 levels is refused too (XmlReader has no limit; here a deeper tree
// would be freed recursively). Names are equal when their scalars are, as in .NET, not when they are canonically
// equivalent. Line ends read as LF, and the writer ends every line with LF where XmlWriter uses Environment.NewLine.

/// A string that is equal to another when their scalars are, which is how .NET compares names; Swift's own == and hash
/// treat canonical equivalents as the same string.
struct OrdinalString: Hashable {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    static func == (a: OrdinalString, b: OrdinalString) -> Bool {
        XmlParser.same(a.text, b.text)
    }

    func hash(into hasher: inout Hasher) {
        for byte in text.utf8 { hasher.combine(byte) }
    }
}

struct XmlName: Hashable {
    let namespace: String
    let local: String

    init(_ namespace: String, _ local: String) {
        self.namespace = namespace
        self.local = local
    }

    static func == (a: XmlName, b: XmlName) -> Bool {
        XmlParser.same(a.namespace, b.namespace) && XmlParser.same(a.local, b.local)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(OrdinalString(namespace))
        hasher.combine(OrdinalString(local))
    }
}

enum XmlNamespaces {
    static let xml = "http://www.w3.org/XML/1998/namespace"
    static let xmlns = "http://www.w3.org/2000/xmlns/"
}

final class XmlAttribute {
    let name: XmlName
    // The prefix as read, nil for one made in code. The writer here looks the prefix up again, as XElement does.
    let prefix: String?
    var value: String

    init(_ name: XmlName, _ value: String, prefix: String? = nil) {
        self.name = name
        self.value = value
        self.prefix = prefix
    }

    /// xmlns="..." or xmlns:p="...".
    var isNamespaceDeclaration: Bool {
        name.namespace.isEmpty ? XmlParser.same(name.local, "xmlns") : XmlParser.same(name.namespace, XmlNamespaces.xmlns)
    }

    /// The prefix a declaration binds; empty for the default namespace.
    var declaredPrefix: String { name.namespace.isEmpty ? "" : name.local }
}

class XmlNode {
    weak var parent: XmlElement?
}

final class XmlText: XmlNode {
    var value: String
    let isCData: Bool

    init(_ value: String, isCData: Bool = false) {
        self.value = value
        self.isCData = isCData
    }
}

final class XmlComment: XmlNode {
    let value: String

    init(_ value: String) {
        self.value = value
    }
}

final class XmlInstruction: XmlNode {
    let target: String
    let data: String

    init(_ target: String, _ data: String) {
        self.target = target
        self.data = data
    }
}

final class XmlElement: XmlNode {
    let name: XmlName
    // The prefix as read, nil for an element made in code. The writer here looks the prefix up again, as XElement does.
    let prefix: String?
    var attributes: [XmlAttribute] = []
    private(set) var children: [XmlNode] = []
    // False for <a/> and for an element made without content; true once it has content, even an empty string (<a></a>).
    private(set) var hasContent = false

    init(_ name: XmlName, prefix: String? = nil) {
        self.name = name
        self.prefix = prefix
    }

    convenience init(_ name: XmlName, text: String) {
        self.init(name)
        append(XmlText(text))
    }

    func append(_ node: XmlNode) {
        node.parent = self
        children.append(node)
        hasContent = true
    }

    func markHasContent() {
        hasContent = true
    }

    /// Takes the node out of the element it is in, as XNode.Remove does.
    func remove() {
        guard let owner = parent, let at = owner.children.firstIndex(where: { $0 === self }) else { return }
        owner.children.remove(at: at)
        if owner.children.isEmpty { owner.hasContent = false }
        parent = nil
    }

    func attribute(_ name: XmlName) -> XmlAttribute? {
        attributes.first { $0.name == name }
    }

    func removeAttribute(_ name: XmlName) {
        attributes.removeAll { $0.name == name }
    }

    func setAttributeValue(_ name: XmlName, _ value: String) {
        if let existing = attribute(name) {
            existing.value = value
        } else {
            attributes.append(XmlAttribute(name, value))
        }
    }

    /// The child elements called `name`, in order.
    func elements(_ name: XmlName) -> [XmlElement] {
        var found: [XmlElement] = []
        for child in children {
            if let e = child as? XmlElement, e.name == name { found.append(e) }
        }
        return found
    }

    func element(_ name: XmlName) -> XmlElement? {
        for child in children {
            if let e = child as? XmlElement, e.name == name { return e }
        }
        return nil
    }

    /// The first descendant called `name` in document order.
    func firstDescendant(_ name: XmlName) -> XmlElement? {
        var work: [XmlNode] = children.reversed()
        while let node = work.popLast() {
            guard let e = node as? XmlElement else { continue }
            if e.name == name { return e }
            work.append(contentsOf: e.children.reversed())
        }
        return nil
    }

    /// The text of the element and everything under it (XElement.Value).
    var value: String {
        var text = ""
        var work: [XmlNode] = children.reversed()
        while let node = work.popLast() {
            if let t = node as? XmlText {
                text += t.value
            } else if let e = node as? XmlElement {
                work.append(contentsOf: e.children.reversed())
            }
        }
        return text
    }

    /// The prefix a namespace has here (XElement.GetPrefixOfNamespace); empty for the default namespace, nil when none is
    /// declared. An attribute cannot use the default one, so `allowDefault` is false for it, and XElement does not
    /// offer it either.
    func prefixOfNamespace(_ uri: String, allowDefault: Bool = true) -> String? {
        if XmlParser.same(uri, XmlNamespaces.xml) { return "xml" }
        var inScope: [OrdinalString: String]?
        var current: XmlElement? = self
        while let element = current {
            for a in element.attributes where a.isNamespaceDeclaration && XmlParser.same(a.value, uri) {
                let p = a.declaredPrefix
                if p.isEmpty && !allowDefault { continue }
                let bound = inScope ?? namespacesInScope()
                inScope = bound
                if let found = bound[OrdinalString(p)], XmlParser.same(found, uri) { return p }
            }
            current = element.parent
        }
        return nil
    }

    // What each prefix stands for here, the nearest declaration winning.
    private func namespacesInScope() -> [OrdinalString: String] {
        var bound: [OrdinalString: String] = [:]
        var current: XmlElement? = self
        while let element = current {
            for a in element.attributes where a.isNamespaceDeclaration {
                let key = OrdinalString(a.declaredPrefix)
                if bound[key] == nil { bound[key] = a.value }
            }
            current = element.parent
        }
        return bound
    }
}

final class XmlDocument {
    private(set) var children: [XmlNode] = []

    var root: XmlElement? {
        for child in children {
            if let e = child as? XmlElement { return e }
        }
        return nil
    }

    func append(_ node: XmlNode) {
        children.append(node)
    }

    /// The first element called `name` anywhere in the document, in document order.
    func firstDescendant(_ name: XmlName) -> XmlElement? {
        guard let root else { return nil }
        return root.name == name ? root : root.firstDescendant(name)
    }

    /// Nil when the bytes are not well-formed XML of the kind described at the top of this file.
    static func parse(_ bytes: [UInt8]) -> XmlDocument? {
        guard var scalars = XmlEncoding.scalars(bytes) else { return nil }
        scalars = XmlEncoding.normalizeLineEnds(scalars)
        var parser = XmlParser(scalars)
        return try? parser.parseDocument()
    }

    /// UTF-8 without a byte order mark or a declaration, nothing added between the nodes.
    func serialize() -> [UInt8] {
        var writer = XmlWriter()
        writer.write(self)
        return writer.output
    }
}

// The namespace declarations in force while writing, as the ElementWriter of System.Xml.Linq keeps them: the prefix of a
// namespace is the one declared last that no later declaration of the same prefix hides.
private struct NamespaceScope {
    private var entries: [(prefix: OrdinalString, uri: OrdinalString, hides: Int?)] = []
    private var newest: [OrdinalString: Int] = [:]
    private var byUri: [OrdinalString: [Int]] = [:]
    private var marks: [(entries: Int, written: Int, madeUp: Int)] = []
    // The prefixes XmlWriter made up for attributes, innermost last. XElement's resolver never hears of them, so a name is
    // not given one of these; an attribute in the same namespace reuses it.
    private var madeUp: [OrdinalString: [String]] = [:]
    private var madeUpOrder: [OrdinalString] = []
    // How many declarations XmlWriter has met so far, which the prefix it makes up for a namespace is numbered by. The
    // declarations of an element count as it reaches each of its attributes, where `push` knows them all at once.
    private(set) var written = 0
    private var withDefault: [OrdinalString: String?] = [:]
    private var withoutDefault: [OrdinalString: String?] = [:]

    mutating func push(_ declarations: [(prefix: String, uri: String)]) {
        marks.append((entries.count, written, madeUpOrder.count))
        for d in declarations { declare(d.prefix, d.uri) }
    }

    mutating func declare(_ prefix: String, _ uri: String) {
        let key = OrdinalString(prefix), target = OrdinalString(uri)
        entries.append((key, target, newest[key]))
        newest[key] = entries.count - 1
        byUri[target, default: []].append(entries.count - 1)
        forget()
    }

    mutating func pop() {
        let mark = marks.removeLast()
        written = mark.written
        while madeUpOrder.count > mark.madeUp { madeUp[madeUpOrder.removeLast()]?.removeLast() }
        if entries.count > mark.entries { forget() }
        while entries.count > mark.entries {
            let entry = entries.removeLast()
            newest[entry.prefix] = entry.hides
            byUri[entry.uri]?.removeLast()
        }
    }

    private mutating func forget() {
        withDefault.removeAll(keepingCapacity: true)
        withoutDefault.removeAll(keepingCapacity: true)
    }

    mutating func prefix(of uri: String, allowDefault: Bool) -> String? {
        let key = OrdinalString(uri)
        if let known = allowDefault ? withDefault[key] : withoutDefault[key] { return known }
        var found: String?
        for at in (byUri[key] ?? []).reversed() {
            let entry = entries[at]
            if newest[entry.prefix] == at && (allowDefault || !entry.prefix.text.isEmpty) {
                found = entry.prefix.text
                break
            }
        }
        if allowDefault { withDefault[key] = found } else { withoutDefault[key] = found }
        return found
    }

    mutating func wrote() {
        written += 1
    }

    func madeUpPrefix(of uri: String) -> String? {
        madeUp[OrdinalString(uri)]?.last
    }

    // The name XmlWriter gives a namespace that has no prefix yet: p and the number of declarations written so far.
    mutating func makeUpPrefix(for uri: String) -> String {
        var n = written + 1
        while newest[OrdinalString("p\(n)")] != nil { n += 1 }
        let key = OrdinalString(uri)
        madeUp[key, default: []].append("p\(n)")
        madeUpOrder.append(key)
        written += 1
        return "p\(n)"
    }
}

private struct XmlWriter {
    var output: [UInt8] = []
    private var scope = NamespaceScope()

    private enum Step {
        case node(XmlNode)
        case close(String)
    }

    mutating func write(_ document: XmlDocument) {
        var work: [Step] = document.children.reversed().map { Step.node($0) }
        while let step = work.popLast() {
            switch step {
            case .node(let node):
                if let element = node as? XmlElement {
                    let name = start(element)
                    if element.hasContent {
                        put(">")
                        work.append(.close(name))
                        work.append(contentsOf: element.children.reversed().map { Step.node($0) })
                    } else {
                        put(" />")
                        scope.pop()
                    }
                } else if let text = node as? XmlText {
                    if text.isCData {
                        put("<![CDATA[" + text.value + "]]>")
                    } else {
                        put(escape(text.value, attribute: false))
                    }
                } else if let comment = node as? XmlComment {
                    put("<!--" + comment.value + "-->")
                } else if let instruction = node as? XmlInstruction {
                    put("<?" + instruction.target + (instruction.data.isEmpty ? "" : " " + instruction.data) + "?>")
                }
            case .close(let name):
                put("</" + name + ">")
                scope.pop()
            }
        }
    }

    private mutating func put(_ text: String) {
        output.append(contentsOf: Array(text.utf8))
    }

    // Writes the start tag up to its end and returns the name it used. Like XElement.Save, the prefix of every name is
    // looked up again rather than kept as read; a namespace with no prefix gets a declaration, as XmlWriter adds one.
    private mutating func start(_ element: XmlElement) -> String {
        scope.push(element.attributes.compactMap { a -> (prefix: String, uri: String)? in
            a.isNamespaceDeclaration ? (prefix: a.declaredPrefix, uri: a.value) : nil
        })
        var added = ""
        var name = element.name.local
        let uri = element.name.namespace
        if !uri.isEmpty {
            if let prefix = scope.prefix(of: uri, allowDefault: true) {
                if !prefix.isEmpty { name = prefix + ":" + name }
            } else {
                scope.declare("", uri)
                scope.wrote()
                added += " xmlns=\"" + escape(uri, attribute: true) + "\""
            }
        }
        var text = "<" + name
        for a in element.attributes {
            var attributeName = a.name.local
            if a.isNamespaceDeclaration {
                scope.wrote()
                attributeName = a.declaredPrefix.isEmpty ? "xmlns" : "xmlns:" + a.declaredPrefix
            } else if !a.name.namespace.isEmpty {
                let prefix: String
                if XmlParser.same(a.name.namespace, XmlNamespaces.xml) {
                    prefix = "xml"
                } else if let known = scope.prefix(of: a.name.namespace, allowDefault: false) ?? scope.madeUpPrefix(of: a.name.namespace) {
                    prefix = known
                } else {
                    prefix = scope.makeUpPrefix(for: a.name.namespace)
                    added += " xmlns:" + prefix + "=\"" + escape(a.name.namespace, attribute: true) + "\""
                }
                attributeName = prefix + ":" + a.name.local
            }
            text += " " + attributeName + "=\"" + escape(a.value, attribute: true) + "\""
        }
        put(text + added)
        return name
    }

    private func escape(_ text: String, attribute: Bool) -> String {
        var result = String.UnicodeScalarView()
        var afterReturn = false
        for c in text.unicodeScalars {
            switch c {
            case "&": result.append(contentsOf: "&amp;".unicodeScalars)
            case "<": result.append(contentsOf: "&lt;".unicodeScalars)
            case ">": result.append(contentsOf: "&gt;".unicodeScalars)
            case "\"" where attribute: result.append(contentsOf: "&quot;".unicodeScalars)
            case "\t" where attribute: result.append(contentsOf: "&#x9;".unicodeScalars)
            case "\n" where attribute: result.append(contentsOf: "&#xA;".unicodeScalars)
            case "\r" where attribute: result.append(contentsOf: "&#xD;".unicodeScalars)
            case "\r": result.append("\n")
            case "\n" where afterReturn: break
            default: result.append(c)
            }
            afterReturn = c == "\r"
        }
        return String(result)
    }
}

enum XmlSyntax {
    /// What XmlConvert.VerifyNCName accepts: a name with no colon.
    static func isNCName(_ text: String) -> Bool {
        guard let first = text.unicodeScalars.first, XmlNameTables.isStart(first.value) else { return false }
        return text.unicodeScalars.allSatisfy { XmlNameTables.isPart($0.value) }
    }
}
