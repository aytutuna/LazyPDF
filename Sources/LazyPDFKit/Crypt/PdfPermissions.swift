import Foundation

// Twin of windows/LazyPDF.Core/Crypt/PdfPermissions.cs: what the document's /P value lets a reader do
// (ISO 32000-1 7.6.3.2, table 22), and the cipher a new file is encrypted with.

/// A request to the reader, not a lock.
public struct PdfPermissions: OptionSet {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let none = PdfPermissions([])
    /// Print, at low quality when `printHighQuality` is missing.
    public static let print = PdfPermissions(rawValue: 1 << 2)
    public static let modify = PdfPermissions(rawValue: 1 << 3)
    public static let copy = PdfPermissions(rawValue: 1 << 4)
    public static let annotate = PdfPermissions(rawValue: 1 << 5)
    public static let fillForms = PdfPermissions(rawValue: 1 << 8)
    public static let extractForAccessibility = PdfPermissions(rawValue: 1 << 9)
    public static let assemble = PdfPermissions(rawValue: 1 << 10)
    public static let printHighQuality = PdfPermissions(rawValue: 1 << 11)
    public static let all: PdfPermissions = [.print, .modify, .copy, .annotate, .fillForms, .extractForAccessibility,
                                             .assemble, .printHighQuality]
}

/// The first case is the default.
public enum PdfCryptStrength: CaseIterable {
    /// V 5, R 6 (ISO 32000-2).
    case aes256
    /// V 4, R 4, the AESV2 crypt filter.
    case aes128
}
