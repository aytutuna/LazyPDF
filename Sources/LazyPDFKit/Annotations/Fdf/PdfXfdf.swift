import Foundation

// Twin of windows/LazyPDF.Core/Annotations/Fdf/PdfXfdf.cs: XFDF (ISO 19444-1), the XML form of the data an FDF file
// holds. Appearance streams, attachment data and the image of an image stamp have no place in what is read or written
// here; an imported annotation gets its appearance drawn from its attributes.
//
// The C# reads and writes with System.Xml.Linq. Here the Structure layer's XmlTree reads, and XfdfXml.swift writes the
// way an XmlWriter with Indent does. The message of the damaged error for XML that is not well-formed is not .NET's. An
// /RC with a DOCTYPE is left out of the written file; XElement.Parse would read it.

public enum PdfXfdf {
    private static let ns = "http://ns.adobe.com/xfdf/"
    private static let maxItems = 200_000
    private static let maxCharacters = 64 << 20

    private static let subtypes = [
        "Text", "Link", "FreeText", "Line", "Square", "Circle", "Polygon", "PolyLine", "Highlight", "Underline", "Squiggly",
        "StrikeOut", "Stamp", "Caret", "Ink", "Popup", "FileAttachment", "Redact",
    ]

    private static let flagNames = [
        "invisible", "hidden", "print", "nozoom", "norotate", "noview", "readonly", "locked", "togglenoview", "lockedcontents",
    ]

    private static func name(_ local: String) -> XmlName { XmlName(ns, local) }

    private static func attribute(_ element: XmlElement, _ local: String) -> String? {
        element.attribute(XmlName("", local))?.value
    }

    /// Reads XFDF. Throws `PdfReadException` (damaged) for XML that is not well-formed, has a DTD, or has no xfdf element.
    public static func read(_ data: [UInt8]) throws -> FdfFile {
        guard let scalars = XmlEncoding.scalars(data) else { throw notWellFormed }
        return try load(scalars)
    }

    public static func read(_ xml: String) throws -> FdfFile {
        try load(Array(xml.unicodeScalars))
    }

    private static var notWellFormed: PdfReadException { PdfReadException.damaged("The XFDF is not well-formed.") }

    private static func load(_ scalars: [Unicode.Scalar]) throws -> FdfFile {
        if scalars.count > maxCharacters { throw notWellFormed }
        var parser = XmlParser(XmlEncoding.normalizeLineEnds(scalars))
        guard let document = try? parser.parseDocument() else { throw notWellFormed }
        return try read(document)
    }

    private static func read(_ document: XmlDocument) throws -> FdfFile {
        guard let root = document.root, root.name == name("xfdf") else {
            throw PdfReadException.damaged("There is no xfdf element in the file.")
        }
        let fdf = FdfFile()
        if let f = root.element(name("f")) { fdf.fileName = attribute(f, "href") }
        var count = 0
        if let fields = root.element(name("fields")) { fdf.fields.append(contentsOf: readFields(fields, 0, &count)) }
        if let annots = root.element(name("annots")) {
            for element in annots.children.compactMap({ $0 as? XmlElement }).prefix(PdfAnnotations.maxAnnotations) {
                guard let subtype = subtypes.first(where: { $0.lowercased() == element.name.local.lowercased() }) else { continue }
                let given = attribute(element, "page")
                let page = InvariantNumbers.parseSignedInt(given) ?? (given == nil ? 0 : -1)
                fdf.annotations.append(FdfAnnotation(page, readAnnotation(element, subtype)))
            }
        }
        return fdf
    }

    private static func readFields(_ parent: XmlElement, _ depth: Int, _ count: inout Int) -> [FdfField] {
        var fields: [FdfField] = []
        for element in parent.elements(name("field")) {
            count += 1
            if count - 1 >= maxItems { break }
            let kids = depth < 32 ? readFields(element, depth + 1, &count) : []
            let values: [PdfObject] = element.elements(name("value")).map { PdfText.toObject($0.value) }
            var value: PdfObject?
            switch values.count {
            case 0: value = nil
            case 1: value = values[0]
            default: value = PdfArray(values)
            }
            fields.append(FdfField(attribute(element, "name") ?? "", value, kids))
        }
        return fields
    }

