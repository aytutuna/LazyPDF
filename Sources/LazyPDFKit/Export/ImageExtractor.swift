import Foundation

// Twin of windows/LazyPDF.Core/Export/ImageExtractor.cs: an image a page paints, as a file: JPEG as its own bytes,
// anything else as PNG.

/// `pageIndex` is from 0. `name` is the resource name on the page ("Im1"), or "inline1" for an inline image.
public struct ExportedImage {
    public let pageIndex: Int
    public let name: String
    public let image: ExportImage

    public init(_ pageIndex: Int, _ name: String, _ image: ExportImage) {
        self.pageIndex = pageIndex
        self.name = name
        self.image = image
    }

    /// "page3_Im1.jpg". Characters a file name cannot hold, a path separator among them, become underscores.
    public var fileName: String { "page\(pageIndex + 1)_\(Self.clean(name)).\(image.extension)" }

    static func clean(_ name: String) -> String {
        var out = String.UnicodeScalarView()
        for c in name.unicodeScalars { out.append(c.value < 0x20 || "\\/:*?\"<>|".unicodeScalars.contains(c) ? "_" : c) }
        return String(out)
    }
}

public enum ImageExtractor {
    /// Every image the pages paint, forms included, in painting order; one the page paints twice is listed once. JPEG
    /// data is kept as stored, other images go to PNG with an /SMask as alpha. Without a `codec` the JPEG 2000 and JBIG2
    /// images, and JPEGs that need a mask, /Decode or a colour space applied, are not decoded: the first is left out, the
    /// second kept as plain JPEG. A mask stored with a codec is read through the codec; without one the picture comes out
    /// opaque. Throws `ArgumentException` when a page index is out of range.
    public static func extract(_ document: PdfDocument, _ pages: [Int]? = nil, _ codec: ImageCodec? = nil) throws -> [ExportedImage] {
        let images = ExportImages(document, codec)
        let interpreter = ContentInterpreter(document)
        interpreter.walkPatterns = false
        var found: [ExportedImage] = []
        let count = document.pages.count
        for index in pages ?? Array(0..<count) {
            try Task.checkCancellation()
            if index < 0 || index >= count { throw ArgumentException("pages") }
            let scan = ExportScan(PageGeometry(document.pages[index]), false)
            interpreter.run(document.pages[index], scan)
            var seen = Set<ObjectIdentifier>()
            var names = Set<String>()
            var inline = 0
            for info in scan.images {
                if let stream = info.stream, !seen.insert(ObjectIdentifier(stream)).inserted { continue }
                guard let image = try images.get(info) else { continue }
                let name: String
                if let known = info.name {
                    name = known
                } else {
                    inline += 1
                    name = "inline\(inline)"
                }
                var unique = name
                var n = 2
                while !names.insert(ExportedImage.clean(unique)).inserted {
                    unique = "\(name)_\(n)"
                    n += 1
                }
                found.append(ExportedImage(index, unique, image))
            }
        }
        return found
    }
}
