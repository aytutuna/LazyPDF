import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Export/ExportKit.cs: the helpers of the export tests. The C# source reads Arial from
// the Windows fonts folder; here it hands out the synthetic font of the font program tests, which has A, B, space, ğ, İ and À (ı
// has the glyph of ğ and reads back as ğ), so the texts use those letters where the C# uses Turkish prose. `XDocument.Parse` is the XML reader of the
// Structure layer, and ZipArchive is `ExportZipReader`, a reader for the packages the writers make.

final class ExportArialSource: FontSource {
    private let data: [UInt8]

    init() throws {
        data = try SyntheticFonts.ttf()
    }

    func find(_ family: String, _ style: FontStyles) -> FontFile? { FontFile(data) }
}

/// Reads PNG and JPEG-less pictures back as a fake system codec would: only what the tests feed it.
final class ExportFakeCodec: ImageCodec {
    var decoded: [String] = []

    func decode(_ data: [UInt8], _ codec: String) -> PdfRgbaImage? {
        decoded.append(codec)
        return PdfRgbaImage(2, 2, [255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 255, 255])
    }

    // A "picture file" of the tests is the bytes P, width, height, then width * height gray levels.
    func decodeFile(_ file: [UInt8]) -> [PdfRgbaImage]? {
        if file.count < 3 || file[0] != UInt8(ascii: "P") { return nil }
        let w = Int(file[1]), h = Int(file[2])
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        for i in 0..<(w * h) {
            let g = 3 + i < file.count ? file[3 + i] : 0
            rgba[4 * i] = g
            rgba[4 * i + 1] = g
            rgba[4 * i + 2] = g
            rgba[4 * i + 3] = 255
        }
        return [PdfRgbaImage(w, h, rgba)]
    }

    func encodeJpeg(_ image: PdfRgbaImage, _ quality: Int) -> [UInt8] {
        [0xFF, 0xD8, UInt8(truncatingIfNeeded: quality), image.rgba[3] == 255 ? 1 : 0, 0xFF, 0xD9]
    }

    static func picture(_ w: Int, _ h: Int, _ gray: UInt8 = 128) -> [UInt8] {
        [UInt8(ascii: "P"), UInt8(truncatingIfNeeded: w), UInt8(truncatingIfNeeded: h)] + [UInt8](repeating: gray, count: w * h)
    }
}

final class ExportFakeRenderer: PageRenderer {
    private let width: Int
    private let height: Int
    private let alpha: UInt8

    init(_ width: Int, _ height: Int, alpha: UInt8 = 255) {
        self.width = width
        self.height = height
        self.alpha = alpha
    }

    func render(_ pageIndex: Int, _ dpi: Double) -> PdfRgbaImage? {
        if pageIndex < 0 || pageIndex > 1 { return nil }
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let o = (y * width + x) * 4
                rgba[o] = UInt8(truncatingIfNeeded: x * 255 / max(1, width - 1))
                rgba[o + 1] = UInt8(truncatingIfNeeded: y * 255 / max(1, height - 1))
                rgba[o + 2] = UInt8(truncatingIfNeeded: pageIndex)
                rgba[o + 3] = alpha
            }
        }
        return PdfRgbaImage(width, height, rgba)
    }
}

struct ExportZipFile {
    let name: String
    let method: Int
    let compressedSize: Int
    let crc: UInt32
    let dosDate: Int
    let flags: Int
    let data: [UInt8]
}

enum ExportZipReader {
    private static func u16(_ b: [UInt8], _ at: Int) -> Int { Int(b[at]) | Int(b[at + 1]) << 8 }
    private static func u32(_ b: [UInt8], _ at: Int) -> Int { u16(b, at) | u16(b, at + 2) << 16 }

    /// The entries of a zip in the order of its central directory, their data inflated; the sizes and the CRC are checked.
    static func read(_ package: [UInt8]) throws -> [ExportZipFile] {
        var end = package.count - 22
        while end >= 0 && u32(package, end) != 0x06054B50 { end -= 1 }
        guard end >= 0 else { throw PdfReadException.damaged("no end of central directory") }
        let count = u16(package, end + 10)
        var at = u32(package, end + 16)
        var files: [ExportZipFile] = []
        for _ in 0..<count {
            guard u32(package, at) == 0x02014B50 else { throw PdfReadException.damaged("no central directory entry") }
            let flags = u16(package, at + 8), method = u16(package, at + 10), dosDate = u16(package, at + 14)
            let crc = UInt32(truncatingIfNeeded: u32(package, at + 16))
            let compressed = u32(package, at + 20), size = u32(package, at + 24)
            let nameLength = u16(package, at + 28), extraLength = u16(package, at + 30), commentLength = u16(package, at + 32)
            let local = u32(package, at + 42)
            let name = String(decoding: package[(at + 46)..<(at + 46 + nameLength)], as: UTF8.self)
            let start = local + 30 + u16(package, local + 26) + u16(package, local + 28)
            let stored = Array(package[start..<(start + compressed)])
            let data = method == 8 ? try PdfFilters.inflate(stored) : stored
            guard data.count == size else { throw PdfReadException.damaged("size of \(name)") }
            files.append(ExportZipFile(name: name, method: method, compressedSize: compressed, crc: crc, dosDate: dosDate, flags: flags, data: data))
            at += 46 + nameLength + extraLength + commentLength
        }
        return files
    }
}