    private static func readAnnotation(_ e: XmlElement, _ subtype: String) -> PdfDictionary {
        let d = PdfDictionary()
        d["Type"] = PdfName("Annot")
        d["Subtype"] = PdfName(subtype)
        func a(_ local: String) -> String? { attribute(e, local) }
        func text(_ local: String, _ key: String) { if let v = a(local) { d[key] = PdfText.toObject(v) } }
        func nameOf(_ local: String, _ key: String) { if let v = a(local), !v.isEmpty { d[key] = PdfName.fromText(v) } }
        func number(_ local: String, _ key: String) { if let n = InvariantNumbers.parseDouble(a(local)) { d[key] = PdfNumber(n) } }

        text("name", "NM"); text("title", "T"); text("subject", "Subj"); text("date", "M"); text("creationdate", "CreationDate")
        text("state", "State"); text("statemodel", "StateModel"); text("overlaytext", "OverlayText")
        nameOf("icon", "Name"); nameOf("intent", "IT")
        if let replyType = a("replyType"), !replyType.isEmpty {
            d["RT"] = PdfName(replyType == "group" ? "Group" : replyType == "reply" ? "R" : replyType)
        }
        if let symbol = a("symbol"), !symbol.isEmpty {
            d["Sy"] = PdfName(symbol == "paragraph" ? "P" : symbol == "none" ? "None" : symbol)
        }
        number("opacity", "CA")
        if let justification = a("justification") {
            var q: Int?
            switch justification {
            case "left": q = 0
            case "centered": q = 1
            case "right": q = 2
            default: q = InvariantNumbers.parseDouble(justification).map { Int(saturating32: $0) }
            }
            if let alignment = q { d["Q"] = PdfNumber(alignment) }
        }
        if let open = a("open") { d["Open"] = PdfBoolean(open.lowercased() == "yes" || open == "true") }
        if let reply = a("inreplyto") { d["IRT"] = PdfText.toObject(reply) }

        let rect = numbers(a("rect"))
        if rect.count == 4 { d["Rect"] = array(rect) }
        if let color = hexColor(a("color")) { d["C"] = array(color) }
        if let interior = hexColor(a("interior-color")) { d["IC"] = array(interior) }
        let coords = numbers(a("coords"))
        if !coords.isEmpty { d["QuadPoints"] = array(coords) }
        let fringe = numbers(a("fringe"))
        if fringe.count == 4 { d["RD"] = array(fringe) }
        let callout = numbers(a("callout"))
        if callout.count >= 4 { d["CL"] = array(callout) }
        if let flags = a("flags") { d["F"] = PdfNumber(parseFlags(flags)) }
        let from = numbers(a("start")), to = numbers(a("end"))
        if from.count == 2 && to.count == 2 { d["L"] = array(from + to) }
        if a("head") != nil || a("tail") != nil {
            d["LE"] = PdfArray([PdfName(a("head") ?? "None"), PdfName(a("tail") ?? "None")])
        }

        let style = a("style")
        if InvariantNumbers.parseDouble(a("width")) != nil || ["dash", "dashed", "beveled", "inset", "underline"].contains(style ?? "") {
            let bs = PdfDictionary()
            bs["Type"] = PdfName("Border")
            bs["W"] = PdfNumber(InvariantNumbers.parseDouble(a("width")) ?? 1)
            switch style {
            case "dash", "dashed": bs["S"] = PdfName("D")
            case "beveled": bs["S"] = PdfName("B")
            case "inset": bs["S"] = PdfName("I")
            case "underline": bs["S"] = PdfName("U")
            default: bs["S"] = PdfName("S")
            }
            let dashes = numbers(a("dashes"))
            if !dashes.isEmpty { bs["D"] = array(dashes) }
            d["BS"] = bs
        }
        if style == "cloudy" {
            let be = PdfDictionary()
            be["S"] = PdfName("C")
            be["I"] = PdfNumber(InvariantNumbers.parseDouble(a("intensity")) ?? 1)
            d["BE"] = be
        }

        for case let child as XmlElement in e.children {
            switch child.name.local {
            case "contents":
                d["Contents"] = PdfText.toObject(child.value)
            case "contents-richtext":
                d["RC"] = PdfText.toObject(child.children.map { XfdfXml.string($0) }.joined())
            case "defaultappearance":
                d["DA"] = PdfText.toObject(child.value)
            case "defaultstyle":
                d["DS"] = PdfText.toObject(child.value)
            case "vertices":
                d["Vertices"] = array(numbers(child.value))
            case "inklist":
                d["InkList"] = PdfArray(child.children.compactMap { node -> PdfObject? in
                    guard let g = node as? XmlElement, g.name.local == "gesture" else { return nil }
                    return array(numbers(g.value))
                })
            case "popup":
                let popup = PdfDictionary()
                let r = numbers(attribute(child, "rect"))
                if r.count == 4 { popup["Rect"] = array(r) }
                if let f = attribute(child, "flags") { popup["F"] = PdfNumber(parseFlags(f)) }
                if let o = attribute(child, "open") { popup["Open"] = PdfBoolean(o.lowercased() == "yes") }
                d["Popup"] = popup
            default:
                break
            }
        }
        return d
    }

