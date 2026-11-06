import Foundation

// Twin of windows/LazyPDF.Core/Redaction/RedactionMetadata.cs: looks for removed text in the document information, the XMP
// packets, bookmark titles and the other text strings of the file (descriptions in the tag tree, link addresses, names);
// replaces it when asked. Copies of whole pages and of earlier versions (XMP thumbnails and history, /PieceInfo) are removed
// whatever is asked, since no search can find a picture in them.
//
// string.Replace and Contains with OrdinalIgnoreCase work on UTF-16 units here too: each unit is mapped to its simple upper
// case and the units are compared, so the text keeps its length and a match can be put back in the original.

enum RedactionMetadata {
    // Binary strings and font data that a few letters match by chance, and the bookmark titles, which have their own pass.
    private static let skipped: Set<String> = ["ID", "O", "U", "OE", "UE", "Perms", "DA", "CharSet", "ByteRange", "Title"]

    /// The depth of objects held inside objects. The lexer stops at 200, so nothing the reader returns is deeper.
    static let objectDepth = 256

    private static let maxPacket = 16 << 20

    // Thumbnails and page images (xmpGImg:image in whatever wrapper the producer used, as an element or an attribute),
    // history and what a page was made from. Names are compared without their prefix, since producers choose their own.
    private static let pageCopies = ["Thumbnails", "History", "Ingredients", "DerivedFrom", "ManagedFrom", "RenditionOf", "Manifest", "Pantry", "PageInfo", "image", "Versions", "DocumentAncestors"]

    // The ids tie the output to the file it was made from.
    private static let identifiers = ["DocumentID", "InstanceID", "OriginalDocumentID"]

    private static let dropped: [[UInt16]] = (pageCopies + identifiers).map { fold(Array($0.utf16)) }

    static func scan(_ document: PdfDocument, _ needles: [String], _ change: Bool) throws -> [RedactionFinding] {
        var findings: [RedactionFinding] = []
        dropPrivateData(document)
        let longestFirst = needles.enumerated().sorted { a, b in
            let (x, y) = (a.element.utf16.count, b.element.utf16.count)
            return x != y ? x > y : a.offset < b.offset
        }.map { fold(Array($0.element.utf16)) }

        // The phrases have single spaces; a producer may break a line or indent between the words.
        func clean(_ text: String) -> String {
            var units = Array(DotNetText.words(text).utf16)
            for needle in longestFirst { units = replace(units, needle, Array(RedactionText.replacedBy.utf16)) }
            return String(decoding: units, as: UTF16.self)
        }
        func holds(_ text: String) -> Bool {
            let spaced = fold(Array(DotNetText.words(text).utf16))
            return longestFirst.contains { contains(spaced, $0) }
        }

        if let info = document.info, !needles.isEmpty {
            var found = false
            for (key, value) in info.entries {
                guard let s = document.resolve(value) as? PdfString else { continue }
                let text = PdfText.decode(s.bytes)
                if !holds(text) { continue }
                found = true
                if change { info[key] = PdfText.toObject(clean(text)) }
            }
            if found { findings.append(RedactionFinding("The document information", change)) }
        }

        var xmp = false
        for packet in packets(document) {
            guard let text = read(document, packet), let xml = DomDocument.parse(text) else {
                emptied(packet, &findings)
                continue
            }
            var changed = strip(xml)
            var found = false
            carriers(xml) { value, replace in
                if !holds(value) { return }
                found = true
                if !change { return }
                replace(clean(value))
                changed = true
            }
            xmp = xmp || found
            if !changed { continue }
            if let declaration = xml.children.first as? DomDeclaration { declaration.encoding = "UTF-8" }
            let written: String
            do {
                written = try xml.outerXml()
            } catch {
                // The parser took names the writer refuses (a reserved xmlns binding); a packet that cannot be written back is not kept.
                emptied(packet, &findings)
                continue
            }
            packet.dictionary.remove("Filter")
            packet.dictionary.remove("DecodeParms")
            packet.data = Array(written.utf8)
        }
        if xmp { findings.append(RedactionFinding("The XMP metadata", change)) }

        if needles.isEmpty { return findings }
        let outline = Outline.read(document)
        var titles = false
        var pending = outline.items
        while let item = pending.popLast() {
            if holds(item.title) {
                titles = true
                if change { item.title = clean(item.title) }
            }
            pending.append(contentsOf: item.children)
        }
        if titles {
            if change { try outline.write(document) }
            findings.append(RedactionFinding("A bookmark title", change))
        }

        let strings = Strings(holds, clean, change)
        for number in document.objectNumbers {
            let object = document.get(number)
            let item: PdfObject
            if let stream = object as? PdfStream {
                item = stream.dictionary
            } else if let object {
                item = object
            } else {
                continue
            }
            if let info = document.info, item === info { continue }
            let replaced = strings.replace(item)
            if replaced !== item { document.set(number, replaced) }
        }
        if strings.found { findings.append(RedactionFinding(RedactionText.textElsewhere, change)) }
        return findings
    }

