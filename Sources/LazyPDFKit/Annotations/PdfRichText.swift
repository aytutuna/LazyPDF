import Foundation

// Twin of windows/LazyPDF.Core/Annotations/PdfRichText.cs: the look of a stretch of text, from what /DA, /DS and the
// style attributes of /RC (an XHTML subset, ISO 32000-1 12.7.3.4) say, merged; and rich text at a basic level.
//
// The C# reads /RC with an XmlReader in fragment mode. Here the text goes between <r> and </r> and the Structure
// layer's XML parser reads it, so a fragment nested deeper than 999 levels is refused where .NET reads it.

struct TextFormat {
    var family: String
    var size: Double
    var bold: Bool
    var italic: Bool
    var underline: Bool
    var color: [Double]

    init(_ family: String, _ size: Double, _ bold: Bool, _ italic: Bool, _ underline: Bool, _ color: [Double]) {
        self.family = family
        self.size = size
        self.bold = bold
        self.italic = italic
        self.underline = underline
        self.color = color
    }

    static let `default` = TextFormat("Helvetica", 12, false, false, false, [0])

    var style: FontStyles {
        var style: FontStyles = []
        if bold { style.insert(.bold) }
        if italic { style.insert(.italic) }
        return style
    }

    /// This format with the declarations of a CSS style attribute applied on top.
    func withCss(_ css: String?) -> TextFormat {
        var f = self
        guard let css, !css.unicodeScalars.allSatisfy({ $0.properties.isWhitespace }) else { return f }
        for declaration in css.split(separator: ";", omittingEmptySubsequences: false) {
            guard let colon = declaration.firstIndex(of: ":") else { continue }
            let key = Self.trim(String(declaration[..<colon])).lowercased()
            let value = Self.trim(String(declaration[declaration.index(after: colon)...]))
            switch key {
            case "font-family":
                f.family = Self.firstFamily(value)
            case "font-size":
                if let size = Self.length(value) { f.size = size }
            case "font-weight":
                f.bold = value.lowercased() == "bold" || (InvariantNumbers.parseInt(value).map { $0 >= 600 } ?? false)
            case "font-style":
                f.italic = value == "italic" || value == "oblique"
            case "text-decoration":
                f.underline = value.lowercased().contains("underline")
            case "color":
                if let color = Self.hexColor(value) { f.color = color }
            case "font":
                f = f.withShorthand(value)
            default:
                break
            }
        }
        return f
    }

    private func withShorthand(_ value: String) -> TextFormat {
        var f = self
        var family: [String] = []
        for token in value.split(separator: " ", omittingEmptySubsequences: true).map(String.init) {
            if token.lowercased() == "bold" {
                f.bold = true
            } else if token == "italic" || token == "oblique" {
                f.italic = true
            } else if token == "normal" {
                continue
            } else if let size = Self.length(token), let first = token.unicodeScalars.first, first.value >= 0x30, first.value <= 0x39 {
                f.size = size
            } else {
                family.append(token)
            }
        }
        if !family.isEmpty { f.family = Self.firstFamily(family.joined(separator: " ")) }
        return f
    }

    // String.Trim() cuts White_Space characters.
    private static func trim(_ text: String) -> String {
        var scalars = Array(text.unicodeScalars)
        while let last = scalars.last, last.properties.isWhitespace { scalars.removeLast() }
        var start = 0
        while start < scalars.count, scalars[start].properties.isWhitespace { start += 1 }
        return String(String.UnicodeScalarView(scalars[start...]))
    }

    private static func firstFamily(_ value: String) -> String {
        let head = value.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        let quotes = Set("'\"".unicodeScalars)
        var scalars = Array(trim(head).unicodeScalars)
        while let last = scalars.last, quotes.contains(last) { scalars.removeLast() }
        var start = 0
        while start < scalars.count, quotes.contains(scalars[start]) { start += 1 }
        let first = String(String.UnicodeScalarView(scalars[start...]))
        return first.isEmpty ? "Helvetica" : first
    }

    private static func length(_ value: String) -> Double? {
        let lower = value.lowercased()
        let number = lower.hasSuffix("pt") || lower.hasSuffix("px") ? String(value.unicodeScalars.dropLast(2)) : value
        guard let size = InvariantNumbers.parseDouble(number), size > 0, size < 1000 else { return nil }
        return size
    }

