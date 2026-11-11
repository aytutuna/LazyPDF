import Foundation
import LazyPDFKit

// Twin of windows/LazyPDF.App/Services/Interfaces.cs.

/// Draws the pages of one open document. A tab holds one and loads it again after every change to the file.
public protocol DocumentRenderer: PageRenderer {
    /// Reads the file as the session holds it now. False when the system cannot draw it: the document can still be
    /// edited, and `render` gives nil.
    func load(_ session: PdfEditSession, _ password: String?) -> Bool

    /// Width and height in points of page `pageIndex` as displayed (crop box, /Rotate applied).
    func pageSize(_ pageIndex: Int) -> (width: Double, height: Double)

    func close()
}

/// The other Lazy apps on this computer: Lazy Scan to scan into, Lazy Print to print with.
public protocol SisterApps {
    var lazyScanInstalled: Bool { get }

    /// Whether `tryPrint` has anywhere to send a file.
    var lazyPrintInstalled: Bool { get }

    /// `failed` runs on the main actor when the system could not start Lazy Scan.
    func openLazyScan(_ failed: @escaping @MainActor () -> Void)

    /// Hands the file to Lazy Print. False when it is not there to take it.
    func tryPrint(_ file: URL) -> Bool
}
