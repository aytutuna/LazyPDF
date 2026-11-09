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

    public init(bytes: [UInt8], url: URL?, title: String, made: Bool, note: String? = nil, stamp: DiskStamp? = nil) {
        self.bytes = bytes
        self.url = url
        self.title = title
        self.made = made
        self.note = note
        self.stamp = stamp
    }
}

/// Reads what the open panel and the drop target hand over: PDFs as they are, pictures and text turned into a PDF.
public final class DocumentOpener {
    let codec: ImageCodec
    let fonts: FontSource

    public init(_ codec: ImageCodec, _ fonts: FontSource) {
        self.codec = codec
        self.fonts = fonts
    }

    public func read(_ url: URL) throws -> OpenSource {
        let stamp = DiskStamp.of(url)
        let bytes = [UInt8](try Data(contentsOf: url))
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
        return OpenSource(bytes: bytes, url: url, title: url.lastPathComponent, made: false, stamp: stamp)
    }

    /// UTF-8 when the bytes are valid UTF-8, Latin-1 otherwise.
    static func decode(_ bytes: [UInt8]) -> String {
        guard let text = String(data: Data(bytes), encoding: .utf8) else {
            return String(String.UnicodeScalarView(bytes.map { Unicode.Scalar($0) }))
        }
        return String(text.drop(while: { $0 == "\u{FEFF}" }))
    }
}
