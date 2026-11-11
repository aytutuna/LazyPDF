import Foundation

// Twin of windows/LazyPDF.Core/Optimize/OptimizeImages.cs: lowers the resolution of images that are placed bigger
// than needed, and stores black and white pictures in one bit. An image is only replaced when the new data is
// smaller. Each image keeps its colour space, /Decode and soft mask; what cannot be carried over is left as it is.

final class OptimizeImages {
    private static let maxPixels = 16_000_000

    // Unpack holds every sample of the image; a row is limited as PdfImageSamples limits it.
    private static let maxSamples = 1 << 28
    private static let maxRowSamples = 1 << 26

    private let document: PdfDocument
    private let options: OptimizeOptions
    private let codec: ImageCodec?
    private var done = Set<ObjectIdentifier>()

    private(set) var bilevel = 0
    private(set) var downsampled = 0
    private(set) var needsCodec = false

    /// Some image was left at its size because a use of it could not be measured.
    private(set) var partial = false

    init(_ document: PdfDocument, _ options: OptimizeOptions, _ codec: ImageCodec?) {
        self.document = document
        self.options = options
        self.codec = codec
    }

    func run() throws {
        var images: [PdfStream] = []
        for (_, value) in PdfGraph.objects(document) {
            if let stream = value as? PdfStream, document.name(stream.dictionary, "Subtype") == "Image",
               document.bool(stream.dictionary, "ImageMask") != true {
                images.append(stream)
            }
        }
        if options.bilevelTolerance >= 0 {
            for image in images {
                try Task.checkCancellation()
                if tryBilevel(image) { bilevel += 1 }
            }
        }
        if options.imageDpi <= 0 { return }
        let placed = PlacedImages.measure(document)
        if !placed.complete {
            partial = images.contains { image in
                guard let seen = placed.found[ObjectIdentifier(image)] else { return true }
                return exceeds(seen)
            }
            return
        }
        let unseen = self.unseen(placed)
        for image in images {
            try Task.checkCancellation()
            guard let placement = placed.found[ObjectIdentifier(image)] else { continue }
            if unseen.contains(ObjectIdentifier(image)) {
                if exceeds(placement) { partial = true }
            } else if tryShrink(image, placement) {
                downsampled += 1
            }
        }
    }

    // Images listed by resources the walk never reached, and by the forms, patterns and soft mask groups those
    // use, may be painted somewhere nobody measured (a Type 3 glyph, an appearance state not shown).
    private func unseen(_ walk: PlacedImages) -> Set<ObjectIdentifier> {
        var set = Set<ObjectIdentifier>()
        var visited = Set<ObjectIdentifier>()
        var forms: [PdfStream] = []
        func enter(_ value: PdfObject?) {
            if let stream = document.resolve(value) as? PdfStream, OptimizeWalk.isForm(document, stream), visited.insert(ObjectIdentifier(stream)).inserted {
                forms.append(stream)
            }
        }
        func list(_ resources: PdfDictionary?) {
            for (_, value) in document.dict(resources, "XObject")?.entries ?? [] {
                guard let xobject = document.resolve(value) as? PdfStream else { continue }
                set.insert(ObjectIdentifier(xobject))
                enter(xobject)
            }
            for (_, value) in document.dict(resources, "Pattern")?.entries ?? [] { enter(value) }
            for (_, value) in document.dict(resources, "ExtGState")?.entries ?? [] {
                if let mask = document.dict(document.resolve(value) as? PdfDictionary, "SMask") { enter(mask["G"]) }
            }
        }
        for dictionary in PdfGraph.allDictionaries(document) {
            if let resources = document.dict(dictionary, "Resources"), !walk.reached(resources) { list(resources) }
        }
        while let form = forms.popLast() { list(document.dict(form.dictionary, "Resources")) }
        return set
    }

    private func exceeds(_ placement: Placement) -> Bool {
        let above = Double(Swift.max(options.imageDpiAbove, options.imageDpi))
        return placement.dpiX > above || placement.dpiY > above
    }

    // (int) of a long in an unchecked context keeps the low 32 bits.
    private func size(_ dictionary: PdfDictionary?, _ key: String) -> Int {
        Int(Int32(truncatingIfNeeded: document.integer(dictionary, key) ?? 0))
    }

