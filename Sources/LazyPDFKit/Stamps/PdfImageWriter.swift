import Foundation

// Twin of windows/LazyPDF.Core/Stamps/PdfImageWriter.cs: adds images to a document for stamps, signatures and pictures placed
// on a page. JPEG bytes go in as they are (DCTDecode), pixels are deflated with an /SMask when any of them is not opaque.

/// An image XObject in a document with its size in pixels.
public struct PdfImage {
    public let reference: PdfReference
    public let width: Int
    public let height: Int

    public init(_ reference: PdfReference, _ width: Int, _ height: Int) {
        self.reference = reference
        self.width = width
        self.height = height
    }
}

public enum PdfImageWriter {
    /// The JPEG embedded as it is; nil when its header cannot be read or it has an unusual number of components.
    public static func addJpeg(_ document: PdfDocument, _ jpeg: [UInt8]) throws -> PdfImage? {
        guard let header = tryReadJpegHeader(jpeg), header.components == 1 || header.components == 3 || header.components == 4 else { return nil }
        guard let reference = try ContentImages.addJpeg(document, jpeg) else { return nil }
        return PdfImage(reference, header.width, header.height)
    }

    /// A picture file as an upright image: a JPEG without an Exif turn as it is, a turned JPEG decoded and stored turned back
    /// (as a quality 92 JPEG when the codec encodes one, else as pixels), any other file as the codec reads it. Nil when nothing reads it or its pixels do not fit.
    public static func addPicture(_ document: PdfDocument, _ file: [UInt8], _ codec: ImageCodec?) throws -> PdfImage? {
        let jpeg = file.count > 2 && file[0] == 0xFF && file[1] == 0xD8
        let orientation = jpeg ? JpegMeta.orientation(file) : 1
        if jpeg && (orientation == 1 || codec == nil), let direct = try addJpeg(document, file) { return direct }
        guard let frame = codec?.decodeFile(file)?.first, ObjectEditor.fits(frame) else { return nil }
        let upright = JpegMeta.upright(frame, orientation)
        // A turned photo goes back in as a JPEG, not as raw pixels many times its size; a codec that cannot encode gives none.
        if orientation > 1, let codec {
            let turned = codec.encodeJpeg(upright, 92)
            if !turned.isEmpty, let encoded = try addJpeg(document, turned) { return encoded }
        }
        return try addRgba(document, upright.width, upright.height, upright.rgba)
    }

    /// The first frame of a picture file that is not too big, turned upright by its Exif turn; the Windows app turns the file itself.
    public static func decodeUpright(_ file: [UInt8], _ codec: ImageCodec) -> PdfRgbaImage? {
        guard let frame = codec.decodeFile(file)?.first(where: { !$0.tooBig }) else { return nil }
        return JpegMeta.upright(frame, JpegMeta.orientation(file))
    }

    /// `rgba` is straight RGBA8, top row first. A size that is not positive or does not fit the data is the caller's
    /// mistake, a precondition where the C# throws ArgumentException; a picture with too many pixels is the user's choice
    /// and throws `InvalidOperationException`.
    public static func addRgba(_ document: PdfDocument, _ width: Int, _ height: Int, _ rgba: [UInt8]) throws -> PdfImage {
        if width >= 1 && height >= 1 && width > PdfImageSamples.maxPixels / height {
            throw InvalidOperationException(StampsText.pictureTooLarge)
        }
        return PdfImage(try ContentImages.addRgba(document, width, height, rgba), width, height)
    }

    // From Lazy Scan's PdfBuilder.cs: the frame size and component count of a JPEG from its start-of-frame segment,
    // walking the markers by their lengths.
    static func tryReadJpegHeader(_ jpeg: [UInt8]) -> (width: Int, height: Int, components: Int)? {
        if jpeg.count < 4 || jpeg[0] != 0xFF || jpeg[1] != 0xD8 { return nil }
        var pos = 2
        while pos < jpeg.count {
            if jpeg[pos] != 0xFF { return nil }
            // Any number of 0xFF fill bytes may precede a marker code.
            while pos < jpeg.count && jpeg[pos] == 0xFF { pos += 1 }
            if pos >= jpeg.count { return nil }
            let marker = jpeg[pos]
            pos += 1

            // Standalone markers carry no length: TEM, RSTn, SOI.
            if marker == 0x01 || (marker >= 0xD0 && marker <= 0xD8) { continue }
            // Scan data or the end of the image before any frame header: no size to be had.
            if marker == 0xDA || marker == 0xD9 || marker == 0x00 { return nil }

            if pos + 2 > jpeg.count { return nil }
            let length = Int(jpeg[pos]) << 8 | Int(jpeg[pos + 1])
            if length < 2 || pos + length > jpeg.count { return nil }

            // SOF0...SOF15, except DHT (C4), JPG (C8) and DAC (CC), which share the range.
            let isFrame = marker >= 0xC0 && marker <= 0xCF && marker != 0xC4 && marker != 0xC8 && marker != 0xCC
            if isFrame {
                // Length(2) precision(1) height(2) width(2) components(1) ...
                if length < 8 { return nil }
                let height = Int(jpeg[pos + 3]) << 8 | Int(jpeg[pos + 4])
                let width = Int(jpeg[pos + 5]) << 8 | Int(jpeg[pos + 6])
                let components = Int(jpeg[pos + 7])
                // Height 0 means "defined later by DNL"; treat it as unknown.
                return width > 0 && height > 0 && components > 0 ? (width, height, components) : nil
            }
            pos += length
        }
        return nil
    }
}
