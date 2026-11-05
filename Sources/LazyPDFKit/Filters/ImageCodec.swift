import Foundation

// Twin of windows/LazyPDF.Core/Filters/IImageCodec.cs: the image codecs Core leaves to the system (WIC on Windows,
// ImageIO on Apple).

public protocol ImageCodec: AnyObject {
    /// Pixels of a stream's data under `codec`: DCTDecode, JPXDecode or JBIG2Decode. Nil when the system cannot read it.
    func decode(_ data: [UInt8], _ codec: String) -> PdfRgbaImage?

    /// Every frame of a picture file (JPEG, PNG, TIFF, BMP, GIF, HEIC), or nil for anything else.
    func decodeFile(_ file: [UInt8]) -> [PdfRgbaImage]?

    /// A JPEG of `image`; `quality` runs from 1 to 100.
    func encodeJpeg(_ image: PdfRgbaImage, _ quality: Int) -> [UInt8]
}