    private static func hexColor(_ value: String) -> [Double]? {
        var scalars = Array(value.unicodeScalars)
        guard scalars.first == "#" else { return nil }
        scalars.removeFirst()
        if scalars.count == 3 { scalars = scalars.flatMap { [$0, $0] } }
        guard scalars.count == 6, let rgb = InvariantNumbers.parseHex(String(String.UnicodeScalarView(scalars))) else { return nil }
        return [Double((rgb >> 16) & 255) / 255.0, Double((rgb >> 8) & 255) / 255.0, Double(rgb & 255) / 255.0]
    }
}

struct TextRun {
    let text: String
    let format: TextFormat

    init(_ text: String, _ format: TextFormat) {
        self.text = text
        self.format = format
    }
}

/// Rich text at a basic level: paragraphs, line breaks, and bold, italic, underline, size, family and colour.
public enum PdfRichText {
    private static let maxLength = 200_000

    /// The plain text of an /RC string: paragraphs on lines of their own. Empty for text that is not well-formed XML.
    public static func toPlain(_ xhtml: String) -> String {
        guard let paragraphs = parse(xhtml, .default) else { return "" }
        return paragraphs.map { $0.map { $0.text }.joined() }.joined(separator: "\n")
    }

    // Where an XML declaration at the very start ends. A fragment may begin with one; inside the wrapper element it is illegal.
    private static func declarationEnd(_ s: [Unicode.Scalar]) -> Int? {
        let head = Array("<?xml".unicodeScalars)
        guard s.count > head.count, Array(s[0..<head.count]) == head, s[head.count] == " " || s[head.count] == "\t" || s[head.count] == "\n" else { return nil }
        var i = head.count
        while i + 1 < s.count {
            if s[i] == "?" && s[i + 1] == ">" { return i + 2 }
            i += 1
        }
        return nil
    }

    static func parse(_ xhtml: String, _ defaults: TextFormat) -> [[TextRun]]? {
        if xhtml.utf16.count > maxLength { return nil }
        var text = XmlEncoding.normalizeLineEnds(Array(xhtml.unicodeScalars))
        if let end = declarationEnd(text) {
            var declaration = XmlParser(Array(text[0..<end]) + Array("<r/>".unicodeScalars))
            guard (try? declaration.parseDocument()) != nil else { return nil }
            text.removeFirst(end)
        }
        let scalars = Array("<r>".unicodeScalars) + text + Array("</r>".unicodeScalars)
        var parser = XmlParser(scalars)
        guard let root = (try? parser.parseDocument())?.root else { return nil }

        var paragraphs: [[TextRun]] = [[]]
        var formats = [defaults]
        var opened: [Bool] = []
        var work: [Step] = root.children.reversed().map { .node($0) }
        while let step = work.popLast() {
            switch step {
            case .node(let node):
                if let element = node as? XmlElement {
                    let name = element.name.local.lowercased()
                    var format = (formats.last ?? defaults).withCss(element.attribute(XmlName("", "style"))?.value)
                    switch name {
                    case "b", "strong": format.bold = true
                    case "i", "em": format.italic = true
                    case "u": format.underline = true
                    default: break
                    }
                    if name == "p" && !(paragraphs.last?.isEmpty ?? true) { paragraphs.append([]) }
                    if name == "br" { paragraphs.append([]) }
                    if element.hasContent {
                        formats.append(format)
                        opened.append(name == "p")
                        work.append(.close)
                        work.append(contentsOf: element.children.reversed().map { .node($0) })
                    }
                } else if let text = node as? XmlText, !text.isCData {
                    let collapsed = collapse(text.value)
                    // Indentation between block tags is not text; a space between two spans is.
                    if !collapsed.isEmpty && (!(paragraphs.last?.isEmpty ?? true) || collapsed != " ") {
                        paragraphs[paragraphs.count - 1].append(TextRun(collapsed, formats.last ?? defaults))
                    }
                }
            case .close:
                if formats.count > 1 { formats.removeLast() }
                if let wasParagraph = opened.popLast(), wasParagraph { paragraphs.append([]) }
            }
        }
        while paragraphs.count > 1 && paragraphs[paragraphs.count - 1].isEmpty { paragraphs.removeLast() }
        return paragraphs
    }

    private enum Step {
        case node(XmlNode)
        case close
    }

    private static func collapse(_ text: String) -> String {
        var result = String.UnicodeScalarView()
        var space = false
        for c in text.unicodeScalars {
            if c.properties.isWhitespace {
                space = true
                continue
            }
            if space { result.append(" ") }
            space = false
            result.append(c)
        }
        if space { result.append(" ") }
        return String(result)
    }
}
