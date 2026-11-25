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

    /// The size of `rawData` without copying it.
    func rawLength(_ stream: PdfStream) -> Int {
        if let memory = stream.data { return memory.count }
        if stream.dataOffset < 0 || stream.dataOffset > source.count { return 0 }
        return streamLength(stream, stream.dataOffset)
    }

    /// The data of `stream` decrypted and decoded, with /Length, /Filter and /DecodeParms resolved first.
    /// Throws `PdfReadException` for a filter that is not supported or data that does not decode.
    public func data(_ stream: PdfStream) throws -> [UInt8] {
        try data(stream, PdfFilters.defaultMaxSize)
    }

    func data(_ stream: PdfStream, _ maxSize: Int, strict: Bool = false) throws -> [UInt8] {
        let (filter, parameters, _) = try decodeSpec(stream, decoding: true, maxSize)
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

    /// As `decodeSpec`, with a /JBIG2Globals stream coming with its decoded data in memory, which is what the filter
    /// reads; a caller that writes the parameters back uses the other and gets the stream as the file has it.
    /// Throws for globals that do not decode.
    func decodeSpec(_ stream: PdfStream, decoding: Bool, _ maxSize: Int = PdfFilters.defaultMaxSize) throws -> (filter: PdfObject?, parameters: PdfObject?, crypt: Bool) {
        var spec = decodeSpec(stream)
        if decoding { spec.parameters = try forJbig2(spec.filter, spec.parameters, stream.dictionary, maxSize) }
        return spec
    }

    // The JBIG2 stage of an image gets what it needs besides its own parameters: the decoded globals, and the size of the image,
    // which the stage fits its page to. A stream with no such stage is left alone, whatever its parameters hold.
    private func forJbig2(_ filter: PdfObject?, _ parameters: PdfObject?, _ image: PdfDictionary, _ maxSize: Int) throws -> PdfObject? {
        let names: [PdfObject]
        switch filter {
        case let name as PdfName: names = [name]
        case let array as PdfArray: names = array.items
        default: names = []
        }
        guard let at = names.firstIndex(where: { ($0 as? PdfName)?.value == "JBIG2Decode" }) else { return parameters }
        var each: [PdfObject] = []
        switch parameters {
        case let array as PdfArray: each = array.items
        case let single as PdfDictionary: each = [single]
        default: break
        }
        while each.count <= at { each.append(PdfNull.instance) }
        let stage = (each[at] as? PdfDictionary)?.copy() ?? PdfDictionary()
        if let globals = stage["JBIG2Globals"] as? PdfStream {
            stage["JBIG2Globals"] = PdfStream(PdfDictionary(), data: try globalsData(globals, maxSize))
        }
        let width = integer(image, "Width") ?? 0, height = integer(image, "Height") ?? 0
        if width >= 1 && width <= Int(Int32.max) && height >= 1 && height <= Int(Int32.max) {
            stage["Width"] = PdfNumber(width)
            stage["Height"] = PdfNumber(height)
        }
        each[at] = stage
        return PdfArray(each)
    }

    /// The most a globals stream may expand to; they hold symbols, not pictures.
    private static let maxGlobals = 32 << 20

    /// The data of a globals stream. Its own filters are read without any globals of theirs (a JBIG2 stage on it is damage),
    /// so that streams that name each other cannot send this round in circles.
    private func globalsData(_ globals: PdfStream, _ maxSize: Int) throws -> [UInt8] {
        if let known = globalsData, globalsOf === globals, sameBuffer(globalsSource, globals.data), known.count <= maxSize { return known }
        let (filter, parameters, _) = decodeSpec(globals)
        if PdfFilters.uses(filter, "JBIG2Decode") { throw PdfReadException.damaged("A JBIG2 globals stream is JBIG2 coded.") }
        let data = try PdfFilters.decode(rawData(globals), filter, parameters, Swift.min(maxSize, Self.maxGlobals), strict: false)
        globalsOf = globals
        globalsSource = globals.data
        globalsData = data
        return data
    }

    /// Whether two arrays are one and the same storage: the cache keeps its own, so a change to the stream's data
    /// makes a copy and shows here.
    private func sameBuffer(_ a: [UInt8]?, _ b: [UInt8]?) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        if a.isEmpty || b.isEmpty { return a.isEmpty && b.isEmpty }
        return a.withUnsafeBufferPointer { x in b.withUnsafeBufferPointer { y in x.baseAddress == y.baseAddress && x.count == y.count } }
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