    private func tryBilevel(_ stream: PdfStream) -> Bool {
        let dictionary = stream.dictionary
        let width = size(dictionary, "Width")
        let height = size(dictionary, "Height")
        if width < 1 || height < 1 || width * height > Self.maxPixels { return false }
        if dictionary.containsKey("Decode") || document.resolve(dictionary["Mask"]) is PdfArray || dictionary.containsKey("SMaskInData") || hasMatte(dictionary) { return false }
        let family = ImageKit.describe(document, dictionary["ColorSpace"]).family
        let bpc = document.integer(dictionary, "BitsPerComponent") ?? 8
        if family == .unknown || family == .spot || family == .lab || (bpc == 1 && family == .gray) { return false }
        guard let samples = samples(stream) else { return false }
        let plain = dictionary.copy()
        plain.remove("SMask")
        plain.remove("Mask")
        let pixels: PdfRgbaImage
        do {
            pixels = try PdfImageSamples.toRgba(plain, samples, { self.document.resolve($0) }, { try self.document.data($0) })
        } catch {
            return false
        }
        if pixels.rgba.count < width * height * 4 { return false }
        let low = options.bilevelTolerance
        let high = 255 - options.bilevelTolerance
        let rowBytes = (width + 7) / 8
        var bits = Array(repeating: UInt8(0), count: rowBytes * height)
        for y in 0..<height {
            for x in 0..<width {
                let at = (y * width + x) * 4
                let r = Int(pixels.rgba[at])
                let g = Int(pixels.rgba[at + 1])
                let b = Int(pixels.rgba[at + 2])
                if r >= high && g >= high && b >= high {
                    bits[y * rowBytes + x / 8] |= UInt8(0x80 >> (x % 8))
                } else if r > low || g > low || b > low {
                    return false
                }
            }
        }
        let packed = PdfFilterEncoders.flate(bits, .smallestSize)
        if packed.count >= document.rawData(stream).count { return false }
        dictionary["ColorSpace"] = PdfName("DeviceGray")
        dictionary["BitsPerComponent"] = PdfNumber(1)
        dictionary["Filter"] = PdfName("FlateDecode")
        dictionary.remove("DecodeParms")
        stream.data = packed
        return true
    }

    // The data with every filter undone; nil for an image codec, which the caller handles.
    private func samples(_ stream: PdfStream) -> [UInt8]? {
        let (filter, parameters, _) = document.decodeSpec(stream)
        do {
            let decoded = try PdfFilters.decodeToCodec(document.rawData(stream), filter, parameters)
            return decoded.codec == nil ? decoded.data : nil
        } catch {
            return nil
        }
    }

    private func tryShrink(_ stream: PdfStream, _ placement: Placement) -> Bool {
        let dictionary = stream.dictionary
        let width = size(dictionary, "Width")
        let height = size(dictionary, "Height")
        if width < 1 || height < 1 || width * height > PdfImageSamples.maxPixels { return false }
        if !exceeds(placement) { return false }
        let newWidth = scaled(width, placement.dpiX)
        let newHeight = scaled(height, placement.dpiY)
        if Double(newWidth * newHeight) > 0.9 * Double(width) * Double(height) { return false }
        if dictionary.containsKey("SMaskInData") || document.resolve(dictionary["Mask"]) != nil { return false }
        let soft = document.resolve(dictionary["SMask"]) as? PdfStream
        let maskWidth = size(soft?.dictionary, "Width")
        let maskHeight = size(soft?.dictionary, "Height")
        // A matte only fits a mask of the image's own size, which a failed mask shrink would break.
        if soft != nil && (hasMatte(dictionary) || maskWidth * maskHeight > PdfImageSamples.maxPixels) { return false }
        if !done.insert(ObjectIdentifier(stream)).inserted { return false }

        let replaced = shrink(stream, width, height, newWidth, newHeight)
        if replaced, let soft, maskWidth > 0, maskHeight > 0, done.insert(ObjectIdentifier(soft)).inserted {
            _ = shrink(soft, maskWidth, maskHeight, Swift.max(1, maskWidth * newWidth / width), Swift.max(1, maskHeight * newHeight / height))
        }
        return replaced
    }

    private func scaled(_ length: Int, _ dpi: Double) -> Int {
        let value = (Double(length) * Swift.min(1, Double(options.imageDpi) / dpi)).rounded(.toNearestOrEven)
        return Swift.max(1, value.isFinite && value < 9e18 ? Int(value) : length)
    }

    private func hasMatte(_ image: PdfDictionary) -> Bool {
        (document.resolve(image["SMask"]) as? PdfStream)?.dictionary.containsKey("Matte") == true
    }

