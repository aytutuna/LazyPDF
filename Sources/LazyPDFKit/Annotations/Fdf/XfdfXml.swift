import Foundation

// No C# twin: what the XFDF code takes from System.Xml. PdfXfdf.Write saves an XDocument through an XmlWriter with
// Indent = true, and PdfXfdf.Read turns the children of /RC back into text with XNode.ToString(), which is the same
// writer on one node. The tree is the Structure layer's XmlTree; its own writer does not indent.
//
// The rules of the indenting writer: an element starts on a new line, indented two spaces a level, unless the element
// it is in has had text (or CDATA) written, which switches indenting off until that element ends; an element with
// children ends on a line of its own, an element without content is written <a /> and one with only an empty string
// <a></a>. A namespace the element needs and the writer does not have in scope is declared after the attributes, so
// <p xmlns=""> appears under a default namespace. Line ends are LF; XmlWriter uses Environment.NewLine, which is CRLF on
// Windows.

enum XfdfXml {
    /// The XML declaration and the element, as XDocument.Save(XmlWriter) writes them with a UTF-8 encoding and Indent.
    static func document(_ root: XmlElement) -> [UInt8] {
        var writer = IndentWriter()
        writer.out = "<?xml version=\"1.0\" encoding=\"utf-8\"?>"
        writer.write(root)
        return Array(writer.out.utf8)
    }

    /// XNode.ToString(): the node alone, indented.
    static func string(_ node: XmlNode) -> String {
        var writer = IndentWriter()
        writer.write(node)
        return writer.out
    }

    /// The element as XElement.Parse reads it: white space between tags is not kept, except under xml:space="preserve".
    static func withoutBlankText(_ root: XmlElement) -> XmlElement {
        let spaceName = XmlName(XmlNamespaces.xml, "space")
        func preserving(_ element: XmlElement, _ inherited: Bool) -> Bool {
            switch element.attribute(spaceName)?.value {
            case "preserve": return true
            case "default": return false
            default: return inherited
            }
        }
        func shell(_ element: XmlElement) -> XmlElement {
            let copy = XmlElement(element.name, prefix: element.prefix)
            copy.attributes = element.attributes
            if element.hasContent { copy.markHasContent() }
            return copy
        }

        let top = shell(root)
        var work: [(source: XmlElement, target: XmlElement, preserve: Bool)] = [(root, top, preserving(root, false))]
        while let (source, target, preserve) = work.popLast() {
            for child in source.children {
                if let element = child as? XmlElement {
                    let copy = shell(element)
                    target.append(copy)
                    work.append((element, copy, preserving(element, preserve)))
                } else if let text = child as? XmlText {
                    let blank = !text.isCData && text.value.unicodeScalars.allSatisfy { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" }
                    if !blank || preserve { target.append(XmlText(text.value, isCData: text.isCData)) }
                } else if let comment = child as? XmlComment {
                    target.append(XmlComment(comment.value))
                } else if let instruction = child as? XmlInstruction {
                    target.append(XmlInstruction(instruction.target, instruction.data))
                }
            }
        }
        return top
    }

    static func escapeText(_ text: String) -> String {
        var result = String.UnicodeScalarView()
        var previousReturn = false
        for c in text.unicodeScalars {
            if c == "\n" && previousReturn {
                previousReturn = false
                continue
            }
            previousReturn = c == "\r"
            switch c {
            case "&": result.append(contentsOf: "&amp;".unicodeScalars)
            case "<": result.append(contentsOf: "&lt;".unicodeScalars)
            case ">": result.append(contentsOf: "&gt;".unicodeScalars)
            case "\r", "\n": result.append("\n")
            default: result.append(c)
            }
        }
        return String(result)
    }

    static func escapeAttribute(_ text: String) -> String {
        var result = String.UnicodeScalarView()
        for c in text.unicodeScalars {
            switch c {
            case "&": result.append(contentsOf: "&amp;".unicodeScalars)
            case "<": result.append(contentsOf: "&lt;".unicodeScalars)
            case ">": result.append(contentsOf: "&gt;".unicodeScalars)
            case "\"": result.append(contentsOf: "&quot;".unicodeScalars)
            case "\t": result.append(contentsOf: "&#x9;".unicodeScalars)
            case "\n": result.append(contentsOf: "&#xA;".unicodeScalars)
            case "\r": result.append(contentsOf: "&#xD;".unicodeScalars)
            default: result.append(c)
            }
        }
        return String(result)
    }
}

private struct IndentWriter {
    private enum Step {
        case node(XmlNode)
        case close(XmlElement, String)
    }

