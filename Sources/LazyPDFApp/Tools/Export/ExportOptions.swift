import Foundation
import LazyPDFKit

// Follows windows/LazyPDF.App/Tools/Export/ExportOptions.cs and ExportPages.cs.

public enum ExportFormat: CaseIterable {
    case word, excel, powerPoint, html, markdown, rtf, text, pictures, images
}

public enum PictureFormat { case png, jpeg }

public struct ExportOptions: Equatable {
    public var format: ExportFormat

    /// 0-based pages in the order wanted; nil for all of them.
    public var pages: [Int]?

    /// HTML with every line at its place on the page, instead of text that reflows.
    public var fixedHtml: Bool
    public var markdownPictures: Bool
    public var picture: PictureFormat
    public var dpi: Int
    public var quality: Int

    public init(_ format: ExportFormat, pages: [Int]? = nil, fixedHtml: Bool = false, markdownPictures: Bool = false,
                picture: PictureFormat = .png, dpi: Int = 150, quality: Int = 85) {
        self.format = format
        self.pages = pages
        self.fixedHtml = fixedHtml
        self.markdownPictures = markdownPictures
        self.picture = picture
        self.dpi = dpi
        self.quality = quality
    }

    /// Pictures go into a folder; every other format is one file.
    public var toFolder: Bool { format == .pictures || format == .images }

    public var fileExtension: String {
        switch format {
        case .word: return ".docx"
        case .excel: return ".xlsx"
        case .powerPoint: return ".pptx"
        case .html: return ".html"
        case .markdown: return ".md"
        case .rtf: return ".rtf"
        case .text: return ".txt"
        default: return ""
        }
    }
}

/// What an export could not carry over.
public enum ExportGap: Equatable {
    case none
    /// The pages have no text, so nothing was written.
    case noText
    /// The workbook has the tables only.
    case outsideTables
    /// The workbook stops at the most sheets it holds.
    case pastSheetLimit
}

/// `files` are the files written, in the folder the export was given. `skipped` counts the pages the system could not draw.
public struct ExportResult: Equatable {
    public let files: [URL]
    public let skipped: Int
    public let gap: ExportGap
    public let picturesLeftOut: Int

    public init(files: [URL], skipped: Int = 0, gap: ExportGap = .none, picturesLeftOut: Int = 0) {
        self.files = files
        self.skipped = skipped
        self.gap = gap
        self.picturesLeftOut = picturesLeftOut
    }
}

public enum PageScope { case all, current, typed }

/// The pages an export covers: nil for all of them, or what is wrong with the pages typed.
public struct ExportPages: Equatable {
    public let pages: [Int]?
    public let error: String?

    public static func of(_ scope: PageScope, _ typed: String, current: Int, count: Int) -> ExportPages {
        if scope == .all { return ExportPages(pages: nil, error: nil) }
        if scope == .current { return ExportPages(pages: [current], error: nil) }
        let parsed = PageRange.parse(typed, count)
        guard parsed.isSuccess else { return ExportPages(pages: nil, error: parsed.error?.message) }
        var seen = Set<Int>()
        return ExportPages(pages: parsed.pages.filter { seen.insert($0).inserted }, error: nil)
    }
}
