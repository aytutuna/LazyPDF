#if canImport(SwiftUI)
import CoreGraphics
import SwiftUI
import UniformTypeIdentifiers
import LazyPDFApp
import LazyPDFKit

// What the side panels' views share: a file made of bytes for the save sheet, a picture from the engine's pixels, the line
// a panel shows in place of an empty list.

struct BytesDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data, .pdf, .plainText] }

    var bytes: [UInt8] = []

    init(bytes: [UInt8] = []) {
        self.bytes = bytes
    }

    init(configuration: ReadConfiguration) throws {
        bytes = [UInt8](configuration.file.regularFileContents ?? Data())
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(bytes))
    }
}

enum PanelImage {
    /// The page picture the engine drew (straight RGBA, opaque for a page) as an image; nil for an empty one.
    static func make(_ image: PdfRgbaImage) -> CGImage? {
        guard image.width > 0, image.height > 0, image.rgba.count >= image.width * image.height * 4,
              let provider = CGDataProvider(data: Data(image.rgba) as CFData) else { return nil }
        return CGImage(width: image.width, height: image.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: image.width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

struct PanelNote: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .accessibilityAddTraits(.updatesFrequently)
    }
}
#endif
