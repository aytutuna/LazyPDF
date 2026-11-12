import Foundation

// Twin of windows/LazyPDF.Core/Office/OfficeConverter.cs: makes PDFs from Office files without Office.

enum OfficeConverter {
    /// Converts a .docx file. `fonts` is the app's font source, normally an `OfficeFontSource` that falls back to the
    /// bundled fonts. Throws `PdfReadException` when the file is not a readable Word document or is over a limit.
    static func fromWord(_ docx: [UInt8], _ fonts: FontSource?) throws -> OfficePdf {
        try OfficePdfWriter.create(try DocxReader.read(docx), fonts)
    }
}