    private func shrink(_ stream: PdfStream, _ width: Int, _ height: Int, _ newWidth: Int, _ newHeight: Int) -> Bool {
        let dictionary = stream.dictionary
        let (filter, parameters, _) = document.decodeSpec(stream)
        let decoded: PdfDecodedStream
        do {
            decoded = try PdfFilters.decodeToCodec(document.rawData(stream), filter, parameters)
        } catch {
            return false
        }
        var (family, components) = ImageKit.describe(document, dictionary["ColorSpace"])
        let bpc = document.integer(dictionary, "BitsPerComponent") ?? 8
        if decoded.codec == "DCTDecode" || decoded.codec == "JPXDecode" { return shrinkCoded(stream, decoded, family, components, newWidth, newHeight) }
        if decoded.codec != nil || bpc == 1 || !(bpc == 2 || bpc == 4 || bpc == 8 || bpc == 16) { return false }

        let pixels: [UInt8]
        if family == .indexed {
            let plain = dictionary.copy()
            plain.remove("SMask")
            do {
                pixels = Self.rgbOf(try PdfImageSamples.toRgba(plain, decoded.data, { self.document.resolve($0) }, { try self.document.data($0) }))
            } catch {
                return false
            }
            components = 3
        } else if components > 0 && family != .unknown && width * components <= Self.maxRowSamples && width * height * components <= Self.maxSamples {
            pixels = ImageKit.unpack(decoded.data, width, height, components, bpc)
        } else {
            return false
        }
        let smaller = PdfFilterEncoders.flate(ImageKit.shrink(pixels, width, height, components, newWidth, newHeight), .smallestSize)
        if smaller.count >= document.rawData(stream).count { return false }
        Self.store(stream, newWidth, newHeight, smaller, "FlateDecode")
        if family == .indexed {
            dictionary["ColorSpace"] = PdfName("DeviceRGB")
            dictionary.remove("Decode")
        }
        return true
    }

    private func shrinkCoded(_ stream: PdfStream, _ decoded: PdfDecodedStream, _ family: ImageFamily, _ components: Int, _ newWidth: Int, _ newHeight: Int) -> Bool {
        let dictionary = stream.dictionary
        let jpx = decoded.codec == "JPXDecode"
        if dictionary.containsKey("Decode") || (!jpx && !(family == .gray || family == .rgb)) { return false }
        if jpx && !(family == .gray || family == .rgb || family == .unknown) { return false }
        guard let codec, let name = decoded.codec else {
            needsCodec = true
            return false
        }
        guard let image = codec.decode(decoded.data, name), image.width >= 1, image.height >= 1, image.width <= image.rgba.count / 4 / image.height,
              image.width * image.height <= Self.maxPixels else { return false }
        let rgb = Self.rgbOf(image)
        let small = ImageKit.shrink(rgb, image.width, image.height, 3, newWidth, newHeight)
        var rgba = Array(repeating: UInt8(255), count: newWidth * newHeight * 4)
        for i in 0..<newWidth * newHeight {
            rgba[4 * i] = small[3 * i]
            rgba[4 * i + 1] = small[3 * i + 1]
            rgba[4 * i + 2] = small[3 * i + 2]
        }
        let jpeg = codec.encodeJpeg(PdfRgbaImage(newWidth, newHeight, rgba), Swift.min(Swift.max(options.jpegQuality, 1), 100))
        if jpeg.isEmpty || jpeg.count >= document.rawData(stream).count { return false }
        Self.store(stream, newWidth, newHeight, jpeg, "DCTDecode")
        if family != .rgb || components != 3 { dictionary["ColorSpace"] = PdfName("DeviceRGB") }
        return true
    }

    private static func rgbOf(_ image: PdfRgbaImage) -> [UInt8] {
        let count = Swift.min(image.width * image.height, image.rgba.count / 4)
        var rgb = Array(repeating: UInt8(0), count: image.width * image.height * 3)
        for i in 0..<count {
            rgb[3 * i] = image.rgba[4 * i]
            rgb[3 * i + 1] = image.rgba[4 * i + 1]
            rgb[3 * i + 2] = image.rgba[4 * i + 2]
        }
        return rgb
    }

    private static func store(_ stream: PdfStream, _ width: Int, _ height: Int, _ data: [UInt8], _ filter: String) {
        let dictionary = stream.dictionary
        dictionary["Width"] = PdfNumber(width)
        dictionary["Height"] = PdfNumber(height)
        dictionary["BitsPerComponent"] = PdfNumber(8)
        dictionary["Filter"] = PdfName(filter)
        dictionary.remove("DecodeParms")
        stream.data = data
    }
}
