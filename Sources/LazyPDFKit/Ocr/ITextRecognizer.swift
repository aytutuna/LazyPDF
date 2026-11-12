import Foundation

// Twin of windows/LazyPDF.Core/Ocr/ITextRecognizer.cs: a box and a word in the pixels of the image that was read, and
// text recognition over a picture of a page. Vision is behind it on Apple; an app passes an implementation in.

/// A box in the pixels of the image that was read: origin top-left, y down.
public struct OcrBox: Equatable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(_ x: Double, _ y: Double, _ width: Double, _ height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var right: Double { x + width }
    public var bottom: Double { y + height }
}

/// One recognized word and where it sits in the image. `confidence` is 0 to 1; 1 when the engine does not say.
/// `angle` is how far the line the word is on is turned, in radians, counter-clockwise as seen; `box` is then the
/// word's box in the line's own upright frame, its bottom-left corner on the baseline where the word starts. 0 for a
/// straight line.
public struct OcrWord {
    public let text: String
    public let box: OcrBox
    public let confidence: Float
    public let angle: Double

    public init(_ text: String, _ box: OcrBox, _ confidence: Float = 1, _ angle: Double = 0) {
        self.text = text
        self.box = box
        self.confidence = confidence
        self.angle = angle
    }
}

public protocol TextRecognizer {
    /// The words found, boxes in the pixels of `image`; empty when there is no text. `language` is a BCP 47 tag such
    /// as "en-US" or "tr". A cancelled task ends the call with `CancellationError`.
    func recognizeAsync(_ image: PdfRgbaImage, _ language: String) async throws -> [OcrWord]
}
