import Foundation

// Twin of windows/LazyPDF.Core/Accessibility/PdfUaMarker.cs.

enum PdfUaMarker {
    /// False, with the file untouched, when the existing packet cannot be read or sits behind a Crypt filter.
    static func write(_ document: PdfDocument, _ date: DateTimeOffset) throws -> Bool {
        let meta = DocumentMetadata.read(document)
        let existing = document.stream(document.catalog, "Metadata")
        if let existing, DocumentMetadata.hasCryptFilter(document, existing) || XmpPacket.load(document) == nil { return false }

        let stream: PdfStream
        if let existing {
            stream = existing
        } else {
            let dictionary = PdfDictionary()
            dictionary["Type"] = PdfName("Metadata")
            dictionary["Subtype"] = PdfName("XML")
            stream = PdfStream(dictionary, data: PdfAPacket.xmp(.a2b, meta, date, false))
            document.catalog["Metadata"] = try document.add(stream)
        }
        let xmp = XmpPacket.load(document)!
        xmp.set(XmpPacket.pdfuaId, "pdfuaid", "part", "1")
        if DotNetText.isNullOrWhiteSpace(xmp.get(XmpPacket.dc, "title")), !DotNetText.isNullOrWhiteSpace(meta.title) { xmp.setAlt(XmpPacket.dc, "dc", "title", meta.title) }
        if xmp.has(XmpPacket.pdfaId, "part") { xmp.declarePdfUaSchema() }
        stream.data = xmp.toBytes()
        stream.dictionary.remove("Filter")
        stream.dictionary.remove("DecodeParms")

        var settings = ViewerSettings.read(document)
        settings.displayDocTitle = true
        settings.write(document)
        return true
    }
}
