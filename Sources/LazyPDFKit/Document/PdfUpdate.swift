import Foundation

// Twin of windows/LazyPDF.Core/Document/PdfUpdate.cs: an incremental update (ISO 32000-1 7.5.6), the changed and
// new objects after the original bytes, then a cross-reference section of the kind the file already ends with.

enum PdfUpdate {
    /// The bytes to append to the document's source; empty when nothing changed.
    static func build(_ document: PdfDocument) throws -> [UInt8] {
        let changed = document.changedObjects()
        let freed = document.deletedObjects
        if changed.isEmpty && freed.isEmpty && !document.trailerChanged { return [] }

        let source = document.source
        let writer = PdfObjectWriter(position: source.count, security: document.security)
        // The update starts on a line of its own.
        if let last = source.last, last != 10 && last != 13 { writer.writeBytes([10]) }

        var entries: [XrefEntry] = []
        for number in changed {
            // Objects that came from an object stream are written as plain objects.
            guard let value = document.get(number) else { continue }
            let generation = document.generationOf(number)
            let plain = number == document.encryptNumber
            let at: Int
            if let stream = value as? PdfStream {
                let view = document.security == nil ? nil : document.cryptView(stream.dictionary)
                at = writer.writeStream(number, generation, stream.dictionary, document.rawData(stream), encrypt: !plain, cryptView: view)
            } else {
                at = writer.writeObject(number, generation, value, encrypt: !plain)
            }
            entries.append(XrefEntry(number, 1, at, generation))
        }
        for i in 0..<freed.count {
            entries.append(XrefEntry(freed[i], 0, i + 1 < freed.count ? freed[i + 1] : 0, document.generationOf(freed[i])))
        }
        if let head = freed.first { entries.append(XrefEntry(0, 0, head, 65535)) }

        // After a rebuild the file's own sections cannot be built on, and past the reader's chain limit it would not read back, so this one lists everything.
        let full = document.xrefRebuilt || document.sectionOffsets.count >= PdfDocument.maxSections
        if full {
            let written = Set(entries.map { $0.number })
            for (number, entry) in document.entries where !written.contains(number) {
                switch entry.kind {
                case .inUse:
                    entries.append(XrefEntry(number, 1, entry.offset, entry.generation))
                case .compressed:
                    entries.append(XrefEntry(number, 2, entry.streamNumber, document.indexInObjectStream(number)))
                default:
                    break
                }
            }
            if freed.isEmpty { entries.append(XrefEntry(0, 0, 0, 65535)) }
        }
        // Only the trailer changed.
        if entries.isEmpty { entries.append(XrefEntry(0, 0, 0, 65535)) }
        entries.sort { $0.number < $1.number }

        let asStream = document.xrefIsStream || entries.contains { $0.type == 2 }
        let size = max(document.nextObjectNumber, (entries.last?.number ?? 0) + 1)
        // The cross-reference stream is an object too, and PDF has no number past the limit for it.
        if asStream && size > PdfDocument.maxObjectNumber { throw PdfReadException.damaged("The file has no object numbers left.") }
        let trailer = PdfDictionary()
        trailer.add("Size", PdfNumber(asStream ? size + 1 : size))
        for (key, value) in document.trailer.entries where key != "Size" && key != "Prev" && key != "XRefStm" && key != "ID" {
            trailer.add(key, value)
        }
        if document.infoRemoved { trailer.add("Info", PdfNull.instance) }
        trailer.add("ID", PdfXrefWriter.idPair(document.firstId ?? PdfSecurity.systemRandom(16)))
        if !full { trailer.add("Prev", PdfNumber(document.startXref)) }

        if asStream {
            PdfXrefWriter.writeStream(writer, size, entries, trailer, compress: false)
        } else {
            PdfXrefWriter.writeTable(writer, entries, trailer)
        }
        return writer.output
    }
}