    public static func write(_ fdf: FdfFile) throws -> [UInt8] {
        try fdf.link()
        let root = XmlElement(name("xfdf"))
        root.attributes.append(XmlAttribute(XmlName(XmlNamespaces.xml, "space"), "preserve", prefix: "xml"))
        if let file = fdf.fileName {
            let f = XmlElement(name("f"))
            f.attributes.append(XmlAttribute(XmlName("", "href"), clean(file)))
            root.append(f)
        }
        if !fdf.fields.isEmpty {
            let fields = XmlElement(name("fields"))
            for field in fdf.fields { fields.append(writeField(field)) }
            root.append(fields)
        }
        let annots = XmlElement(name("annots"))
        // A reply names its parent, so the parent needs a name before any element is written.
        for annotation in fdf.annotations {
            if let parent = fdf.resolve(annotation.dictionary["IRT"]) as? PdfDictionary, parent["NM"] == nil {
                parent["NM"] = PdfText.toObject(UUID().uuidString.lowercased())
            }
        }
        for annotation in fdf.annotations {
            if let subtype = (annotation.dictionary["Subtype"] as? PdfName)?.value, subtype != "Popup" {
                annots.append(writeAnnotation(fdf, annotation, subtype))
            }
        }
        if annots.children.contains(where: { $0 is XmlElement }) { root.append(annots) }
        return XfdfXml.document(root)
    }

    private static func writeField(_ field: FdfField) -> XmlElement {
        let element = XmlElement(name("field"))
        element.attributes.append(XmlAttribute(XmlName("", "name"), clean(field.name)))
        var values: [String] = []
        if let array = field.value as? PdfArray {
            values = array.items.map { text($0) }
        } else if let single = field.value {
            values = [text(single)]
        }
        for value in values { element.append(XmlElement(name("value"), text: clean(value))) }
        for kid in field.kids { element.append(writeField(kid)) }
        return element
    }

    private static func text(_ value: PdfObject) -> String {
        switch value {
        case let s as PdfString: return PdfText.decode(s.bytes)
        case let n as PdfName: return n.value
        case let n as PdfNumber: return n.text
        case let b as PdfBoolean: return b.value ? "true" : "false"
        default: return ""
        }
    }