    private static func emptied(_ packet: PdfStream, _ findings: inout [RedactionFinding]) {
        packet.dictionary.remove("Filter")
        packet.dictionary.remove("DecodeParms")
        packet.data = []
        findings.append(RedactionFinding(RedactionText.xmpUnreadable, true))
    }

    private static func packets(_ document: PdfDocument) -> [PdfStream] {
        var seen = RedactionObjects.Identities()
        var found: [PdfStream] = []
        for number in document.objectNumbers {
            let value = document.get(number)
            for holder in direct(value, 0) {
                if let named = document.stream(holder, "Metadata"), seen.insert(named) { found.append(named) }
            }
            if let stream = value as? PdfStream, document.name(stream.dictionary, "Type") == "Metadata" || document.name(stream.dictionary, "Subtype") == "XML", seen.insert(stream) {
                found.append(stream)
            }
        }
        return found
    }

    // Every dictionary held directly in the object; what a reference leads to is an object of its own.
    private static func direct(_ value: PdfObject?, _ depth: Int) -> [PdfDictionary] {
        var found: [PdfDictionary] = []
        collect(value, depth, &found)
        return found
    }

    private static func collect(_ value: PdfObject?, _ depth: Int, _ found: inout [PdfDictionary]) {
        if depth > objectDepth { return }
        switch value {
        case let stream as PdfStream:
            collect(stream.dictionary, depth, &found)
        case let dictionary as PdfDictionary:
            found.append(dictionary)
            for (_, item) in dictionary.entries { collect(item, depth + 1, &found) }
        case let array as PdfArray:
            for item in array.items { collect(item, depth + 1, &found) }
        default:
            break
        }
    }

    /// The character data of an XMP packet with the character references resolved, one piece per line; nil when it is not XML.
    static func plainText(_ data: [UInt8]) -> String? {
        guard data.count <= maxPacket, let xml = DomDocument.parse(decode(data)) else { return nil }
        var values: [String] = []
        carriers(xml) { value, _ in values.append(value) }
        return values.joined(separator: "\n")
    }

    /// Whether a name is text a person wrote, not one of the names the format defines.
    static func isFreeText(_ name: String) -> Bool {
        name.unicodeScalars.contains { c in
            let letterOrDigit = (c.value >= 0x30 && c.value <= 0x39) || (c.value >= 0x41 && c.value <= 0x5A) || (c.value >= 0x61 && c.value <= 0x7A)
            return !(letterOrDigit || c == "." || c == "_" || c == "-" || c == "+")
        }
    }

    /// The value of a font name entry, which takes spaces and commas without being text a person wrote.
    static func isFontName(_ key: String, _ value: PdfObject) -> Bool { value is PdfName && (key == "BaseFont" || key == "FontName") }

