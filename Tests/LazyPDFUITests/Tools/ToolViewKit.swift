#if canImport(SwiftUI)
import CoreGraphics
import SwiftUI
import XCTest
import LazyPDFKit
import LazyPDFApp
@testable import LazyPDFUI

// What the tool view tests share: a tab with a viewer and a recording window, and the picture of a view at a fixed size.

@MainActor
struct ToolViewRig {
    let tab: DocumentTab
    let viewer: PanelViewer
    let host: RecordingHost

    init(_ bytes: [UInt8]? = nil) throws {
        tab = try PanelPdfs.tab(bytes ?? StandInPdfs.text(2))
        viewer = PanelViewer(tab)
        host = RecordingHost()
    }
}

@MainActor
enum ToolPicture {
    /// The view drawn at `width` by `height` on white, as the inspector would show it.
    static func draw<V: View>(_ view: V, width: Int = 280, height: Int = 420, file: StaticString = #filePath, line: UInt = #line) throws -> CGImage {
        let renderer = ImageRenderer(content: view.frame(width: CGFloat(width), height: CGFloat(height)).background(Color.white))
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.cgImage, file: file, line: line)
        XCTAssertEqual(image.width, width, file: file, line: line)
        XCTAssertEqual(image.height, height, file: file, line: line)
        return image
    }

    /// How many pixels are not white.
    static func ink(_ image: CGImage) throws -> Int {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = try XCTUnwrap(CGContext(data: &pixels, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return stride(from: 0, to: pixels.count, by: 4).filter { pixels[$0] != 255 || pixels[$0 + 1] != 255 || pixels[$0 + 2] != 255 }.count
    }
}
#endif
