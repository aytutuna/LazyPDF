import Foundation

// Twin of windows/LazyPDF.Core/Document/PdfDocument.Save.cs: saving, the two ways out (PdfUpdate and PdfRewriter
// hold the work) and what they need to know of the reader.

extension PdfDocument {
    /// The bytes read, then an update (ISO 32000-1 7.5.6) holding only what changed since: the objects that
    /// differ, the new ones, free entries for deleted ones and a new cross-reference section. The bytes read
    /// are untouched, which is what signatures rest on; anything before the %PDF header was cut off on reading
    /// and is not in them. With no change the result is the bytes read.
    public func saveIncremental() throws -> [UInt8] {
        let update = try PdfUpdate.build(self)
        return source + update
    }

    /// A new file of the objects reachable from the trailer, renumbered. Signatures do not survive it.
    /// Another handler than the file's own, or none, needs the owner's rights when the file restricts its
    /// permissions, and throws `PdfPermissionException` without them.
    public func saveRewrite(_ options: PdfSaveOptions = PdfSaveOptions()) throws -> [UInt8] {
        try requireEncryptionRights(options.security)
        return try PdfRewriter(self, options).run()
    }

    /// The file had an /Info and the trailer has none now. Readers fill a missing key in from an older trailer,
    /// so an update has to say it is gone.
    var infoRemoved: Bool { hadInfo && !trailer.containsKey("Info") }

    /// The offsets of the cross-reference sections, newest first; empty after a rebuild.
    var sectionOffsets: [Int] { xrefRebuilt ? [] : sections }

    /// Something differs from what was read: an object, the trailer, or an object freed.
    var hasChanges: Bool { !changedObjects().isEmpty || !deleted.isEmpty || trailerChanged }

    /// The place of object `number` in its object stream; 0 when that cannot be told.
    func indexInObjectStream(_ number: Int) -> Int {
        guard let entry = entries[number], entry.kind == .compressed else { return 0 }
        return loadObjectStream(entry.streamNumber)?.numberIndex[number] ?? 0
    }
}
