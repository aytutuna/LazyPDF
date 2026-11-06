import Foundation

// Twin of windows/LazyPDF.Core/Standards/PdfAPacket.cs: from Lazy Scan's PdfA.cs (Xmp, CleanTitle): the packet is built
// as text; the part and level are the caller's and more of the document's own properties go in.

enum PdfAPacket {
    static func xmp(_ level: PdfALevel, _ meta: DocumentMetadata, _ metadataDate: DateTimeOffset, _ declare: Bool = true) -> [UInt8] {
        var sb = ""
        sb += "<?xpacket begin=\"\u{FEFF}\" id=\"W5M0MpCehiHzreSzNTczkc9d\"?>\n"
        sb += "<x:xmpmeta xmlns:x=\"adobe:ns:meta/\">\n"
        sb += " <rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\">\n"
        sb += "  <rdf:Description rdf:about=\"\"\n"
        if declare { sb += "    xmlns:pdfaid=\"http://www.aiim.org/pdfa/ns/id/\"\n" }
        sb += "    xmlns:dc=\"http://purl.org/dc/elements/1.1/\"\n"
        sb += "    xmlns:xmp=\"http://ns.adobe.com/xap/1.0/\"\n"
        sb += "    xmlns:pdf=\"http://ns.adobe.com/pdf/1.3/\">\n"
        if declare {
            sb += "   <pdfaid:part>\(level.part())</pdfaid:part>\n"
            if let conformance = level.conformance() {
                sb += "   <pdfaid:conformance>\(conformance)</pdfaid:conformance>\n"
            } else {
                sb += "   <pdfaid:rev>2020</pdfaid:rev>\n"
            }
        }
        sb += "   <dc:format>application/pdf</dc:format>\n"
        if let title = clean(meta.title) {
            sb += "   <dc:title><rdf:Alt><rdf:li xml:lang=\"x-default\">\(title)</rdf:li></rdf:Alt></dc:title>\n"
        }
        if let author = clean(meta.author) {
            sb += "   <dc:creator><rdf:Seq><rdf:li>\(author)</rdf:li></rdf:Seq></dc:creator>\n"
        }
        if let subject = clean(meta.subject) {
            sb += "   <dc:description><rdf:Alt><rdf:li xml:lang=\"x-default\">\(subject)</rdf:li></rdf:Alt></dc:description>\n"
        }
        if let created = meta.created { sb += "   <xmp:CreateDate>\(PdfDate.formatXmp(created))</xmp:CreateDate>\n" }
        if let modified = meta.modified { sb += "   <xmp:ModifyDate>\(PdfDate.formatXmp(modified))</xmp:ModifyDate>\n" }
        sb += "   <xmp:MetadataDate>\(PdfDate.formatXmp(metadataDate))</xmp:MetadataDate>\n"
        if let tool = clean(meta.creator) { sb += "   <xmp:CreatorTool>\(tool)</xmp:CreatorTool>\n" }
        if let producer = clean(meta.producer) { sb += "   <pdf:Producer>\(producer)</pdf:Producer>\n" }
        if let keywords = clean(meta.keywords) { sb += "   <pdf:Keywords>\(keywords)</pdf:Keywords>\n" }
        sb += "  </rdf:Description>\n"
        sb += " </rdf:RDF>\n"
        sb += "</x:xmpmeta>\n"
        sb += "<?xpacket end=\"w\"?>"
        return Array(sb.utf8)
    }

    /// The text with what XML cannot hold removed, line breaks as one LF and the ends trimmed, so that /Info and the XMP read the same; nil when nothing is left.
    static func strip(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        let units = Array(text.utf16)
        var kept: [UInt16] = []
        var i = 0
        while i < units.count {
            let c = units[i]
            if c >= 0xD800 && c <= 0xDBFF && i + 1 < units.count && units[i + 1] >= 0xDC00 && units[i + 1] <= 0xDFFF {
                kept.append(c)
                kept.append(units[i + 1])
                i += 2
                continue
            }
            if isXmlChar(c) { kept.append(c) }
            i += 1
        }
        var lines: [UInt16] = []
        var k = 0
        while k < kept.count {
            if kept[k] == 13 {
                lines.append(10)
                if k + 1 < kept.count && kept[k + 1] == 10 { k += 1 }
            } else {
                lines.append(kept[k])
            }
            k += 1
        }
        let clean = PdfDate.trimmed(String(decoding: lines, as: UTF16.self))
        return clean.isEmpty ? nil : clean
    }

    // XmlConvert.IsXmlChar of one UTF-16 unit: surrogates are only good in pairs, which the caller keeps.
    private static func isXmlChar(_ c: UInt16) -> Bool {
        c == 0x9 || c == 0xA || c == 0xD || (c >= 0x20 && c <= 0xD7FF) || (c >= 0xE000 && c <= 0xFFFD)
    }

    private static func clean(_ text: String?) -> String? {
        guard let stripped = strip(text) else { return nil }
        var result = String.UnicodeScalarView()
        for scalar in stripped.unicodeScalars {
            switch scalar {
            case "&": result.append(contentsOf: "&amp;".unicodeScalars)
            case "<": result.append(contentsOf: "&lt;".unicodeScalars)
            case ">": result.append(contentsOf: "&gt;".unicodeScalars)
            case "\"": result.append(contentsOf: "&quot;".unicodeScalars)
            default: result.append(scalar)
            }
        }
        return String(result)
    }

    /// The catalog's /OutputIntents entry, its profile in object `profile`.
    static func outputIntent(_ profile: PdfReference) -> PdfDictionary {
        let intent = PdfDictionary()
        intent["Type"] = PdfName("OutputIntent")
        intent["S"] = PdfName("GTS_PDFA1")
        intent["OutputConditionIdentifier"] = PdfString(bytes: Array(PdfASrgb.outputConditionIdentifier.utf8), isHex: false)
        intent["Info"] = PdfString(bytes: Array(PdfASrgb.outputConditionIdentifier.utf8), isHex: false)
        intent["DestOutputProfile"] = profile
        return intent
    }
}
