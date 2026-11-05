import Foundation

// Twin of windows/LazyPDF.Core/Document/PdfDocument.Streams.cs: stream data. The length is taken from /Length
// when "endstream" follows it; otherwise from the keyword itself, as viewers do.

extension PdfDocument {
    /// Whitespace tolerated between a stream's declared end and "endstream".
    private static let endstreamSlack = 16

    /// The data of `stream` as stored: decrypted, filters still applied. The array of a stream whose
    /// `PdfStream.data` was set is that data itself.
    public func rawData(_ stream: PdfStream) -> [UInt8] {
        if let memory = stream.data { return memory }
        if stream.dataOffset < 0 || stream.dataOffset > source.count { return [] }
        let start = stream.dataOffset
        let raw = Array(source[start..<start + streamLength(stream, start)])
        guard let security, stream.number > 0, name(stream.dictionary, "Type") != "XRef" else { return raw }
        return security.decryptStream(stream.number, stream.generation, raw, cryptView(stream.dictionary))
    }

    /// The data of `stream` decrypted and decoded, with /Length, /Filter and /DecodeParms resolved first.
    /// Throws `PdfReadException` for a filter that is not supported or data that does not decode.
    public func data(_ stream: PdfStream) throws -> [UInt8] {
        try data(stream, PdfFilters.defaultMaxSize)
    }

    func data(_ stream: PdfStream, _ maxSize: Int, strict: Bool = false) throws -> [UInt8] {
        let (filter, parameters, _) = decodeSpec(stream)
        return try PdfFilters.decode(rawData(stream), filter, parameters, maxSize, strict: strict)
    }

    /// The stream's dictionary with /Filter and /DecodeParms direct. The security handler reads them for the
    /// Crypt filter, on writing as on reading, so both must see the same thing.
    func cryptView(_ stream: PdfDictionary) -> PdfDictionary {
        let view = stream.copy()
        view["Filter"] = flatten(stream["Filter"], 3)
        view["DecodeParms"] = flatten(stream["DecodeParms"], 3)
        return view
    }

    /// What the filter layer is given: the resolved /Filter and /DecodeParms of an encrypted file's stream
    /// without the Crypt stage, which the decryption has already carried out. `crypt` says there was one.
    func decodeSpec(_ stream: PdfStream) -> (filter: PdfObject?, parameters: PdfObject?, crypt: Bool) {
        let filter = flatten(stream.dictionary["Filter"], 2)
        var parameters = flatten(stream.dictionary["DecodeParms"], 3)
        if security == nil { return (filter, parameters, false) }
        if let name = filter as? PdfName, name.value == "Crypt" { return (nil, nil, true) }
        if let array = filter as? PdfArray, let at = array.items.firstIndex(where: { ($0 as? PdfName)?.value == "Crypt" }) {
            let rest = PdfArray(array.items.enumerated().filter { $0.offset != at }.map { $0.element })
            if let list = parameters as? PdfArray, at < list.items.count {
                parameters = PdfArray(list.items.enumerated().filter { $0.offset != at }.map { $0.element })
            }
            return (rest, parameters, true)
        }
        return (filter, parameters, false)
    }

    private func streamLength(_ stream: PdfStream, _ start: Int) -> Int {
        // While the cross-reference data is being read an indirect /Length cannot be looked up.
        let declared = loadingXref ? (stream.dictionary["Length"] as? PdfNumber)?.integer : integer(stream.dictionary, "Length")
        if let declared, declared >= 0, declared <= source.count - start, endstreamFollows(start + declared) { return declared }
        if lengthRepaired.insert(stream.dataOffset).inserted {
            addRepair("Stream \(stream.number): /Length is wrong or missing; its data was taken up to endstream.")
        }
        return findStreamEnd(start) - start
    }

    func endstreamFollows(_ position: Int) -> Bool {
        var position = position
        let end = Swift.min(position + Self.endstreamSlack, source.count)
        while position < end && PdfLexer.isWhiteSpace(Int(source[position])) { position += 1 }
        return source.hasPattern("endstream".keywordBytes, at: position)
    }

    func findStreamEnd(_ start: Int) -> Int {
        var end = indexFrom("endstream".keywordBytes, &lastEndstream, start)
        if end < 0 { end = indexFrom("endobj".keywordBytes, &lastEndobj, start) }
        if end < 0 { end = source.count }
        // The line break before the keyword is not data.
        if end > start && source[end - 1] == 10 { end -= 1 }
        if end > start && source[end - 1] == 13 { end -= 1 }
        return end
    }

    /// The first `pattern` at or after `start`, or -1. Knowing the last one in the file spares a scan to the end
    /// for each stream that has none.
    private func indexFrom(_ pattern: [UInt8], _ last: inout Int, _ start: Int) -> Int {
        if last == -2 { last = source.lastIndexOf(pattern) ?? -1 }
        if last < start { return -1 }
        return source.indexOf(pattern, from: start) ?? -1
    }
}
