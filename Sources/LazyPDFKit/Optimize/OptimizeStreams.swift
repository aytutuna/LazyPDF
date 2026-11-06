import Foundation

// Twin of windows/LazyPDF.Core/Optimize/OptimizeStreams.cs: Flate at the smallest level for every stream, and the
// older text and run-length filters turned into Flate.

enum OptimizeStreams {
    private static let flate: Set<String> = ["FlateDecode", "Fl"]
    private static let old: Set<String> = ["LZWDecode", "LZW", "ASCII85Decode", "A85", "ASCIIHexDecode", "AHx", "RunLengthDecode", "RL"]
    private static let predictorKeys = ["Predictor", "Colors", "BitsPerComponent", "Columns"]

    /// Returns (streams recompressed, streams converted from the old filters).
    static func run(_ document: PdfDocument, _ recompress: Bool, _ convert: Bool) -> (recompressed: Int, converted: Int) {
        var recompressed = 0
        var converted = 0
        for (_, value) in PdfGraph.objects(document) {
            guard let stream = value as? PdfStream else { continue }
            guard let names = filters(document, stream), !names.isEmpty else { continue }
            let isOld = names.contains { old.contains($0) }
            if isOld ? !convert : !recompress { continue }
            if let type = document.name(stream.dictionary, "Type"), type == "Metadata" || type == "XRef" || type == "ObjStm" { continue }
            if !encode(document, stream, names) { continue }
            if isOld { converted += 1 } else { recompressed += 1 }
        }
        return (recompressed, converted)
    }

    // Nil for a chain with an image codec or anything else that is not left to us.
    private static func filters(_ document: PdfDocument, _ stream: PdfStream) -> [String]? {
        let names: [String]
        switch document.decodeSpec(stream).filter {
        case let name as PdfName: names = [name.value]
        case let array as PdfArray: names = array.items.map { ($0 as? PdfName)?.value ?? "" }
        default: names = []
        }
        return names.allSatisfy { flate.contains($0) || old.contains($0) } ? names : nil
    }

    private static func encode(_ document: PdfDocument, _ stream: PdfStream, _ filters: [String]) -> Bool {
        let dictionary = stream.dictionary
        let each: [PdfDictionary?]
        switch document.decodeSpec(stream).parameters {
        case let array as PdfArray: each = array.items.map { $0 as? PdfDictionary }
        case let single as PdfDictionary: each = [single]
        default: each = []
        }
        // A predictor belongs to the last stage; the new stream keeps it and only the stage under it changes.
        var predictor: PdfDictionary?
        var stripped: [PdfObject] = []
        for i in 0..<filters.count {
            let p = i < each.count ? each[i] : nil
            let plain = p?.copy() ?? PdfDictionary()
            if let p, (document.integer(p, "Predictor") ?? 0) > 1 {
                if i != filters.count - 1 { return false }
                let kept = PdfDictionary()
                for key in predictorKeys {
                    if let v = p[key] { kept[key] = v }
                    plain.remove(key)
                }
                predictor = kept
            }
            stripped.append(plain)
        }
        let raw = document.rawData(stream)
        let data: [UInt8]
        do {
            data = try PdfFilters.decode(raw, PdfArray(filters.map { PdfName($0) }), PdfArray(stripped), PdfFilters.defaultMaxSize, strict: true)
        } catch {
            return false
        }
        let packed = PdfFilterEncoders.flate(data, .smallestSize)
        let onlyFlate = filters.count == 1 && flate.contains(filters[0])
        // The same filter again only has to be smaller; a different one is worth the change when it is not larger.
        if onlyFlate ? packed.count >= raw.count : packed.count > raw.count { return false }
        stream.data = packed
        dictionary["Filter"] = PdfName("FlateDecode")
        if let predictor { dictionary["DecodeParms"] = predictor } else { dictionary.remove("DecodeParms") }
        return true
    }
}