enum ExportKit {
    /// An 8 by 6 pixel colour JPEG.
    static let sampleJpeg = "/9j/4AAQSkZJRgABAQEAYABgAAD/2wBDAAMCAgMCAgMDAwMEAwMEBQgFBQQEBQoHBwYIDAoMDAsKCwsNDhIQDQ4RDgsLEBYQERMUFRUVDA8XGBYUGBIUFRT/2wBDAQMEBAUEBQkFBQkUDQsNFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBT/wAARCAAGAAgDASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwDI+Fv7K+jfueYe38J/wooor57Nc6zH6y/3zO/gHiHNf7Ep/wC0SP/Z"


    static var jpeg: [UInt8] { [UInt8](Data(base64Encoded: sampleJpeg) ?? Data()) }

    private static let fonts = "/Font <</F1 10 0 R /F2 11 0 R /F3 12 0 R>> /XObject <</Im1 13 0 R>>"

    static func open(_ pageContents: String...) throws -> PdfDocument { try PdfDocument.open(build(pageContents)) }

    static func open(pages pageContents: [String]) throws -> PdfDocument { try PdfDocument.open(build(pageContents)) }

    static func build(_ pageContents: String...) -> [UInt8] { build(pageContents) }

    /// Pages 612 by 792 with Helvetica as /F1, Helvetica-Bold /F2, Helvetica-Oblique /F3 and the sample JPEG as /Im1.
    static func build(_ pageContents: [String]) -> [UInt8] {
        let n = pageContents.count
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R>>")
        pdf.obj(2, "<</Type /Pages /Kids [\((0..<n).map { "\(20 + $0) 0 R" }.joined(separator: " "))] /Count \(n) /MediaBox [0 0 612 792]>>")
        pdf.obj(10, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding>>")
        pdf.obj(11, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold /Encoding /WinAnsiEncoding>>")
        pdf.obj(12, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica-Oblique /Encoding /WinAnsiEncoding>>")
        pdf.stream(13, "/Type /XObject /Subtype /Image /Width 8 /Height 6 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode", jpeg)
        for i in 0..<n {
            pdf.obj(20 + i, "<</Type /Page /Parent 2 0 R /Resources <<\(fonts)>> /Contents \(40 + i) 0 R>>")
            pdf.stream(40 + i, "", pageContents[i])
        }
        return pdf.finish()
    }

    /// Three pages of a made-up report: running head and page number, a heading, two paragraphs, a list, a drawn table and a picture.
    static func report() throws -> PdfDocument {
        let pages = (1...3).map { i in
            """
            BT /F1 9 Tf 72 765 Td (Confidential) Tj ET
            BT /F1 9 Tf 300 20 Td (\(i)) Tj ET
            BT /F2 24 Tf 72 700 Td (Annual Report) Tj ET
            BT /F1 11 Tf 72 670 Td 14 TL (First line of the opening paragraph that runs on) Tj T* (to a second line and stops there.) Tj ET
            BT /F1 11 Tf 72 620 Td (Second paragraph with ) Tj /F2 11 Tf (important) Tj /F3 11 Tf ( words.) Tj ET
            BT /F1 11 Tf 72 580 Td (\\225) Tj ET BT /F1 11 Tf 90 580 Td (Apples) Tj ET
            BT /F1 11 Tf 72 566 Td (\\225) Tj ET BT /F1 11 Tf 90 566 Td (Pears) Tj ET
            BT /F1 11 Tf 72 540 Td (1. First step) Tj ET
            BT /F1 11 Tf 72 526 Td (2. Second step) Tj ET
            0.5 w 72 400 m 372 400 l S 72 440 m 372 440 l S 72 480 m 372 480 l S
            72 400 m 72 480 l S 222 400 m 222 480 l S 372 400 m 372 480 l S
            BT /F1 11 Tf 80 460 Td (Item) Tj ET BT /F1 11 Tf 230 460 Td (Price) Tj ET
            BT /F1 11 Tf 80 420 Td (Tea) Tj ET BT /F1 11 Tf 230 420 Td (1,250.50) Tj ET
            q 96 0 0 72 72 250 cm /Im1 Do Q
            """
        }
        return try PdfDocument.open(build(pages))
    }

    static func unzip(_ package: [UInt8], _ entry: String) throws -> String {
        guard let found = try ExportZipReader.read(package).first(where: { $0.name == entry }) else {
            throw InvalidOperationException(entry)
        }
        return String(decoding: found.data, as: UTF8.self)
    }

    static func entries(_ package: [UInt8]) throws -> [String] {
        try ExportZipReader.read(package).map { $0.name }
    }

    /// XDocument.Parse: the element tree of a part.
    static func part(_ package: [UInt8], _ name: String, file: StaticString = #filePath, line: UInt = #line) throws -> XmlElement {
        let document = XmlDocument.parse(Array(try unzip(package, name).utf8))
        return try XCTUnwrap(document?.root, "\(name) is not well-formed", file: file, line: line)
    }

    /// The descendants of `element` called `local` in `namespace`, in document order.
    static func descendants(_ element: XmlElement, _ namespace: String, _ local: String) -> [XmlElement] {
        var found: [XmlElement] = []
        var work: [XmlNode] = element.children.reversed()
        while let node = work.popLast() {
            guard let e = node as? XmlElement else { continue }
            if e.name == XmlName(namespace, local) { found.append(e) }
            work.append(contentsOf: e.children.reversed())
        }
        return found
    }

    /// All the descendants of `element`, in document order.
    static func descendants(_ element: XmlElement) -> [XmlElement] {
        var found: [XmlElement] = []
        var work: [XmlNode] = element.children.reversed()
        while let node = work.popLast() {
            guard let e = node as? XmlElement else { continue }
            found.append(e)
            work.append(contentsOf: e.children.reversed())
        }
        return found
    }

    /// A reader for the PNGs the writer makes: all five filters, 8 bits, gray, RGB or RGBA; chunk CRCs checked.
    static func pngDecode(_ png: [UInt8], file: StaticString = #filePath, line: UInt = #line) throws -> (width: Int, height: Int, rgba: [UInt8]) {
        XCTAssertEqual(Array(png.prefix(8)), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A], file: file, line: line)
        var pos = 8, width = 0, height = 0, type = -1
        var data: [UInt8] = []
        var end = false
        func int(_ at: Int) -> Int { Int(png[at]) << 24 | Int(png[at + 1]) << 16 | Int(png[at + 2]) << 8 | Int(png[at + 3]) }
        while pos < png.count {
            let length = int(pos)
            let name = String(decoding: png[(pos + 4)..<(pos + 8)], as: UTF8.self)
            let body = Array(png[(pos + 8)..<(pos + 8 + length)])
            let crc = UInt32(truncatingIfNeeded: int(pos + 8 + length))
            XCTAssertEqual(crc, ExportZip.crc32(body, ExportZip.crc32(Array(png[(pos + 4)..<(pos + 8)]))), file: file, line: line)
            if name == "IHDR" {
                width = int(pos + 8)
                height = int(pos + 12)
                XCTAssertEqual(body[8], 8, file: file, line: line)
                type = Int(body[9])
            } else if name == "IDAT" {
                data += body
            } else if name == "IEND" {
                end = true
            }
            pos += 12 + length
        }
        XCTAssertTrue(end, file: file, line: line)
        let channels: Int
        switch type {
        case 0: channels = 1
        case 2: channels = 3
        case 6: channels = 4
        default: throw InvalidOperationException("color type \(type)")
        }
        let raw = try PdfFilters.inflate(data)
        let stride = width * channels
        XCTAssertEqual(raw.count, height * (stride + 1), file: file, line: line)
        var rows = [UInt8](repeating: 0, count: height * stride)
        for y in 0..<height {
            let filter = Int(raw[y * (stride + 1)])
            for i in 0..<stride {
                let a = i >= channels ? Int(rows[y * stride + i - channels]) : 0
                let b = y > 0 ? Int(rows[(y - 1) * stride + i]) : 0
                let c = i >= channels && y > 0 ? Int(rows[(y - 1) * stride + i - channels]) : 0
                let p = a + b - c, pa = abs(p - a), pb = abs(p - b), pc = abs(p - c)
                let predicted: Int
                switch filter {
                case 0: predicted = 0
                case 1: predicted = a
                case 2: predicted = b
                case 3: predicted = (a + b) / 2
                case 4: predicted = pa <= pb && pa <= pc ? a : pb <= pc ? b : c
                default: throw InvalidOperationException("filter \(filter)")
                }
                rows[y * stride + i] = UInt8(truncatingIfNeeded: Int(raw[y * (stride + 1) + 1 + i]) + predicted)
            }
        }
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        for i in 0..<(width * height) {
            rgba[4 * i] = rows[i * channels]
            rgba[4 * i + 1] = rows[i * channels + (channels == 1 ? 0 : 1)]
            rgba[4 * i + 2] = rows[i * channels + (channels == 1 ? 0 : 2)]
            rgba[4 * i + 3] = channels == 4 ? rows[i * channels + 3] : 255
        }
        return (width, height, rgba)
    }
}
