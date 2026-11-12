import Foundation

// Twin of windows/LazyPDF.Core/Export/PdfFromPictures.cs: a PDF page for each picture or each frame of a picture file.
// The C# ArgumentException is thrown as `ArgumentException`: the files and the margin come from the user.

/// The paper a made PDF page has. `picture` sizes each page to its picture and means A4 for text.
public enum PdfPaper {
    case a4
    case letter
    case a3
    case a5
    case legal
    /// `PdfPageSetup.customWidth` by `customHeight` points, each clamped to 3...14400.
    case custom
    case picture
}

public enum PdfOrientation {
    /// Landscape for a picture wider than tall; portrait for text.
    case auto
    case portrait
    case landscape
}

/// Page size, orientation and margin (points) of a PDF made from pictures or text.
public struct PdfPageSetup {
    public let paper: PdfPaper
    public let orientation: PdfOrientation
    public let margin: Double
    public let customWidth: Double
    public let customHeight: Double

    public init(paper: PdfPaper = .a4, orientation: PdfOrientation = .auto, margin: Double = 36, customWidth: Double = 595.276, customHeight: Double = 841.89) {
        self.customWidth = customWidth
        self.customHeight = customHeight
        self.paper = paper
        self.orientation = orientation
        self.margin = margin
    }
}

/// A made PDF: its bytes, page count and the files in the list that could not be read (by index) and how many frames were too big to decode and left out.
public struct PicturesPdf {
    public let bytes: [UInt8]
    public let pages: Int
    public let unreadable: [Int]
    public let skippedFrames: Int

    public init(_ bytes: [UInt8], _ pages: Int, _ unreadable: [Int], skippedFrames: Int = 0) {
        self.bytes = bytes
        self.pages = pages
        self.unreadable = unreadable
        self.skippedFrames = skippedFrames
    }
}

public enum PdfFromPictures {
    private static let maxPageSide = 14400.0
    private static let defaultDpi = 96.0
    private static let minBox = 1.0

    private struct Picture {
        let image: PdfImage
        let dpiX: Double
        let dpiY: Double
        let orientation: Int
    }

    /// `files` are picture files in page order. A JPEG goes into the PDF as its own bytes, anything else is decoded by the
    /// `codec` (every frame is a page). A picture is placed at its natural size, which JFIF density or a decoded frame's own gives (each axis its
    /// own) and 96 dpi otherwise, shrunk to fit the page inside its margin, never enlarged, centred. A JPEG's Exif
    /// orientation is applied by the way it is placed, so its bytes stay as they are. Throws `ArgumentException` when no
    /// file could be read, or the margin is negative or leaves no room on the page. Throws `CancellationError` when the calling task is cancelled.
    public static func create(_ files: [[UInt8]], _ codec: ImageCodec, _ setup: PdfPageSetup? = nil) throws -> PicturesPdf {
        let setup = setup ?? PdfPageSetup()
        if !(setup.margin >= 0) { throw ArgumentException("The margin cannot be negative.") }
        let document = try ExportPdf.newDocument()
        var pictures: [Picture] = []
        var unreadable: [Int] = []
        var skipped = 0
        for i in 0..<files.count {
            try Task.checkCancellation()
            let before = pictures.count
            if isJpeg(files[i]), let jpeg = try PdfImageWriter.addJpeg(document, files[i]) {
                let (dpiX, dpiY) = JpegMeta.density(files[i])
                pictures.append(Picture(image: jpeg, dpiX: dpiX, dpiY: dpiY, orientation: JpegMeta.orientation(files[i])))
            } else if let frames = codec.decodeFile(files[i]) {
                skipped += frames.filter { $0.tooBig }.count
                for frame in frames where fits(frame) {
                    pictures.append(Picture(image: try PdfImageWriter.addRgba(document, frame.width, frame.height, frame.rgba), dpiX: storedDpi(frame).x, dpiY: storedDpi(frame).y, orientation: 1))
                }
            }
            if pictures.count == before { unreadable.append(i) }
        }
        if pictures.isEmpty { throw ArgumentException(ExportText.noUsablePicture) }

        try Task.checkCancellation()
        let naturals = pictures.map(natural)
        let sizes = naturals.map { pageSize(setup, $0.width, $0.height) }
        // Picture paper is the picture plus margins, so a tiny picture is room enough; only the clamp can take it away.
        let least = setup.paper == .picture ? Double.leastNonzeroMagnitude : minBox
        if sizes.contains(where: { $0.width - 2 * setup.margin < least || $0.height - 2 * setup.margin < least }) {
            throw ArgumentException("The margin leaves no room on the page.")
        }
        for i in 0..<sizes.count { try PageOperations.insertBlank(document, i, sizes[i].width, sizes[i].height) }
        for i in 0..<pictures.count {
            let (width, height) = sizes[i]
            let (naturalW, naturalH) = naturals[i]
            let scale = nanMin(1, nanMin((width - 2 * setup.margin) / naturalW, (height - 2 * setup.margin) / naturalH))
            let w = naturalW * scale, h = naturalH * scale
            let page = document.pages[i]
            let name = ContentResources.add(document, ContentResources.forEdit(document, page), "XObject", pictures[i].image.reference, "Im")
            let content = ContentWriter().paint(name, JpegMeta.placement(pictures[i].orientation, w, h, (width - w) / 2, (height - h) / 2))
            page.dictionary["Contents"] = try document.add(PdfStream(PdfDictionary(), data: content.toArray()))
        }
        try Task.checkCancellation()
        return PicturesPdf(try document.saveRewrite(), pictures.count, unreadable, skippedFrames: skipped)
    }

    private static func fits(_ frame: PdfRgbaImage) -> Bool {
        guard let size = ExportImageMerge.area(frame) else { return false }
        return frame.width > 0 && frame.height > 0 && size <= PdfImageSamples.maxPixels && frame.rgba.count == size * 4
    }

    private static func storedDpi(_ frame: PdfRgbaImage) -> (x: Double, y: Double) {
        (50.0...1200.0).contains(frame.dpiX) && (50.0...1200.0).contains(frame.dpiY) ? (frame.dpiX, frame.dpiY) : (defaultDpi, defaultDpi)
    }

    // The size on the page, after the picture is turned.
    private static func natural(_ p: Picture) -> (width: Double, height: Double) {
        let w = Double(p.image.width) * 72 / p.dpiX, h = Double(p.image.height) * 72 / p.dpiY
        return p.orientation >= 5 ? (h, w) : (w, h)
    }

    private static func pageSize(_ setup: PdfPageSetup, _ w: Double, _ h: Double) -> (width: Double, height: Double) {
        if setup.paper == .picture {
            return (clamp(w + 2 * setup.margin, 1, maxPageSide), clamp(h + 2 * setup.margin, 1, maxPageSide))
        }
        return ExportPdf.paper(setup, landscape: w > h)
    }

    // Math.Clamp: a NaN passes through.
    private static func clamp(_ value: Double, _ low: Double, _ high: Double) -> Double {
        value < low ? low : value > high ? high : value
    }

    private static func isJpeg(_ file: [UInt8]) -> Bool { file.count > 3 && file[0] == 0xFF && file[1] == 0xD8 }
}