    var out = ""
    private var mixed = false
    private var mixedStack: [Bool] = []
    private var level = 0
    private var frames: [[(prefix: String, uri: String)]] = []
    private var generated = 0

    mutating func write(_ root: XmlNode) {
        var work: [Step] = [.node(root)]
        while let step = work.popLast() {
            switch step {
            case .node(let node):
                if let element = node as? XmlElement {
                    start(element, &work)
                } else if let text = node as? XmlText {
                    mixed = true
                    out += text.isCData ? "<![CDATA[" + text.value + "]]>" : XfdfXml.escapeText(text.value)
                } else if let comment = node as? XmlComment {
                    indent()
                    out += "<!--" + comment.value + "-->"
                } else if let instruction = node as? XmlInstruction {
                    indent()
                    out += "<?" + instruction.target + (instruction.data.isEmpty ? "" : " " + instruction.data) + "?>"
                }
            case .close(let element, let name):
                level -= 1
                if !mixed && !element.children.isEmpty { newLineNow() }
                out += "</" + name + ">"
                mixed = mixedStack.removeLast()
                frames.removeLast()
            }
        }
    }

    private mutating func indent() {
        if !mixed && !out.isEmpty { newLineNow() }
    }

    private mutating func newLineNow() {
        out += "\n" + String(repeating: "  ", count: level)
    }

    private func lookupNamespace(_ prefix: String) -> String? {
        for frame in frames.reversed() {
            for d in frame.reversed() where d.prefix == prefix { return d.uri }
        }
        if prefix.isEmpty { return "" }
        return prefix == "xml" ? XmlNamespaces.xml : nil
    }

    private func lookupPrefix(_ uri: String) -> String? {
        for frame in frames.reversed() {
            for d in frame.reversed() where d.uri == uri && lookupNamespace(d.prefix) == uri { return d.prefix }
        }
        if uri.isEmpty { return lookupNamespace("") == "" ? "" : nil }
        return uri == XmlNamespaces.xml ? "xml" : nil
    }

    private mutating func start(_ element: XmlElement, _ work: inout [Step]) {
        indent()
        level += 1
        mixedStack.append(mixed)

        let ns = element.name.namespace
        let prefix = element.prefixOfNamespace(ns) ?? lookupPrefix(ns) ?? ""
        let explicit = element.attributes.filter { $0.isNamespaceDeclaration }
        var declared: [(prefix: String, uri: String)] = explicit.map { ($0.declaredPrefix, $0.value) }
        var implicit: [(prefix: String, uri: String)] = []
        if lookupNamespace(prefix) != ns && !explicit.contains(where: { $0.declaredPrefix == prefix }) {
            implicit.append((prefix, ns))
        }
        frames.append(declared)

        var tag = "<" + (prefix.isEmpty ? element.name.local : prefix + ":" + element.name.local)
        for a in element.attributes {
            if a.isNamespaceDeclaration {
                tag += " " + (a.declaredPrefix.isEmpty ? "xmlns" : "xmlns:" + a.declaredPrefix) + "=\"" + XfdfXml.escapeAttribute(a.value) + "\""
                continue
            }
            let uri = a.name.namespace
            if uri.isEmpty {
                tag += " " + a.name.local
            } else {
                var attributePrefix = uri == XmlNamespaces.xml ? "xml" : element.prefixOfNamespace(uri, allowDefault: false)
                if attributePrefix == nil, let found = lookupPrefix(uri), !found.isEmpty { attributePrefix = found }
                if attributePrefix == nil {
                    generated += 1
                    attributePrefix = "p\(generated)"
                    implicit.append((attributePrefix ?? "", uri))
                }
                tag += " " + (attributePrefix ?? "") + ":" + a.name.local
            }
            tag += "=\"" + XfdfXml.escapeAttribute(a.value) + "\""
        }
        for d in implicit {
            tag += " " + (d.prefix.isEmpty ? "xmlns" : "xmlns:" + d.prefix) + "=\"" + XfdfXml.escapeAttribute(d.uri) + "\""
        }
        declared.append(contentsOf: implicit)
        frames[frames.count - 1] = declared

        if element.hasContent {
            out += tag + ">"
            work.append(.close(element, prefix.isEmpty ? element.name.local : prefix + ":" + element.name.local))
            work.append(contentsOf: element.children.reversed().map { Step.node($0) })
        } else {
            out += tag + " />"
            level -= 1
            mixed = mixedStack.removeLast()
            frames.removeLast()
        }
    }
}
