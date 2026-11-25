import Foundation
import LazyPDFKit

// Port of windows/LazyPDF.App/Viewer/DisplayCopy.cs. The renderer is made by the caller, as PDFKit's on Apple.

/// A copy of a file with some layers switched, and a renderer loaded from it. The viewer draws from this while the layers
/// differ from the file; the file itself, and the tab's session, are not touched.
public struct DisplayCopy {
    public let session: PdfEditSession
    public let renderer: DocumentRenderer

    /// Nil when the engine or the system cannot read the copy.
    public static func create(_ bytes: [UInt8], password: String?, changes: [(layer: PdfReference, visible: Bool)],
                              makeRenderer: () -> DocumentRenderer) -> DisplayCopy? {
        make(password, changes, makeRenderer) { try PdfEditSession.open(bytes, password: password) }
    }

    #if canImport(Security)
    public static func create(_ bytes: [UInt8], certificate: PdfCertificate, changes: [(layer: PdfReference, visible: Bool)],
                              makeRenderer: () -> DocumentRenderer) -> DisplayCopy? {
        make(nil, changes, makeRenderer) { try PdfEditSession.open(bytes, certificate: certificate) }
    }
    #endif

    private static func make(_ password: String?, _ changes: [(layer: PdfReference, visible: Bool)], _ makeRenderer: () -> DocumentRenderer,
                             _ open: () throws -> PdfEditSession) -> DisplayCopy? {
        do {
            let session = try open()
            for (layer, visible) in changes { PdfLayers.setVisible(session.document, layer, visible) }
            // A viewer may hide a layer by its usage rules (/AS) whatever /ON and /OFF say; in the copy the switches decide.
            let document = session.document
            if let properties = document.dict(document.catalog, "OCProperties"), let config = document.dict(properties, "D") {
                config.remove("AS")
            }
            _ = try session.commit("Layers")
            let renderer = makeRenderer()
            if renderer.load(session, password) { return DisplayCopy(session: session, renderer: renderer) }
            renderer.close()
            return nil
        } catch {
            return nil
        }
    }
}