    private static func writeAnnotation(_ fdf: FdfFile, _ annotation: FdfAnnotation, _ subtype: String) -> XmlElement {
        let d = annotation.dictionary
        let e = XmlElement(name(subtype.lowercased()))
        e.attributes.append(XmlAttribute(XmlName("", "page"), String(annotation.pageIndex)))
        func v(_ key: String) -> PdfObject? { fdf.resolve(d[key]) }
        func put(_ attribute: String, _ value: String?) {
            if let value { e.setAttributeValue(XmlName("", attribute), clean(value)) }
        }
        func textOf(_ key: String) -> String? { (v(key) as? PdfString).map { PdfText.decode($0.bytes) } }
        func nameOf(_ key: String) -> String? { (v(key) as? PdfName)?.text }
        func numberOf(_ key: String) -> String? { (v(key) as? PdfNumber)?.text }
        func list(_ key: String) -> String? {
            guard let a = v(key) as? PdfArray else { return nil }
            return a.items.map { (fdf.resolve($0) as? PdfNumber)?.text ?? "0" }.joined(separator: ",")
        }

        put("rect", list("Rect"))
        put("name", textOf("NM")); put("title", textOf("T")); put("subject", textOf("Subj"))
        put("date", textOf("M")); put("creationdate", textOf("CreationDate"))
        put("opacity", numberOf("CA"))
        switch (v("Q") as? PdfNumber)?.integer {
        case 0: put("justification", "left")
        case 1: put("justification", "centered")
        case 2: put("justification", "right")
        default: break
        }
        put("icon", nameOf("Name")); put("intent", nameOf("IT"))
        switch nameOf("RT") {
        case "R": put("replyType", "reply")
        case "Group": put("replyType", "group")
        case let other: put("replyType", other)
        }
        switch nameOf("Sy") {
        case "P": put("symbol", "paragraph")
        case "None": put("symbol", "none")
        case let other: put("symbol", other)
        }
        put("state", textOf("State")); put("statemodel", textOf("StateModel")); put("overlaytext", textOf("OverlayText"))
        put("coords", list("QuadPoints")); put("fringe", list("RD")); put("callout", list("CL"))
        if let open = v("Open") as? PdfBoolean { put("open", open.value ? "yes" : "no") }
        if let flags = v("F") as? PdfNumber, let f = flags.integer {
            put("flags", flagNames.enumerated().filter { (f >> $0.offset) & 1 != 0 }.map { $0.element }.joined(separator: ","))
        }
        put("color", hexOf(v("C"))); put("interior-color", hexOf(v("IC")))
        if let parent = v("IRT") as? PdfDictionary {
            if parent["NM"] == nil { parent["NM"] = PdfText.toObject(UUID().uuidString.lowercased()) }
            // The C# casts the /NM to a string; one that is not is left unnamed here.
            if let nm = parent["NM"] as? PdfString { put("inreplyto", PdfText.decode(nm.bytes)) }
        }
        if let line = v("L") as? PdfArray, line.items.count == 4 {
            let n = line.items.map { (fdf.resolve($0) as? PdfNumber)?.text ?? "0" }
            put("start", "\(n[0]),\(n[1])")
            put("end", "\(n[2]),\(n[3])")
        }
        if let ends = v("LE") as? PdfArray, !ends.items.isEmpty {
            put("head", (fdf.resolve(ends.items[0]) as? PdfName)?.value)
            if ends.items.count > 1 { put("tail", (fdf.resolve(ends.items[1]) as? PdfName)?.value) }
        } else if let single = v("LE") as? PdfName {
            put("head", single.value)
        }
        if let bs = fdf.resolve(d["BS"]) as? PdfDictionary {
            put("width", (fdf.resolve(bs["W"]) as? PdfNumber)?.text)
            switch (fdf.resolve(bs["S"]) as? PdfName)?.value {
            case "D": put("style", "dash")
            case "B": put("style", "beveled")
            case "I": put("style", "inset")
            case "U": put("style", "underline")
            default: put("style", "solid")
            }
            if let dash = fdf.resolve(bs["D"]) as? PdfArray {
                put("dashes", dash.items.map { (fdf.resolve($0) as? PdfNumber)?.text ?? "0" }.joined(separator: ","))
            }
        }
        if let be = fdf.resolve(d["BE"]) as? PdfDictionary, (fdf.resolve(be["S"]) as? PdfName)?.value == "C" {
            put("style", "cloudy")
            put("intensity", (fdf.resolve(be["I"]) as? PdfNumber)?.text ?? "1")
        }

        if let contents = textOf("Contents") { e.append(XmlElement(name("contents"), text: clean(contents))) }
        if let rich = textOf("RC"), let parsed = parseFragment(rich) {
            let wrapper = XmlElement(name("contents-richtext"))
            wrapper.append(parsed)
            e.append(wrapper)
        }
        if let da = textOf("DA") { e.append(XmlElement(name("defaultappearance"), text: clean(da))) }
        if let ds = textOf("DS") { e.append(XmlElement(name("defaultstyle"), text: clean(ds))) }
        if let vertices = v("Vertices") as? PdfArray { e.append(XmlElement(name("vertices"), text: pairs(fdf, vertices))) }
        if let ink = v("InkList") as? PdfArray {
            let element = XmlElement(name("inklist"))
            for case let g as PdfArray in ink.items.map({ fdf.resolve($0) }) {
                element.append(XmlElement(name("gesture"), text: pairs(fdf, g)))
            }
            e.append(element)
        }
        if let popup = v("Popup") as? PdfDictionary {
            let element = XmlElement(name("popup"))
            element.attributes.append(XmlAttribute(XmlName("", "page"), String(annotation.pageIndex)))
            if let r = fdf.resolve(popup["Rect"]) as? PdfArray {
                element.setAttributeValue(XmlName("", "rect"), r.items.map { (fdf.resolve($0) as? PdfNumber)?.text ?? "0" }.joined(separator: ","))
            }
            if let o = fdf.resolve(popup["Open"]) as? PdfBoolean { element.setAttributeValue(XmlName("", "open"), o.value ? "yes" : "no") }
            e.append(element)
        }
        return e
    }

