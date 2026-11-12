import Foundation

// Twin of windows/LazyPDF.Core/Office/OfficeConverter.cs: makes PDFs from Office files without Office.

public enum OfficeConverter {
    /// Converts a .docx file. `fonts` is the app's font source, normally an `OfficeFontSource` that falls back to the
    /// bundled fonts; `images` reads pictures that are not JPEG. Throws `PdfReadException` when the file is not a readable Word document or is over a limit.
    public static func fromWord(_ docx: [UInt8], _ fonts: FontSource?, _ images: ImageCodec? = nil) throws -> OfficePdf {
        try OfficePdfWriter.create(try DocxReader.read(docx), fonts, images: images)
    }

    /// Converts an .xlsx file, one or more pages per visible sheet as Excel would print it. `fileName` fills the file name field
    /// of headers and footers. Throws `PdfReadException` when the file is not a readable Excel workbook, is over a limit, or has
    /// nothing to print.
    public static func fromExcel(_ xlsx: [UInt8], _ fonts: FontSource?, fileName: String = "") throws -> OfficePdf {
        let book = try XlsxReader.read(xlsx)
        return try OfficePdfWriter.create(try XlsxLayout.run(book, LayoutFonts(fonts), Date(), fileName), fonts)
    }

    /// Converts a .pptx file, one page per slide that is not hidden. `images` reads pictures that are not JPEG. Throws `PdfReadException` when the file is not a readable
    /// PowerPoint presentation, is over a limit, or has no slide to show.
    public static func fromPowerPoint(_ pptx: [UInt8], _ fonts: FontSource?, _ images: ImageCodec? = nil) throws -> OfficePdf {
        let presentation = try PptxReader.read(pptx)
        return try OfficePdfWriter.create(try PptxLayout.run(presentation, LayoutFonts(fonts)), fonts, images: images)
    }
}
