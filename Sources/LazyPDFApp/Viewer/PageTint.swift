import Foundation
import LazyPDFKit

// Port of windows/LazyPDF.App/Viewer/PageTint.cs, without the WPF bitmap: a tinted tile is `TileBitmap`, bytes the
// surface turns into whatever its platform draws.

/// How the pages are coloured on screen. The file is never touched: the tint is applied to the pixels of a tile as it is made.
public enum PageTint: Hashable {
    case none
    case dark
    case sepia
}

public struct PaperColor: Equatable {
    public let red: UInt8
    public let green: UInt8
    public let blue: UInt8
}

/// A tile's pixels as B, G, R, 255 for each pixel, rows top to bottom.
public struct TileBitmap: PixelSized {
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let bgra: [UInt8]

    public init(_ image: PdfRgbaImage, _ tint: PageTint) {
        pixelWidth = image.width
        pixelHeight = image.height
        bgra = PageTints.toBgra(image.rgba, tint)
    }
}

public enum PageTints {
    /// The paper before its tiles arrive.
    public static func paper(_ tint: PageTint) -> PaperColor {
        switch tint {
        case .dark: return PaperColor(red: 0x1C, green: 0x1C, blue: 0x1C)
        case .sepia: return PaperColor(red: 0xF4, green: 0xEC, blue: 0xD8)
        case .none: return PaperColor(red: 255, green: 255, blue: 255)
        }
    }

    /// B, G, R, 255 for each R, G, B, A of `rgba`.
    public static func toBgra(_ rgba: [UInt8], _ tint: PageTint) -> [UInt8] {
        var bgra = [UInt8](repeating: 0, count: rgba.count)
        switch tint {
        case .dark: dark(rgba, &bgra)
        case .sepia: sepia(rgba, &bgra)
        case .none:
            for i in stride(from: 0, to: rgba.count, by: 4) {
                bgra[i] = rgba[i + 2]
                bgra[i + 1] = rgba[i + 1]
                bgra[i + 2] = rgba[i]
                bgra[i + 3] = 255
            }
        }
        return bgra
    }

    // Invert, then turn the hue half way round so colours keep their look: white becomes near black, black near white.
    // The matrix is the hue rotation by 180 degrees, in 1/1024 steps; the result is held between two greys.
    private static func dark(_ rgba: [UInt8], _ bgra: inout [UInt8]) {
        let low = 26, high = 232
        for i in stride(from: 0, to: rgba.count, by: 4) {
            let r = Int(rgba[i]), g = Int(rgba[i + 1]), b = Int(rgba[i + 2])
            let nr = (-588 * r + 1464 * g + 147 * b) >> 10
            let ng = (436 * r + 440 * g + 147 * b) >> 10
            let nb = (436 * r + 1464 * g - 876 * b) >> 10
            bgra[i] = scale(255 - nb, low, high)
            bgra[i + 1] = scale(255 - ng, low, high)
            bgra[i + 2] = scale(255 - nr, low, high)
            bgra[i + 3] = 255
        }
    }

    private static func scale(_ v: Int, _ low: Int, _ high: Int) -> UInt8 {
        UInt8(low + (Swift.min(Swift.max(v, 0), 255) * (high - low) + 127) / 255)
    }

    // White paper becomes the paper colour and everything else is darkened in proportion.
    private static func sepia(_ rgba: [UInt8], _ bgra: inout [UInt8]) {
        for i in stride(from: 0, to: rgba.count, by: 4) {
            bgra[i] = UInt8(Int(rgba[i + 2]) * 216 / 255)
            bgra[i + 1] = UInt8(Int(rgba[i + 1]) * 236 / 255)
            bgra[i + 2] = UInt8(Int(rgba[i]) * 244 / 255)
            bgra[i + 3] = 255
        }
    }
}
