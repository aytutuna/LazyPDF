import Foundation
import LazyPDFKit

// Follows windows/LazyPDF.App/Tools/Standards/ConvertJob.cs: the conversion of a tab's file, taken from the tab on the main
// actor and run off it.

public final class ConvertJob: @unchecked Sendable {
    private let file: [UInt8]
    private let password: String?
    private let hasCertificate: Bool
    private let open: @Sendable () throws -> PdfDocument

    @MainActor
    public init(_ tab: DocumentTab, _ host: ToolHost) {
        file = tab.session.current
        password = tab.password
        hasCertificate = tab.certificate != nil
        open = OpenCopy.of(tab, host)
    }

    /// A refusal is the answer, not an error; what the engine does not explain is thrown.
    public func run(_ level: PdfALevel, _ fonts: FontSource?) throws -> PdfAConversion {
        do {
            var bytes = file
            var password = self.password
            if hasCertificate {
                // The converter takes a password and nothing else, so a file opened with a certificate is handed over unencrypted.
                bytes = try open().saveRewrite()
                password = nil
            }
            return try PdfAConverter(fonts).convert(bytes, level, PanelDates.now(), password)
        } catch is PdfPermissionException {
            // Dropping the encryption needs the owner's rights, which the converter's own check of the permissions does not cover.
            return PdfAConversion(nil, PdfAText.noRights, [], [])
        } catch let error as PdfReadException {
            return PdfAConversion(nil, PdfAText.couldNotRewrite(error.message), [], [])
        }
    }
}
