import Foundation
import LazyPDFKit

// Follows windows/LazyPDF.App/Documents/DocumentOpener.cs.

/// When a file was last written and how long it was, the two things that tell a program it changed.
public struct DiskStamp: Equatable, Sendable {
    public let write: Date
    public let length: Int64

    public init(write: Date, length: Int64) {
        self.write = write
        self.length = length
    }

    /// Nil when the url is nil or the file is not there.
    public static func of(_ url: URL?) -> DiskStamp? {
        guard let url, let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        return DiskStamp(write: attributes[.modificationDate] as? Date ?? Date(timeIntervalSince1970: 0),
                         length: (attributes[.size] as? NSNumber)?.int64Value ?? 0)
    }
}

/// A file read and ready for the engine: PDF bytes, and where they came from.
public struct OpenSource: Sendable {
    public let bytes: [UInt8]
    /// The file to save back to; nil for pictures and text, which become a new document.
    public let url: URL?
    public let title: String
    /// The bytes were made from a picture or a text file, so they differ from anything on disk.
    public let made: Bool
    /// Something the person should hear about how the file was read.
    public let note: String?
    /// What the file looked like just before it was read, so a later change by someone else shows.
    public let stamp: DiskStamp?
    /// The file cannot be written to, so saving goes to Save as.
    public let readOnly: Bool
    /// A digest of the bytes of a file read from disk, to tell a file only touched from one rewritten; nil when too large.
    public let hash: Int?

    public init(bytes: [UInt8], url: URL?, title: String, made: Bool, note: String? = nil, stamp: DiskStamp? = nil, readOnly: Bool = false,
                hash: Int? = nil) {
        self.bytes = bytes
        self.url = url
        self.title = title
        self.made = made
        self.note = note
        self.stamp = stamp
        self.readOnly = readOnly
        self.hash = hash
    }
}

/// Reads what the open panel and the drop target hand over: PDFs as they are, pictures and text turned into a PDF.
public final class DocumentOpener {
    let codec: ImageCodec
    let fonts: FontSource
    /// How the bytes are read; the Apple shells set a coordinated reader.
    public var reader: (URL) throws -> Data = { try Data(contentsOf: $0) }

    public init(_ codec: ImageCodec, _ fonts: FontSource) {
        self.codec = codec
        self.fonts = fonts
    }

    /// Process-local: not to be kept or compared across launches. Nil above 64 MB.
    static func digest<B: ContiguousBytes>(_ bytes: B) -> Int? {
        bytes.withUnsafeBytes { buffer in
            guard buffer.count <= 64 * 1024 * 1024 else { return nil }
            var hasher = Hasher()
            hasher.combine(bytes: buffer)
            return hasher.finalize()
        }
    }

    static let isFolder = "The path is a folder."

    /// With `asCopy` a PDF has no file to save back to, for a url that is only a copy the system made for the app.
    public func read(_ url: URL, asCopy: Bool = false) throws -> OpenSource {
        if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            throw InvalidDataException(Self.isFolder)
        }
        var stamp = DiskStamp.of(url)
        let bytes = [UInt8](try reader(url))
        // A file fetched from the cloud was a placeholder when the first stamp was taken.
        if stamp?.length != Int64(bytes.count) { stamp = DiskStamp.of(url) }
        let stem = url.deletingPathExtension().lastPathComponent
        if FileKinds.isPicture(url) {
            do {
                let made = try PdfFromPictures.create([bytes], codec)
                return OpenSource(bytes: made.bytes, url: nil, title: stem + ".pdf", made: true)
            } catch is ArgumentException {
                throw InvalidDataException(ExportText.noUsablePicture)
            }
        }
        if FileKinds.isText(url) {
            let made = try PdfFromText.create(Self.decode(bytes), fonts: fonts)
            return OpenSource(bytes: made.bytes, url: nil, title: stem + ".pdf", made: true,
                              note: made.missing.isEmpty ? nil : L10n.t("Some characters have no letter in the font and were left out."))
        }
        if asCopy { return OpenSource(bytes: bytes, url: nil, title: url.lastPathComponent, made: false) }
        return OpenSource(bytes: bytes, url: url, title: url.lastPathComponent, made: false, stamp: stamp,
                          readOnly: !FileManager.default.isWritableFile(atPath: url.path), hash: Self.digest(bytes))
    }

    /// UTF-16 with a byte order mark, else UTF-8 when valid, else the Windows code page of the locale.
    static func decode(_ bytes: [UInt8], locale: Locale = .current) -> String {
        if bytes.starts(with: [0xFF, 0xFE]) || bytes.starts(with: [0xFE, 0xFF]) {
            let little = bytes[0] == 0xFF
            if let text = String(data: Data(bytes.dropFirst(2)), encoding: little ? .utf16LittleEndian : .utf16BigEndian) {
                return text
            }
        }
        if let text = String(data: Data(bytes), encoding: .utf8) {
            return String(text.drop(while: { $0 == "\u{FEFF}" }))
        }
        let windows: String.Encoding = locale.language.languageCode?.identifier == "tr" ? .windowsCP1254 : .windowsCP1252
        return String(data: Data(bytes), encoding: windows)
            ?? String(String.UnicodeScalarView(bytes.map { Unicode.Scalar($0) }))
    }
}
