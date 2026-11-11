import Foundation

// Twin of windows/LazyPDF.Core/Filters/PdfFilters.cs, from Lazy Scan's PdfFilters.cs, extended to the whole
// filter set of ISO 32000-1 7.4.
//
// Flate is Flate.swift, the engine's own inflater, not a system library: the limits and the tolerance of the
// C# (which reads through DeflateStream) are part of what is ported. CCITT, LZW and the ASCII filters are
// ported as they are. DCT, JPX and JBIG2 stay image codecs, as in the C#.

/// A stream's data with its filters undone up to an image codec; `codec` is nil when none is left.
public struct PdfDecodedStream {
    public let data: [UInt8]
    public let codec: String?
    public let parameters: PdfDictionary?

    public init(_ data: [UInt8], _ codec: String?, _ parameters: PdfDictionary?) {
        self.data = data
        self.codec = codec
        self.parameters = parameters
    }
}

/// The stream filters (ISO 32000-1 7.4) and the predictors that go with Flate and LZW.
public enum PdfFilters {
    /// The most a filter chain may expand to unless the caller says otherwise.
    public static let defaultMaxSize = 256 << 20

    private static let maxColors = 1 << 16

    /// The data of a stream with its filters undone. Both arguments are resolved: a name or an
    /// array of names, a dictionary or an array of them. An image codec (DCT, JPX, JBIG2) is
    /// `PdfReadProblem.unsupported` here; see `decodeToCodec`.
    public static func decode(_ data: [UInt8], _ filter: PdfObject?, _ parameters: PdfObject?, _ maxSize: Int = defaultMaxSize) throws -> [UInt8] {
        try decode(data, filter, parameters, maxSize, strict: false)
    }

    /// With `strict` a Flate stream that breaks off or does not decode cleanly is damage, not a short result.
    static func decode(_ data: [UInt8], _ filter: PdfObject?, _ parameters: PdfObject?, _ maxSize: Int, strict: Bool) throws -> [UInt8] {
        try run(data, filter, parameters, maxSize, stopAtCodec: false, strict: strict).data
    }

    /// Undoes the filters before an image codec and stops there: the bytes are the codec's input
    /// (a JPEG file, say), with the codec's name ("DCTDecode", "JPXDecode" or "JBIG2Decode") and its
    /// /DecodeParms. Without a codec in the chain the data is fully decoded and the name is nil.
    public static func decodeToCodec(_ data: [UInt8], _ filter: PdfObject?, _ parameters: PdfObject?, _ maxSize: Int = defaultMaxSize) throws -> PdfDecodedStream {
        try run(data, filter, parameters, maxSize, stopAtCodec: true, strict: false)
    }

    private static func run(_ data: [UInt8], _ filter: PdfObject?, _ parameters: PdfObject?, _ maxSize: Int, stopAtCodec: Bool, strict: Bool) throws -> PdfDecodedStream {
        var data = data
        let filters: [String]
        switch filter {
        case nil, is PdfNull: filters = []
        case let name as PdfName: filters = [name.value]
        case let array as PdfArray: filters = array.items.map { ($0 as? PdfName)?.value ?? "" }
        default: throw PdfReadException.damaged("A stream's /Filter is not a name.")
        }
        let parameterList: [PdfDictionary?]
        switch parameters {
        case let array as PdfArray: parameterList = array.items.map { $0 as? PdfDictionary }
        case let dictionary as PdfDictionary: parameterList = [dictionary]
        default: parameterList = []
        }
        for (i, name) in filters.enumerated() {
            let decodeParms = i < parameterList.count ? parameterList[i] : nil
            switch name {
            case "FlateDecode", "Fl":
                data = try predict(try inflate(data, maxSize, strict), decodeParms)
            case "LZWDecode", "LZW":
                data = try predict(try LzwCodec.decode(data, int(decodeParms?["EarlyChange"], 1) != 0, maxSize), decodeParms)
            case "ASCIIHexDecode", "AHx":
                data = try AsciiFilters.decodeHex(data, maxSize)
            case "ASCII85Decode", "A85":
                data = try AsciiFilters.decode85(data, maxSize)
            case "RunLengthDecode", "RL":
                data = try AsciiFilters.decodeRunLength(data, maxSize)
            case "CCITTFaxDecode", "CCF":
                data = try decodeCcitt(data, decodeParms, maxSize)
            case "Crypt":
                // Decryption is the document layer's; /Identity leaves the data alone (ISO 32000-1 7.4.10).
                if let named = (decodeParms?["Name"] as? PdfName)?.value, named != "Identity" {
                    throw PdfReadException(.unsupported, "A named crypt filter reached the filter layer.")
                }
            case "DCTDecode", "DCT", "JPXDecode", "JBIG2Decode":
                if !stopAtCodec { throw PdfReadException(.unsupported, "The /\(name) filter is an image codec.") }
                return PdfDecodedStream(data, name == "DCT" ? "DCTDecode" : name, decodeParms)
            default:
                throw PdfReadException(.unsupported, "The /\(name) filter is not supported.")
            }
        }
        return PdfDecodedStream(data, nil, nil)
    }

