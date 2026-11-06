import Foundation

// Twin of windows/LazyPDF.Core/Export/ExportImages.cs: turns the images a page paints into files. A JPEG that a JPEG
// file shows as the page does goes out as its own bytes; the rest are decoded and written as PNG with their masks,
// /Decode and colour space applied. Results are kept per image object, and per picture for inline images, so a logo on
// every page is decoded once.
//
// An inline image whose dictionary holds a stream is left out before it is written as text: `PdfObject.description` of a
// stream stops the process, where the C# throws InvalidOperationException and catches it. The cancellation of the task
// is checked where the C# checks its token.

final class ExportImages {
    // Past this many pixels an image is left out rather than decoded (rule 4).
    private static let maxPixels = 1 << 26

    private struct StreamKey: Hashable {
        let stream: PdfStream
        let orientation: Int

        static func == (a: StreamKey, b: StreamKey) -> Bool { a.stream === b.stream && a.orientation == b.orientation }

        func hash(into hasher: inout Hasher) {
            hasher.combine(ObjectIdentifier(stream))
            hasher.combine(orientation)
        }
    }

    private struct InlineKey: Hashable {
        let text: String
        let orientation: Int
    }

    private let document: PdfDocument
    private let codec: ImageCodec?
    private let byteLimit: Int
    private let merge: ExportImageMerge
    private var streams: [StreamKey: ExportImage?] = [:]
    private var inline: [InlineKey: ExportImage?] = [:]
    private var total = 0

    /// Pictures left out because they or the pictures before them passed a memory limit; one the codec cannot read does
    /// not count.
    private(set) var leftOut = 0

    init(_ document: PdfDocument, _ codec: ImageCodec?, pixelBudget: Int = 1 << 32, byteLimit: Int = 1 << 29) {
        self.document = document
        self.codec = codec
        self.byteLimit = byteLimit
        merge = ExportImageMerge(document, codec, pixelBudget)
    }

    /// The picture for `info`. `orientation` (1 to 8, as in Exif) turns its pixels to the way the page shows them; a
    /// JPEG kept as its own bytes cannot be turned.
    func get(_ info: ImageInfo, _ orientation: Int = 1) throws -> ExportImage? {
        if let stream = info.stream {
            let key = StreamKey(stream: stream, orientation: orientation)
            if let known = streams[key] { return known }
            let image = try make(info.dictionary, document.rawData(stream), stream, orientation)
            streams[key] = image
            return image
        }
        guard let data = info.inline?.data else { return nil }
        // A stream cannot be written inline; a colour space that resolves to one is damage.
        if Self.holdsStream(info.dictionary) { return nil }
        let key = InlineKey(text: "\(info.dictionary.description)|\(Data(Sha256.hash(data)).base64EncodedString())", orientation: orientation)
        if let known = inline[key] { return known }
        let image = try make(info.dictionary, data, nil, orientation)
        inline[key] = image
        return image
    }

    private static func holdsStream(_ object: PdfObject) -> Bool {
        var pending: [PdfObject] = [object]
        while let next = pending.popLast() {
            switch next {
            case is PdfStream: return true
            case let array as PdfArray: pending += array.items
            case let dictionary as PdfDictionary: pending += dictionary.entries.map { $0.value }
            default: break
            }
        }
        return false
    }

    private func make(_ dictionary: PdfDictionary, _ raw: [UInt8], _ stream: PdfStream?, _ orientation: Int) throws -> ExportImage? {
        do {
            try Task.checkCancellation()
            let width = document.integer(dictionary, "Width") ?? 0, height = document.integer(dictionary, "Height") ?? 0
            if width < 1 || height < 1 { return nil }
            if width > Self.maxPixels / height { return dropped() }

            let filter: PdfObject?, parameters: PdfObject?
            if let stream {
                let spec = document.decodeSpec(stream)
                filter = spec.filter
                parameters = spec.parameters
            } else {
                filter = dictionary["Filter"]
                parameters = dictionary["DecodeParms"]
            }
            let decoded = try PdfFilters.decodeToCodec(raw, filter, parameters, max(0, byteLimit - total))

            func jpeg() -> ExportImage { ExportImage(decoded.data, true, width, height) }
            if decoded.codec == "DCTDecode" && orientation == 1, try merge.showsAsFile(dictionary, decoded.data) { return keep(jpeg()) }

            // Past a limit a JPEG is still kept as its bytes: they are in hand and cost nothing to decode.
            var pixels: PdfRgbaImage?
            do {
                if total > byteLimit { throw PdfReadException(.unsupported, ExportText.tooLarge) }
                pixels = try self.pixels(dictionary, decoded, width * height)
            } catch is PdfReadException where decoded.codec == "DCTDecode" {
            }
            guard var shown = pixels else { return decoded.codec == "DCTDecode" ? keep(jpeg()) : nil }
            shown = ExportImageTurn.apply(shown, orientation)
            return keep(ExportImage(try PngWriter.encode(shown), false, shown.width, shown.height))
        } catch let e as PdfReadException {
            return e.message == ExportText.tooLarge || e.message == FilterBuffer.tooBig().message ? dropped() : nil
        }
    }

    private func dropped() -> ExportImage? {
        leftOut += 1
        return nil
    }

    // A mask that cannot be read leaves the picture opaque.
    private func pixels(_ dictionary: PdfDictionary, _ decoded: PdfDecodedStream, _ declared: Int) throws -> PdfRgbaImage? {
        do {
            return try decode(dictionary, decoded, declared)
        } catch let e as PdfReadException where e.problem == .damaged
            && (document.resolve(dictionary["SMask"]) is PdfStream || document.resolve(dictionary["Mask"]) is PdfStream) {
            let opaque = dictionary.copy()
            opaque.remove("SMask")
            opaque.remove("Mask")
            return try decode(opaque, decoded, declared)
        }
    }

    private func decode(_ dictionary: PdfDictionary, _ decoded: PdfDecodedStream, _ declared: Int) throws -> PdfRgbaImage? {
        guard let coder = decoded.codec else {
            try merge.charge(declared)
            return try merge.fromSamples(dictionary, decoded.data)
        }
        guard let codec else { return nil }
        try merge.charge(0)
        guard let coded = codec.decode(decoded.data, coder) else { return nil }
        guard let size = ExportImageMerge.area(coded) else { throw PdfReadException(.unsupported, ExportText.tooLarge) }
        try merge.charge(size)
        if size > Self.maxPixels { throw PdfReadException(.unsupported, ExportText.tooLarge) }
        if coded.width < 1 || coded.height < 1 || coded.rgba.count != size * 4 { return nil }
        return try merge.fromPixels(dictionary, coded, coder, decoded.data)
    }

    private func keep(_ image: ExportImage) -> ExportImage {
        total += image.data.count
        return image
    }
}
