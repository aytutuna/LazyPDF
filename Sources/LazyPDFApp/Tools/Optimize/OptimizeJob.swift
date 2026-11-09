import Foundation
import LazyPDFKit

// Follows windows/LazyPDF.App/Tools/Optimize/OptimizeJob.cs. Open and NeedsOwner are ToolDocuments in Tools/Common. The work
// is done on a copy of the file's bytes, so it can run off the main actor while the document stays as it is.

/// The file and what the run reports of it; `sizeAfter` is the size of `bytes`, which Fast web view changes.
public struct OptimizeOutcome {
    public let bytes: [UInt8]
    public let sizeBefore: Int
    public let sizeAfter: Int
    public let notes: [String]
}

public enum OptimizeJob {
    public static func audit(_ file: [UInt8], password: String?, certificate: X509Certificate?) throws -> SpaceAudit {
        let document = try ToolDocuments.open(file, password: password, certificate: certificate)
        return PdfOptimizer(document).audit()
    }

    public static func run(_ file: [UInt8], password: String?, certificate: X509Certificate?, choice: OptimizeChoice,
                           codec: ImageCodec?, token: CancelToken) throws -> OptimizeOutcome {
        let document = try ToolDocuments.open(file, password: password, certificate: certificate)
        // The older handlers make their keys from the first /ID, which the optimizer's unencrypted working copy no longer shows.
        var options = choice.options(document.security)
        options.documentId = document.security == nil ? nil : document.firstId
        let result = try PdfOptimizer(document, codec).run(options)
        try token.throwIfCancelled()
        if !choice.fastWebView {
            return OptimizeOutcome(bytes: result.bytes, sizeBefore: result.sizeBefore, sizeAfter: result.sizeAfter, notes: result.notes)
        }

        let optimized = try ToolDocuments.open(result.bytes, password: password, certificate: certificate)
        let web = try optimized.saveLinearized(PdfSaveOptions(security: optimized.security))
        try token.throwIfCancelled()
        return OptimizeOutcome(bytes: web, sizeBefore: result.sizeBefore, sizeAfter: web.count, notes: result.notes)
    }
}