    /// The text a name stands for: its bytes are UTF-8 (ISO 32000-1 7.3.5), held one to a character.
    static func nameText(_ name: String) -> String {
        if name.unicodeScalars.contains(where: { $0.value > 0xFF }) { return name }
        let bytes = Latin1.bytes(name)
        // A byte sequence that is not UTF-8 decodes with replacement characters, which do not encode back to it.
        let text = String(decoding: bytes, as: UTF8.self)
        return Array(text.utf8) == bytes ? text : name
    }

    private static func nameValue(_ text: String) -> String { Latin1.string(Array(text.utf8)) }

    // Text, comments and attribute values: where words can be. The text of an element makes one piece with what its child
    // elements hold, since a word can be split between them, by a comment or by a tag.
    private static func carriers(_ xml: DomDocument, _ body: (String, (String) -> Void) -> Void) {
        DomDocument.walk(xml.children) { node in
            if let comment = node as? DomComment { body(comment.value) { comment.value = $0 } }
            guard let element = node as? DomElement else { return }
            for attribute in element.attributes where !attribute.name.hasPrefix("xmlns") {
                body(attribute.value) { attribute.value = $0 }
            }
            let hasText = element.children.contains { child in
                guard let text = child as? DomText else { return false }
                return !DotNetText.isNullOrWhiteSpace(text.value)
            }
            if !hasText { return }
            var runs: [DomText] = []
            DomDocument.walk([element]) { if let text = $0 as? DomText { runs.append(text) } }
            body(runs.map { $0.value }.joined()) { v in
                runs[0].value = v
                for rest in runs.dropFirst() { rest.value = "" }
            }
        }
    }

    // RemoveChild finds the node before the one it removes by walking from the first child, so taking many out of a long
    // list one at a time is quadratic; the element is emptied and what stays put back instead.
    private static func strip(_ xml: DomDocument) -> Bool {
        func isDropped(_ name: String) -> Bool {
            let local = name.split(separator: ":", omittingEmptySubsequences: false).last.map(String.init) ?? name
            let folded = fold(Array(local.utf16))
            return dropped.contains { $0 == folded }
        }
        var any = false
        for element in xml.elements {
            let children = element.children
            let attributes = element.attributes
            if !children.contains(where: { ($0 as? DomElement).map { isDropped($0.name) } ?? false }) && !attributes.contains(where: { isDropped($0.name) }) { continue }
            any = true
            element.removeAll()
            for attribute in attributes where !isDropped(attribute.name) { element.attributes.append(attribute) }
            for child in children where !(((child as? DomElement).map { isDropped($0.name) }) ?? false) { element.append(child) }
        }
        return any
    }

    // Private data of the producing program can hold the whole page or document as it was.
    private static func dropPrivateData(_ document: PdfDocument) {
        document.catalog.remove("PieceInfo")
        for page in document.pages { page.dictionary.remove("PieceInfo") }
        for number in document.objectNumbers {
            if let stream = document.get(number) as? PdfStream, document.name(stream.dictionary, "Subtype") == "Form" { stream.dictionary.remove("PieceInfo") }
        }
    }

    // Nil when it cannot be read, which is no reason to keep it.
    private static func read(_ document: PdfDocument, _ packet: PdfStream) -> String? {
        do {
            let bytes = try document.data(packet, maxPacket)
            return bytes.count > maxPacket ? nil : decode(bytes)
        } catch {
            return nil
        }
    }

