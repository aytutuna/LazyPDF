#if canImport(Vision)
import CoreGraphics
import Foundation
import LazyPDFKit
import Vision

// Follows windows/LazyPDF.App/Services/WindowsOcr.cs: text recognition on Vision's accurate level, with the languages
// the system has. Vision takes a picture of any size, so there is no shrinking and scaling back as on Windows.

public struct VisionTextRecognizer: TextRecognizer {
    public init() {}

    /// True when Vision can recognize `language` (a BCP 47 tag; "tr" matches "tr-TR").
    public static func isAvailable(_ language: String) -> Bool {
        supportedTag(language) != nil
    }

    private static func supportedTag(_ language: String) -> String? {
        guard let supported = try? VNRecognizeTextRequest().supportedRecognitionLanguages() else { return nil }
        let wanted = language.lowercased()
        if let exact = supported.first(where: { $0.lowercased() == wanted }) { return exact }
        let primary = wanted.split(separator: "-").first.map(String.init) ?? wanted
        guard !primary.isEmpty else { return nil }
        return supported.first { $0.lowercased().split(separator: "-").first.map(String.init) == primary }
    }

    // English comes second so Latin-script names and numbers inside another language's page are still read.
    static func recognitionLanguages(for tag: String) -> [String] {
        guard !tag.lowercased().hasPrefix("en"), let english = supportedTag("en-US") else { return [tag] }
        return [tag, english]
    }

    public func recognizeAsync(_ image: PdfRgbaImage, _ language: String) async throws -> [OcrWord] {
        guard let tag = Self.supportedTag(language) else {
            throw InvalidOperationException(L10n.t("This device cannot read {0} text.", language))
        }
        try Task.checkCancellation()
        guard let picture = Self.picture(image) else { return [] }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = Self.recognitionLanguages(for: tag)
        request.usesLanguageCorrection = true
        let width = Double(image.width), height = Double(image.height)

        do {
            let words: [OcrWord] = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    DispatchQueue.global(qos: .userInitiated).async {
                        do {
                            try VNImageRequestHandler(cgImage: picture, options: [:]).perform([request])
                            continuation.resume(returning: Self.words(request.results ?? [], width, height))
                        } catch {
                            continuation.resume(throwing: error)
                        }
                    }
                }
            } onCancel: {
                request.cancel()
            }
            try Task.checkCancellation()
            return words
        } catch {
            // A cancelled request fails with Vision's own error; the caller is promised CancellationError.
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }

    // Vision's boxes are fractions of the picture with the origin at the bottom left.
    private static func words(_ lines: [VNRecognizedTextObservation], _ width: Double, _ height: Double) -> [OcrWord] {
        var words: [OcrWord] = []
        for line in lines {
            guard let candidate = line.topCandidates(1).first else { continue }
            let text = candidate.string
            var start: String.Index?
            func flush(_ end: String.Index) {
                guard let first = start else { return }
                start = nil
                guard let corners = try? candidate.boundingBox(for: first..<end) else { return }
                let (box, angle) = Self.placement(corners.bottomLeft, corners.bottomRight, corners.topLeft, corners.boundingBox, width, height)
                words.append(OcrWord(String(text[first..<end]), box, candidate.confidence, angle))
            }
            for index in text.indices {
                if text[index].isWhitespace { flush(index) } else if start == nil { start = index }
            }
            flush(text.endIndex)
        }
        return words
    }

    // A word turned by more than this (about 0.3 degrees) gets an angle and its upright box at the baseline start; Vision's
    // corners are never exactly square, and a straight page keeps its axis-aligned boxes.
    private static let minAngle = 0.005

    // The corners are fractions of the picture with y up. The angle is counter-clockwise as seen, which is atan2 with y up.
    static func placement(_ bottomLeft: CGPoint, _ bottomRight: CGPoint, _ topLeft: CGPoint, _ bounds: CGRect,
                          _ width: Double, _ height: Double) -> (OcrBox, Double) {
        let along = (x: (bottomRight.x - bottomLeft.x) * width, y: (bottomRight.y - bottomLeft.y) * height)
        let angle = atan2(along.y, along.x)
        guard angle.isFinite, abs(angle) >= minAngle else {
            return (OcrBox(bounds.minX * width, (1 - bounds.maxY) * height, bounds.width * width, bounds.height * height), 0)
        }
        let wide = hypot(along.x, along.y)
        let high = hypot((topLeft.x - bottomLeft.x) * width, (topLeft.y - bottomLeft.y) * height)
        let bottom = (1 - bottomLeft.y) * height
        return (OcrBox(bottomLeft.x * width, bottom - high, wide, high), angle)
    }

    // The alpha is ignored, as on Windows.
    private static func picture(_ image: PdfRgbaImage) -> CGImage? {
        guard image.width > 0, image.height > 0, image.rgba.count >= image.width * image.height * 4,
              let provider = CGDataProvider(data: Data(image.rgba) as CFData) else { return nil }
        return CGImage(width: image.width, height: image.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: image.width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider, decode: nil,
                       shouldInterpolate: false, intent: .defaultIntent)
    }
}
#endif
