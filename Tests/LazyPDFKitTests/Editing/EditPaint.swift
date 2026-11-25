import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Editing/EditPaint.cs: pages with pictures and paths, and what the interpreter
// paints from them.

struct ImageSeen: Equatable {
    let matrix: PdfMatrix
    let clip: PdfRect
    let alpha: Double
    let width: Int
    let height: Int
}

struct PathSeen {
    let path: PathInfo
    let fill: RgbColor
    let stroke: RgbColor
    let lineWidth: Double
    let alpha: Double
}

enum EditPaint {
    /// An 8 by 6 pixel colour JPEG.
    static let sampleJpeg =
        "/9j/4AAQSkZJRgABAQEAYABgAAD/2wBDAAMCAgMCAgMDAwMEAwMEBQgFBQQEBQoHBwYIDAoMDAsKCwsNDhIQDQ4RDgsLEBYQERMUFRUVDA8XGBYUGBIUFRT/2wBDAQMEBAUEBQkFBQkUDQsNFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBT/wAARCAAGAAgDASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwDI+Fv7K+jfueYe38J/wooor57Nc6zH6y/3zO/gHiHNf7Ep/wC0SP/Z"

    static func jpeg() throws -> [UInt8] {
        [UInt8](try XCTUnwrap(Data(base64Encoded: sampleJpeg)))
    }

    /// A page with two pictures: the JPEG at 100 by 50 in a q, a 2 by 2 gray one at 80 by 80 in another.
    static func pictures(_ extra: String = "") throws -> PdfEditSession {
        let picture = try jpeg()
        let file = EditKit.file("q 100 0 0 50 100 600 cm /Im1 Do Q\nq 80 0 0 80 300 600 cm /Im2 Do Q\n" + extra, more: { pdf in
            pdf.stream(7, "/Type /XObject /Subtype /Image /Width 8 /Height 6 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode", picture)
            pdf.stream(8, "/Type /XObject /Subtype /Image /Width 2 /Height 2 /ColorSpace /DeviceGray /BitsPerComponent 8", [0, 255, 255, 0])
        }, resources: "/Font <</F1 5 0 R>> /XObject <</Im1 7 0 R /Im2 8 0 R>>")
        return try PdfEditSession.open(file)
    }

    static func images(_ session: PdfEditSession) throws -> [ImageSeen] {
        let document = try PdfDocument.open(session.current)
        let probe = ImageProbe()
        ContentInterpreter(document).run(document.pages[0], probe)
        return probe.seen
    }

    private final class ImageProbe: ContentVisitor {
        var seen: [ImageSeen] = []

        override func paintImage(_ context: ContentContext, _ image: ImageInfo) {
            seen.append(ImageSeen(matrix: image.matrix, clip: context.state.clip, alpha: context.state.fillAlpha, width: image.width, height: image.height))
        }
    }

    static func paths(_ session: PdfEditSession) throws -> [PathSeen] {
        let document = try PdfDocument.open(session.current)
        let probe = PathProbe()
        ContentInterpreter(document).run(document.pages[0], probe)
        return probe.seen
    }

    private final class PathProbe: ContentVisitor {
        var seen: [PathSeen] = []

        override func paintPath(_ context: ContentContext, _ path: PathInfo) {
            let s = context.state
            if path.fill || path.stroke {
                seen.append(PathSeen(path: path, fill: s.fillColor.rgb, stroke: s.strokeColor.rgb, lineWidth: s.lineWidth, alpha: s.fillAlpha))
            }
        }
    }
}
