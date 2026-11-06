import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Optimize/OptimizeKit.cs: the same helpers. PigText and PigPages open a file in
// PdfPig and have no twin; the tests that call them keep their other assertions. Noise is a small generator of its own
// where the C# uses System.Random, as the tests need data that does not deflate, not a particular sequence.

enum OptimizeKit {
    static let tinyJpeg: [UInt8] = {
        let text = "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAMCAgMCAgMDAwMEAwMEBQgFBQQEBQoHBwYIDAoMDAsKCwsNDhIQDQ4RDgsLEBYQ" +
            "ERMUFRUVDA8XGBYUGBIUFRT/2wBDAQMEBAUEBQkFBQkUDQsNFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQU" +
            "FBQUFBQUFBQUFBQUFBT/wAARCAAQABADASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAA" +
            "AgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6" +
            "Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXG" +
            "x8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREA" +
            "AgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5" +
            "OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPE" +
            "xcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwD5V8KfCn7n7n9K9m8J/Cn7n7n9K9i8J/Cn" +
            "7n7n9K9m8KfCn7n7n9K6854w394nw249+D3+x//Z"
        return [UInt8](Data(base64Encoded: text) ?? Data())
    }()

    /// The options with every step off, so that a test turns on the one it is about.
    static let off = OptimizeOptions(objectStreams: false, recompressStreams: false, convertOldFilters: false, removeDuplicates: false,
                                     stripThumbnails: false, stripPieceInfo: false, pruneResources: false)

    /// A one-page file (200 by 200); the content is object 4 and `more` adds objects from 5 on. With `shared` the resources are object 12.
    static func build(_ content: String, _ resources: String = "", _ more: ((TestPdf) -> Void)? = nil, pageExtra: String = "", catalogExtra: String = "",
                      contents: String = "4 0 R", shared: Bool = false) -> [UInt8] {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R \(catalogExtra)>>")
        pdf.obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 200 200]>>")
        pdf.obj(3, "<</Type /Page /Parent 2 0 R /Contents \(contents) /Resources \(shared ? "12 0 R" : "<<\(resources)>>") \(pageExtra)>>")
        if shared { pdf.obj(12, "<<\(resources)>>") }
        pdf.stream(4, "", content)
        more?(pdf)
        return pdf.finish()
    }

    /// The text of every page as the engine reads it.
    static func engineText(_ file: [UInt8]) throws -> String {
        let document = try PdfDocument.open(file)
        let cache = TextCache(document)
        return (0..<document.pages.count).map { cache.get($0).text }.joined(separator: "\u{0C}")
    }

    /// Whether the marker is in the bytes of the file, or in the data of any stream once decoded.
    static func everywhere(_ file: [UInt8], _ marker: String) throws -> Bool {
        let needle = Latin1.bytes(marker)
        let wide = marker.utf16.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] }
        if indexOf(file, needle) >= 0 || indexOf(file, wide) >= 0 { return true }
        let document = try PdfDocument.open(file)
        for number in document.objectNumbers {
            guard let stream = document.get(number) as? PdfStream else { continue }
            guard let data = try? document.data(stream) else { continue }
            if indexOf(data, needle) >= 0 || indexOf(data, wide) >= 0 { return true }
        }
        return false
    }

    static func indexOf(_ data: [UInt8], _ needle: [UInt8]) -> Int {
        if needle.isEmpty { return 0 }
        if data.count < needle.count { return -1 }
        for i in 0...(data.count - needle.count) where data[i] == needle[0] && Array(data[i..<i + needle.count]) == needle { return i }
        return -1
    }

    static func image(_ document: PdfDocument, _ name: String = "Im0", file: StaticString = #filePath, line: UInt = #line) throws -> PdfStream {
        let page = document.pages[0]
        let xobjects = try XCTUnwrap(document.dict(page.resources, "XObject"), file: file, line: line)
        return try XCTUnwrap(document.resolve(xobjects[name]) as? PdfStream, file: file, line: line)
    }

    static func count(_ document: PdfDocument, _ match: (PdfObject) -> Bool) -> Int {
        document.objectNumbers.filter { n in document.get(n).map(match) ?? false }.count
    }

    static func isImage(_ document: PdfDocument, _ o: PdfObject) -> Bool {
        guard let s = o as? PdfStream else { return false }
        return document.name(s.dictionary, "Subtype") == "Image"
    }

    /// Samples of a stream with its filters undone.
    static func decoded(_ document: PdfDocument, _ stream: PdfStream) throws -> [UInt8] { try document.data(stream) }

    static func noise(_ length: Int, _ seed: Int = 1) -> [UInt8] {
        var state = UInt64(truncatingIfNeeded: seed) &* 6364136223846793005 &+ 1442695040888963407
        var data = Array(repeating: UInt8(0), count: length)
        for i in 0..<length {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            data[i] = UInt8(truncatingIfNeeded: state >> 33)
        }
        return data
    }

    /// RGB samples with a smooth gradient, so that they deflate well but are not flat.
    static func gradient(_ width: Int, _ height: Int, _ components: Int) -> [UInt8] {
        var data = Array(repeating: UInt8(0), count: width * height * components)
        for y in 0..<height {
            for x in 0..<width {
                for c in 0..<components {
                    let across = x * 255 / max(1, width - 1)
                    let down = y * c * 40 / max(1, height)
                    data[(y * width + x) * components + c] = UInt8((across + down) & 0xFF)
                }
            }
        }
        return data
    }
}

/// Stands for the system codecs: reads the size from a JPEG header and answers with a gradient.
final class OptimizeFakeCodec: ImageCodec {
    private(set) var decodes = 0
    private(set) var lastQuality = 0
    private(set) var lastEncoded: PdfRgbaImage?

    func decode(_ data: [UInt8], _ codec: String) -> PdfRgbaImage? {
        decodes += 1
        let at = OptimizeKit.indexOf(data, [0xFF, 0xC0])
        if at < 0 || at + 8 >= data.count { return nil }
        let height = Int(data[at + 5]) << 8 | Int(data[at + 6])
        let width = Int(data[at + 7]) << 8 | Int(data[at + 8])
        var rgba = Array(repeating: UInt8(0), count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let o = (y * width + x) * 4
                rgba[o] = UInt8(x * 255 / max(1, width - 1))
                rgba[o + 1] = UInt8(y * 255 / max(1, height - 1))
                rgba[o + 2] = 128
                rgba[o + 3] = 255
            }
        }
        return PdfRgbaImage(width, height, rgba)
    }

    func decodeFile(_ file: [UInt8]) -> [PdfRgbaImage]? { nil }

    func encodeJpeg(_ image: PdfRgbaImage, _ quality: Int) -> [UInt8] {
        lastQuality = quality
        lastEncoded = image
        var data = Array(repeating: UInt8(0), count: 24 + image.width * image.height * quality / 100)
        data[0] = 0xFF
        data[1] = 0xD8
        data[data.count - 2] = 0xFF
        data[data.count - 1] = 0xD9
        return data
    }
}

extension OptimizeOptions {
    /// The record `with` expression.
    func with(_ edit: (inout OptimizeOptions) -> Void) -> OptimizeOptions {
        var copy = self
        edit(&copy)
        return copy
    }
}

extension SanitizeOptions {
    func with(_ edit: (inout SanitizeOptions) -> Void) -> SanitizeOptions {
        var copy = self
        edit(&copy)
        return copy
    }
}
