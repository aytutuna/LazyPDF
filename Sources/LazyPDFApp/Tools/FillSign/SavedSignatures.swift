import Foundation
import LazyPDFKit

// Follows windows/LazyPDF.App/Tools/FillSign/SavedSignatures.cs: signatures and initials the person keeps, one PNG each in a
// folder of their own beside the app's other settings (Application Support/Lazy PDF/Signatures; inside the container on the Mac).

public enum SavedKind: String {
    case signature, initials
}

/// A signature or initials kept for reuse. The kind and the time are in the file name.
public struct SavedItem: Equatable {
    public let kind: SavedKind
    public let url: URL
}

public final class SavedSignatures {
    private let directory: URL
    private let codec: ImageCodec

    public static func defaultDirectory(_ folders: AppFolders) -> URL {
        folders.settings.appendingPathComponent("Signatures", isDirectory: true)
    }

    /// `codec` reads the pictures back; the apps pass the system's.
    public init(directory: URL, codec: ImageCodec) {
        self.directory = directory
        self.codec = codec
    }

    /// Newest first.
    public func list(_ kind: SavedKind) -> [SavedItem] {
        let prefix = kind.rawValue + "-"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasPrefix(prefix) && $0.hasSuffix(".png") }
            .sorted(by: >)
            .map { SavedItem(kind: kind, url: directory.appendingPathComponent($0)) }
    }

    @discardableResult
    public func add(_ kind: SavedKind, _ image: PdfRgbaImage) throws -> SavedItem {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.timeZone = TimeZone(secondsFromGMT: 0)
        stamp.dateFormat = "yyyyMMddHHmmssSSS"
        let unique = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(6).lowercased()
        let url = directory.appendingPathComponent("\(kind.rawValue)-\(stamp.string(from: Date()))-\(unique).png")
        try Data(try PngWriter.encode(image)).write(to: url)
        return SavedItem(kind: kind, url: url)
    }

    public func load(_ item: SavedItem) -> PdfRgbaImage? {
        guard let data = try? Data(contentsOf: item.url) else { return nil }
        return codec.decodeFile([UInt8](data))?.first(where: { !$0.tooBig })
    }

    public func remove(_ item: SavedItem) {
        // A file that cannot be deleted stays in the list; there is nothing more to do about it.
        try? FileManager.default.removeItem(at: item.url)
    }
}