    // A packet is UTF-8, UTF-16 or UTF-32 (XMP specification, 7.3). The byte order mark sits inside the begin attribute
    // of the wrapper, so the packet starts with its first character, and a zero byte tells the width and the order.
    // A mark at the very start is taken too.
    static func decode(_ b: [UInt8]) -> String {
        let n = b.count
        if n >= 4 && b[0] == 0xFF && b[1] == 0xFE && b[2] == 0 && b[3] == 0 { return utf32(b[4...], false) }
        if n >= 4 && b[0] == 0 && b[1] == 0 && b[2] == 0xFE && b[3] == 0xFF { return utf32(b[4...], true) }
        if n >= 2 && b[0] == 0xFE && b[1] == 0xFF { return utf16(b[2...], true) }
        if n >= 2 && b[0] == 0xFF && b[1] == 0xFE { return utf16(b[2...], false) }
        if n >= 3 && b[0] == 0xEF && b[1] == 0xBB && b[2] == 0xBF { return String(decoding: b[3...], as: UTF8.self) }
        if n >= 4 && b[0] == 0 && b[1] == 0 && b[2] == 0 && b[3] > 0 { return utf32(b[...], true) }
        if n >= 4 && b[0] > 0 && b[1] == 0 && b[2] == 0 && b[3] == 0 { return utf32(b[...], false) }
        if n >= 2 && b[0] == 0 && b[1] > 0 { return utf16(b[...], true) }
        if n >= 2 && b[0] > 0 && b[1] == 0 { return utf16(b[...], false) }
        return String(decoding: b, as: UTF8.self)
    }

    private static func utf16(_ bytes: ArraySlice<UInt8>, _ bigEndian: Bool) -> String {
        var units: [UInt16] = []
        units.reserveCapacity(bytes.count / 2 + 1)
        var i = bytes.startIndex
        while i + 1 < bytes.endIndex {
            units.append(bigEndian ? UInt16(bytes[i]) << 8 | UInt16(bytes[i + 1]) : UInt16(bytes[i + 1]) << 8 | UInt16(bytes[i]))
            i += 2
        }
        // A byte left over decodes as the replacement character.
        if i < bytes.endIndex { units.append(0xFFFD) }
        return String(decoding: units, as: UTF16.self)
    }

    private static func utf32(_ bytes: ArraySlice<UInt8>, _ bigEndian: Bool) -> String {
        var text = String.UnicodeScalarView()
        var i = bytes.startIndex
        while i + 3 < bytes.endIndex {
            let b0 = UInt32(bytes[i]), b1 = UInt32(bytes[i + 1]), b2 = UInt32(bytes[i + 2]), b3 = UInt32(bytes[i + 3])
            let value = bigEndian ? b0 << 24 | b1 << 16 | b2 << 8 | b3 : b3 << 24 | b2 << 16 | b1 << 8 | b0
            text.append(Unicode.Scalar(value) ?? "\u{FFFD}")
            i += 4
        }
        if i < bytes.endIndex { text.append("\u{FFFD}") }
        return String(text)
    }

    // The simple upper case of each character, surrogate pairs included, as OrdinalIgnoreCase compares; a character keeps its
    // length. The dotted and dotless I are left alone, as the invariant casing leaves them. Where the full mapping is longer
    // than one character (U+1F80), the simple one is the titlecase, which is a single character for those and only those.
    private static func fold(_ units: [UInt16]) -> [UInt16] {
        var folded: [UInt16] = []
        folded.reserveCapacity(units.count)
        var i = 0
        while i < units.count {
            var scalar = Unicode.Scalar(units[i])
            var width = 1
            if scalar == nil, units[i] >= 0xD800, units[i] < 0xDC00, i + 1 < units.count, units[i + 1] >= 0xDC00, units[i + 1] < 0xE000 {
                scalar = Unicode.Scalar(0x10000 + (UInt32(units[i] - 0xD800) << 10) + UInt32(units[i + 1] - 0xDC00))
                width = 2
            }
            if let scalar, let upper = simpleUpper(scalar), upper.utf16.count == width {
                folded.append(contentsOf: upper.utf16)
            } else {
                folded.append(contentsOf: units[i..<i + width])
            }
            i += width
        }
        return folded
    }

    private static func simpleUpper(_ scalar: Unicode.Scalar) -> String? {
        if scalar.value < 0x80 { return scalar.value >= 0x61 && scalar.value <= 0x7A ? String(Unicode.Scalar(scalar.value - 0x20) ?? scalar) : String(scalar) }
        if scalar.value == 0x130 || scalar.value == 0x131 { return nil }
        let upper = scalar.properties.uppercaseMapping.unicodeScalars
        if upper.count == 1 { return String(upper) }
        let title = scalar.properties.titlecaseMapping.unicodeScalars
        return title.count == 1 ? String(title) : nil
    }