    private static func decodeCcitt(_ data: [UInt8], _ p: PdfDictionary?, _ maxSize: Int) throws -> [UInt8] {
        let columns = int(p?["Columns"], 1728)
        if columns < 1 || columns > 1 << 20 { throw PdfReadException.damaged("A CCITT stream has /Columns out of range.") }
        return try Ccitt.decode(data, int(p?["K"], 0), columns, max(0, int(p?["Rows"], 0)),
                                bool(p?["EncodedByteAlign"]), bool(p?["EndOfLine"]), bool(p?["BlackIs1"]), maxSize)
    }

    /// zlib data inflated; raw deflate data (no zlib header) is accepted too. Data that breaks
    /// off or fails its checksum gives what decoded before the break; nothing decoded is damage.
    public static func inflate(_ data: [UInt8], _ maxSize: Int = defaultMaxSize) throws -> [UInt8] {
        try inflate(data, maxSize, false)
    }

    private static func inflate(_ data: [UInt8], _ maxSize: Int, _ strict: Bool) throws -> [UInt8] {
        if data.isEmpty { return [] }
        let output = FilterBuffer(maxSize, capacity: min(data.count * 4, 1 << 22))
        // The deflate stream is read bare, past a valid zlib header: the Adler-32 check would throw away
        // the last block of a file whose checksum is wrong (ISO 32000-1 7.4.4).
        let header = data.count >= 2 && (data[0] & 0x0F) == 8 && (Int(data[0]) * 256 + Int(data[1])) % 31 == 0 ? 2 : 0
        var ended = try inflateFrom(data, header, output, strict)
        if output.count == 0 && !ended && header > 0 { ended = try inflateFrom(data, 0, output, strict) }
        if output.count == 0 && !ended { throw PdfReadException.damaged("A compressed stream does not inflate.") }
        return output.toArray()
    }

    private static func inflateFrom(_ data: [UInt8], _ start: Int, _ output: FilterBuffer, _ strict: Bool) throws -> Bool {
        let ended = try Flate.inflate(data, start, output)
        if !ended && strict && output.count > 0 { throw PdfReadException.damaged("A compressed stream breaks off.") }
        return ended
    }

    /// Undoes a /Predictor (ISO 32000-1 7.4.4.4): 2 (TIFF) or 10-15 (PNG, each row with its own
    /// filter byte), at 1, 2, 4, 8 or 16 bits per component. A last row cut short is kept as far as it goes.
    public static func predict(_ data: [UInt8], _ parameters: PdfDictionary?) throws -> [UInt8] {
        let predictor = int(parameters?["Predictor"], 1)
        if predictor <= 1 || data.isEmpty { return data }
        let colors = max(1, int(parameters?["Colors"], 1))
        if colors > maxColors { throw PdfReadException.damaged("A predictor with \(colors) colors.") }
        let bitsPerComponent = int(parameters?["BitsPerComponent"], 8)
        let columns = max(1, int(parameters?["Columns"], 1))
        if ![1, 2, 4, 8, 16].contains(bitsPerComponent) {
            throw PdfReadException.damaged("A predictor with \(bitsPerComponent) bits per component.")
        }
        if predictor != 2 && predictor < 10 { throw PdfReadException(.unsupported, "Predictor \(predictor) is not supported.") }
        // A row longer than the data is one short row; this keeps a bad /Columns from allocating.
        let rowBits = colors * bitsPerComponent * columns
        let rowLength = min((rowBits + 7) / 8, data.count)
        return predictor == 2
            ? predictTiff(data, rowLength, colors, bitsPerComponent, columns)
            : predictPng(data, rowLength, min((colors * bitsPerComponent + 7) / 8, rowLength))
    }