    // The /RC string parsed as XML so that it nests as markup, not as escaped text.
    private static func parseFragment(_ xhtml: String) -> XmlElement? {
        var parser = XmlParser(XmlEncoding.normalizeLineEnds(Array(xhtml.unicodeScalars)))
        guard let root = (try? parser.parseDocument())?.root else { return nil }
        return XfdfXml.withoutBlankText(root)
    }

    private static func pairs(_ fdf: FdfFile, _ array: PdfArray) -> String {
        let numbers = array.items.map { (fdf.resolve($0) as? PdfNumber)?.text ?? "0" }
        var pairs: [String] = []
        var i = 0
        while i + 1 < numbers.count {
            pairs.append(numbers[i] + "," + numbers[i + 1])
            i += 2
        }
        return pairs.joined(separator: ";")
    }

    private static func hexOf(_ color: PdfObject?) -> String? {
        guard let array = color as? PdfArray, [1, 3, 4].contains(array.items.count) else { return nil }
        let n = array.items.map { ($0 as? PdfNumber)?.value ?? 0 }
        var r = 0.0, g = 0.0, b = 0.0
        switch n.count {
        case 1: (r, g, b) = (n[0], n[0], n[0])
        case 3: (r, g, b) = (n[0], n[1], n[2])
        default: (r, g, b) = ((1 - n[0]) * (1 - n[3]), (1 - n[1]) * (1 - n[3]), (1 - n[2]) * (1 - n[3]))
        }
        func byte(_ v: Double) -> String {
            String(format: "%02lX", Int((min(max(v.isNaN ? 0 : v, 0), 1) * 255).rounded(.toNearestOrEven)))
        }
        return "#" + byte(r) + byte(g) + byte(b)
    }

    private static func hexColor(_ text: String?) -> [Double]? {
        guard let text, text.utf16.count == 7, text.hasPrefix("#"), let rgb = InvariantNumbers.parseHex(String(text.dropFirst())) else { return nil }
        return [Double((rgb >> 16) & 255) / 255.0, Double((rgb >> 8) & 255) / 255.0, Double(rgb & 255) / 255.0]
    }

    private static func parseFlags(_ text: String) -> Int {
        var flags = 0
        for part in text.split(separator: ",", omittingEmptySubsequences: true) {
            let name = part.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if let bit = flagNames.firstIndex(of: name) { flags |= 1 << bit }
        }
        return flags
    }

    // Numbers separated by commas, semicolons or spaces.
    private static func numbers(_ text: String?) -> [Double] {
        guard let text, !text.unicodeScalars.allSatisfy({ $0.properties.isWhitespace }) else { return [] }
        var list: [Double] = []
        let separators = Set(",; \t\r\n".unicodeScalars)
        for part in text.unicodeScalars.split(whereSeparator: { separators.contains($0) }) {
            if list.count >= 1_000_000 { break }
            list.append(InvariantNumbers.parseDouble(String(String.UnicodeScalarView(part))) ?? 0)
        }
        return list
    }

    private static func array(_ numbers: [Double]) -> PdfArray { PdfArray(numbers.map { PdfNumber($0) }) }

    private static func clean(_ text: String) -> String {
        var result = String.UnicodeScalarView()
        for c in text.unicodeScalars {
            let v = c.value
            if v == 9 || v == 10 || v == 13 || (v >= 0x20 && v <= 0xD7FF) || (v >= 0xE000 && v <= 0xFFFD) || v >= 0x10000 {
                result.append(c)
            }
        }
        return String(result)
    }
}
