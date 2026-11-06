import Foundation

// Twin of windows/LazyPDF.Core/Optimize/LinearizerSave.cs: SaveLinearized, a member of PdfDocument.

extension PdfDocument {
    /// A new file of the objects reachable from the trailer, laid out for page-at-a-time viewing
    /// (ISO 32000-1 Annex F): the first page's objects up front with their own cross-reference
    /// section, the hint tables that locate every other page, then the rest. Numbered afresh, no
    /// history, signatures do not survive. `options` is read as by `saveRewrite` for its handler and id; object
    /// streams are never used, since the cross-reference sections of a linearized file are tables. A change to
    /// the result by `saveIncremental` leaves a valid file that is no longer linearized.
    public func saveLinearized(_ options: PdfSaveOptions = PdfSaveOptions()) throws -> [UInt8] {
        try requireEncryptionRights(options.security)
        return try Linearizer(self, options).run()
    }
}