    private static func predictTiff(_ data: [UInt8], _ rowLength: Int, _ colors: Int, _ bits: Int, _ columns: Int) -> [UInt8] {
        var output = data
        var start = 0
        while start < output.count {
            let length = min(rowLength, output.count - start)
            switch bits {
            case 8:
                var i = colors
                while i < length {
                    output[start + i] = output[start + i] &+ output[start + i - colors]
                    i += 1
                }
            case 16:
                var i = colors * 2
                while i + 1 < length {
                    let a = start + i
                    let b = a - colors * 2
                    let sum = (Int(output[a]) << 8 | Int(output[a + 1])) + (Int(output[b]) << 8 | Int(output[b + 1]))
                    output[a] = UInt8(truncatingIfNeeded: sum >> 8)
                    output[a + 1] = UInt8(truncatingIfNeeded: sum)
                    i += 2
                }
            default:
                let count = min(columns * colors, length * 8 / bits)
                let mask = (1 << bits) - 1
                var j = colors
                while j < count {
                    let sum = component(output, start, j, bits) + component(output, start, j - colors, bits)
                    let shift = 8 - bits - j * bits % 8
                    let at = start + j * bits / 8
                    output[at] = UInt8(truncatingIfNeeded: (Int(output[at]) & ~(mask << shift)) | ((sum & mask) << shift))
                    j += 1
                }
            }
            start += rowLength
        }
        return output
    }

    private static func component(_ row: [UInt8], _ start: Int, _ index: Int, _ bits: Int) -> Int {
        (Int(row[start + index * bits / 8]) >> (8 - bits - index * bits % 8)) & ((1 << bits) - 1)
    }

    private static func predictPng(_ data: [UInt8], _ rowLength: Int, _ bytesPerPixel: Int) -> [UInt8] {
        let bytesPerPixel = max(1, bytesPerPixel)
        let step = rowLength + 1
        let rem = data.count % step
        var output = [UInt8](repeating: 0, count: (data.count / step) * rowLength + max(rem - 1, 0))
        var at = 0, written = 0, previous = -1
        while at < data.count - 1 {
            let type = data[at]
            at += 1
            let n = min(rowLength, data.count - at)
            for i in 0..<n { output[written + i] = data[at + i] }
            // Other row filter bytes leave the row as it is, as other readers do.
            switch type {
            case 1:
                var i = bytesPerPixel
                while i < n {
                    output[written + i] = output[written + i] &+ output[written + i - bytesPerPixel]
                    i += 1
                }
            case 2:
                for i in 0..<n {
                    output[written + i] = output[written + i] &+ (previous >= 0 ? output[previous + i] : 0)
                }
            case 3:
                for i in 0..<n {
                    let left = i >= bytesPerPixel ? Int(output[written + i - bytesPerPixel]) : 0
                    let up = previous >= 0 ? Int(output[previous + i]) : 0
                    output[written + i] = output[written + i] &+ UInt8(truncatingIfNeeded: (left + up) / 2)
                }
            case 4:
                for i in 0..<n {
                    let inside = i >= bytesPerPixel
                    let left = inside ? Int(output[written + i - bytesPerPixel]) : 0
                    let up = previous >= 0 ? Int(output[previous + i]) : 0
                    let upLeft = inside && previous >= 0 ? Int(output[previous + i - bytesPerPixel]) : 0
                    output[written + i] = output[written + i] &+ UInt8(truncatingIfNeeded: paeth(left, up, upLeft))
                }
            default:
                break
            }
            previous = written
            written += n
            at += n
        }
        return output
    }

    private static func paeth(_ a: Int, _ b: Int, _ c: Int) -> Int {
        let p = a + b - c
        let pa = abs(p - a), pb = abs(p - b), pc = abs(p - c)
        return pa <= pb && pa <= pc ? a : pb <= pc ? b : c
    }

    static func int(_ value: PdfObject?, _ fallback: Int) -> Int {
        if let n = (value as? PdfNumber)?.integer, n >= Int(Int32.min) && n <= Int(Int32.max) { return n }
        return fallback
    }

    static func bool(_ value: PdfObject?) -> Bool {
        (value as? PdfBoolean)?.value == true
    }
}
