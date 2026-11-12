import Foundation

// Twin of windows/LazyPDF.Core/Document/PdfFileSaver.cs: Global rule 5, a save goes to a temporary file in the same
// folder, is read back, and only then takes the original's place. The replacement follows Lazy Scan's
// PdfAppender.cs (ReplaceOriginal).
//
// The C# marks the temporary file hidden and puts the original's attributes and creation time back; here the
// leading dot hides it and `replaceItemAt` keeps the original's metadata; a file without write permission is
// refused, as a read-only one is there. A read-back that differs from what was
// written is `CocoaError.fileReadCorruptFile`, where the C# raises IOException.

/// Writes PDF bytes to a path without ever leaving a half-written file there.
public enum PdfFileSaver {
    /// Writes `bytes` to a hidden temporary file beside `path`, reads it back, opens it with `PdfDocument.open`
    /// (`password` for an encrypted one) and then replaces the file. Any failure removes the temporary file and
    /// leaves the original as it was. Throws the Foundation error of the file system, or `PdfReadException`
    /// (the bytes are not a PDF).
    public static func save(_ path: String, _ bytes: [UInt8], password: String? = nil) throws {
        try save(path, bytes, source: nil, samePages: false) { try PdfDocument.open($0, password: password) }
    }

    /// As above, refused when the bytes read back with repairs the `source` did not need, or with another number of pages
    /// than the `source` has: for a tool that writes a rewrite of an open file over it.
    public static func save(_ path: String, _ bytes: [UInt8], password: String?, source: PdfDocument) throws {
        try save(path, bytes, source: source, samePages: true) { try PdfDocument.open($0, password: password) }
    }

    #if canImport(Security)
    /// The same, for bytes encrypted for recipients.
    public static func save(_ path: String, _ bytes: [UInt8], certificate: PdfCertificate, source: PdfDocument) throws {
        try save(path, bytes, source: source, samePages: true) { try PdfDocument.open($0, certificate: certificate) }
    }

    /// As above, for bytes encrypted for recipients: read back with the private key of `certificate`.
    public static func save(_ path: String, _ bytes: [UInt8], certificate: PdfCertificate) throws {
        try save(path, bytes, source: nil, samePages: false) { try PdfDocument.open($0, certificate: certificate) }
    }
    #endif

    /// As above; with the `source` the bytes come from, a file that opens only by a rebuild the source did not
    /// need, or (with `samePages`) that has another number of pages, is refused: opening alone is not proof that
    /// nothing was lost. `open` reads the bytes back the way the caller opened the source.
    static func save(_ path: String, _ bytes: [UInt8], source: PdfDocument?, samePages: Bool,
                     open: ([UInt8]) throws -> PdfDocument) throws {
        let full = URL(fileURLWithPath: path).standardizedFileURL
        let temp = full.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).pdf.tmp")
        do {
            try Data(bytes).write(to: temp, options: .withoutOverwriting)
            let file = try FileHandle(forWritingTo: temp)
            try file.synchronize()
            try file.close()
            let back = [UInt8](try Data(contentsOf: temp))
            if back != bytes { throw CocoaError(.fileReadCorruptFile) }
            let reopened = try open(back)
            if let source, reopened.xrefRebuilt && !source.xrefRebuilt {
                throw PdfReadException.damaged("The file does not read back without repairs.")
            }
            if let source, samePages, reopened.pages.count != source.pages.count {
                throw PdfReadException.damaged("The file reads back with another number of pages.")
            }
            try replace(temp, full)
        } catch {
            // The original is what matters; the stray file is hidden and harmless.
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
    }

    private static func replace(_ temp: URL, _ path: URL) throws {
        if !FileManager.default.fileExists(atPath: path.path) {
            try FileManager.default.moveItem(at: temp, to: path)
            return
        }
        // A rename ignores the file's own permissions, which Windows' replace does not.
        if !FileManager.default.isWritableFile(atPath: path.path) {
            throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: path.path])
        }
        #if canImport(Darwin)
        _ = try FileManager.default.replaceItemAt(path, withItemAt: temp)
        #else
        // swift-corelibs-foundation's replaceItemAt removes the original and then fails.
        if rename(temp.path, path.path) != 0 {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: path.path])
        }
        #endif
    }
}