    private static func contains(_ text: [UInt16], _ needle: [UInt16]) -> Bool {
        if needle.isEmpty { return true }
        if text.count < needle.count { return false }
        for start in 0...(text.count - needle.count) where text[start] == needle[0] {
            if text[start..<start + needle.count].elementsEqual(needle) { return true }
        }
        return false
    }

    // Every occurrence of the folded needle in the text, which keeps its length: they are replaced in the text itself.
    private static func replace(_ text: [UInt16], _ needle: [UInt16], _ with: [UInt16]) -> [UInt16] {
        if needle.isEmpty || text.count < needle.count { return text }
        let folded = fold(text)
        var output: [UInt16] = []
        var at = 0
        var start = 0
        while start <= folded.count - needle.count {
            if folded[start] == needle[0] && folded[start..<start + needle.count].elementsEqual(needle) {
                output.append(contentsOf: text[at..<start])
                output.append(contentsOf: with)
                start += needle.count
                at = start
            } else {
                start += 1
            }
        }
        output.append(contentsOf: text[at...])
        return output
    }

    // The text strings held directly in dictionaries and arrays; what a reference leads to is visited as an object of its own.
    private final class Strings {
        private let holds: (String) -> Bool
        private let clean: (String) -> String
        private let change: Bool

        private(set) var found = false

        init(_ holds: @escaping (String) -> Bool, _ clean: @escaping (String) -> String, _ change: Bool) {
            self.holds = holds
            self.clean = clean
            self.change = change
        }

        /// The object itself, or the string that replaces it.
        func replace(_ value: PdfObject) -> PdfObject { item(value, 0) }

        private func visit(_ dictionary: PdfDictionary, _ depth: Int) {
            if depth > RedactionMetadata.objectDepth { return }
            for (key, value) in dictionary.entries {
                if RedactionMetadata.skipped.contains(key) || RedactionMetadata.isFontName(key, value) { continue }
                let replaced = item(value, depth)
                if RedactionMetadata.isFreeText(key) && holds(RedactionMetadata.nameText(key)) {
                    found = true
                    if change {
                        var renamed = RedactionMetadata.nameValue(clean(RedactionMetadata.nameText(key)))
                        while dictionary.containsKey(renamed) { renamed += "_" }
                        dictionary.remove(key)
                        dictionary[renamed] = replaced
                        continue
                    }
                }
                if replaced !== value { dictionary[key] = replaced }
            }
        }

        private func item(_ value: PdfObject, _ depth: Int) -> PdfObject {
            switch value {
            case let s as PdfString:
                if let text = Self.text(s.bytes), holds(text) {
                    found = true
                    return change ? PdfText.toObject(clean(text)) : value
                }
            case let name as PdfName:
                if RedactionMetadata.isFreeText(name.value) && holds(RedactionMetadata.nameText(name.value)) {
                    found = true
                    return change ? PdfName(RedactionMetadata.nameValue(clean(RedactionMetadata.nameText(name.value)))) : value
                }
            case let inner as PdfDictionary:
                visit(inner, depth + 1)
            case let array as PdfArray where depth < RedactionMetadata.objectDepth:
                for i in 0..<array.items.count { array.items[i] = item(array.items[i], depth + 1) }
            default:
                break
            }
            return value
        }

        // Text in PDFDocEncoding or UTF-16 or UTF-8 with a mark; anything with control bytes is data.
        private static func text(_ bytes: [UInt8]) -> String? {
            let utf16Mark = bytes.count >= 2 && ((bytes[0] == 0xFE && bytes[1] == 0xFF) || (bytes[0] == 0xFF && bytes[1] == 0xFE))
            let marked = utf16Mark || (bytes.count >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF)
            if !marked && bytes.contains(where: { $0 < 0x20 && !($0 == 9 || $0 == 10 || $0 == 13) }) { return nil }
            return PdfText.decode(bytes)
        }
    }
}
