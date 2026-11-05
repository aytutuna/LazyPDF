import Foundation

// Twin of windows/LazyPDF.Core/Content/ContentImages.cs: image XObjects made from pixels or a JPEG file, ready to
// paint with `ContentWriter.paint(_:_:)`.

public enum ContentImages {
    /// An RGB image, Flate-compressed, with an /SMask when any pixel is not opaque. `rgba` is straight RGBA8, top row
    /// first, as `PdfRgbaImage` has it. Pixel data that does not fit the size throws, where the C# raises
    /// ArgumentException: a codec can decode a frame past `PdfImageSamples.maxPixels`.
    public static func addRgba(_ document: PdfDocument, _ width: Int, _ height: Int, _ rgba: [UInt8]) throws -> PdfReference {
        guard width >= 1, height >= 1, width <= PdfImageSamples.maxPixels / height, rgba.count == width * height * 4 else {
            throw PdfReadException.damaged("The pixel data does not fit the size.")
        }
        var rgb = [UInt8](repeating: 0, count: width * height * 3)
        var alpha = [UInt8](repeating: 0, count: width * height)
        var translucent = false
        var o = 0
        for i in 0..<alpha.count {
            rgb[o] = rgba[4 * i]
            rgb[o + 1] = rgba[4 * i + 1]
            rgb[o + 2] = rgba[4 * i + 2]
            o += 3
            alpha[i] = rgba[4 * i + 3]
            translucent = translucent || alpha[i] != 255
        }
        let image = makeImage(width, height, "DeviceRGB", 8)
        if translucent {
            let mask = makeImage(width, height, "DeviceGray", 8)
            mask.data = PdfFilterEncoders.flate(alpha)
            image.dictionary["SMask"] = try document.add(mask)
        }
        image.data = PdfFilterEncoders.flate(rgb)
        return try document.add(image)
    }

    /// A JPEG file embedded as it is (DCTDecode); nil when its header cannot be read.
    public static func addJpeg(_ document: PdfDocument, _ jpeg: [UInt8]) throws -> PdfReference? {
        guard let header = readJpegHeader(jpeg) else { return nil }
        let space: String
        switch header.components {
        case 1: space = "DeviceGray"
        case 3: space = "DeviceRGB"
        default: space = "DeviceCMYK"
        }
        let image = makeImage(header.width, header.height, space, 8)
        image.dictionary["Filter"] = PdfName("DCTDecode")
        // Adobe writes CMYK JPEGs inverted.
        if header.components == 4 && header.adobe {
            let ones: [Int] = (0..<8).map { $0 % 2 == 0 ? 1 : 0 }
            image.dictionary["Decode"] = PdfArray(ones.map { PdfNumber($0) })
        }
        image.data = jpeg
        return try document.add(image)
    }

    private static func makeImage(_ width: Int, _ height: Int, _ space: String, _ bits: Int) -> PdfStream {
        let dictionary = PdfDictionary()
        dictionary["Type"] = PdfName("XObject")
        dictionary["Subtype"] = PdfName("Image")
        dictionary["Width"] = PdfNumber(width)
        dictionary["Height"] = PdfNumber(height)
        dictionary["ColorSpace"] = PdfName(space)
        dictionary["BitsPerComponent"] = PdfNumber(bits)
        dictionary["Filter"] = PdfName("FlateDecode")
        return PdfStream(dictionary, data: [])
    }

    private static func readJpegHeader(_ d: [UInt8]) -> (width: Int, height: Int, components: Int, adobe: Bool)? {
        var adobe = false
        if d.count < 4 || d[0] != 0xFF || d[1] != 0xD8 { return nil }
        var p = 2
        while p + 4 <= d.count {
            if d[p] != 0xFF {
                p += 1
                continue
            }
            let marker = Int(d[p + 1])
            if marker == 0xFF || marker == 0x00 || (marker >= 0xD0 && marker <= 0xD8) || marker == 0x01 {
                p += marker == 0xFF ? 1 : 2
                continue
            }
            let length = Int(d[p + 2]) << 8 | Int(d[p + 3])
            if marker == 0xEE && length >= 7 && p + 9 <= d.count && d[p + 4] == 0x41 && d[p + 5] == 0x64 { adobe = true }
            if marker >= 0xC0 && marker <= 0xCF && marker != 0xC4 && marker != 0xC8 && marker != 0xCC {
                if p + 10 > d.count { return nil }
                let height = Int(d[p + 5]) << 8 | Int(d[p + 6])
                let width = Int(d[p + 7]) << 8 | Int(d[p + 8])
                let components = Int(d[p + 9])
                return width > 0 && height > 0 && (components == 1 || components == 3 || components == 4) ? (width, height, components, adobe) : nil
            }
            p += 2 + length
        }
        return nil
    }
}
