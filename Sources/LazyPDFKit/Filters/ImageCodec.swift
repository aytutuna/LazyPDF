import Foundation

// Twin of windows/LazyPDF.Core/Filters/IImageCodec.cs: the image codecs Core leaves to the system (WIC on Windows,
// ImageIO on Apple).

public protocol ImageCodec: AnyObject {
    /// Pixels of a stream's data under `codec`: DCTDecode or JPXDecode. Nil when the system cannot read it. `components` is
    /// the component count of the image's PDF colour space, or 0 when there is none or it is not known; a codec that has to
    /// guess what the data holds takes its hint from it (ImageIO reads the data as it is and ignores it). The pixels are
    /// sRGB or RGBA whatever the PDF says (see `JpxImage` for what callers may use).
    func decode(_ data: [UInt8], _ codec: String, _ components: Int) -> PdfRgbaImage?

    /// Every frame of a picture file (JPEG, PNG, TIFF, BMP, GIF, HEIC), or nil for anything else. A frame carries the resolution the file stores, in dots per inch. A frame with too many pixels comes back as a placeholder with its size and no pixels (`tooBig`).
    func decodeFile(_ file: [UInt8]) -> [PdfRgbaImage]?

    /// A JPEG of `image`; `quality` runs from 1 to 100. Empty when the picture cannot be encoded.
    func encodeJpeg(_ image: PdfRgbaImage, _ quality: Int) -> [UInt8]
}
