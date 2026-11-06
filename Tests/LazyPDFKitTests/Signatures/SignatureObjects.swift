#if canImport(Security)
import XCTest
@testable import LazyPDFKit

// No C# twin: the casts and small builders the C# tests write inline, as lookups that fail a test where C# throws
// an InvalidCastException.

enum SignatureObjects {
    static func dictionary(_ document: PdfDocument, _ number: Int, file: StaticString = #filePath, line: UInt = #line) throws -> PdfDictionary {
        try XCTUnwrap(document.get(number) as? PdfDictionary, "object \(number) is not a dictionary", file: file, line: line)
    }

    static func stream(_ document: PdfDocument, _ number: Int, file: StaticString = #filePath, line: UInt = #line) throws -> PdfStream {
        try XCTUnwrap(document.get(number) as? PdfStream, "object \(number) is not a stream", file: file, line: line)
    }

    static func entries(_ pairs: (String, PdfObject)...) -> PdfDictionary {
        let dictionary = PdfDictionary()
        for (key, value) in pairs { dictionary[key] = value }
        return dictionary
    }

    static func text(_ value: String) -> PdfString { PdfString(bytes: TestPdf.latin(value), isHex: false) }

    static func numbers(_ values: Double...) -> PdfArray { PdfArray(values.map { PdfNumber($0) }) }

    /// The first page's /Annots array.
    static func annots(_ document: PdfDocument, file: StaticString = #filePath, line: UInt = #line) throws -> PdfArray {
        try XCTUnwrap(document.array(document.pages[0].dictionary, "Annots"), "the page has no /Annots", file: file, line: line)
    }

    /// The first signature field of the form.
    static func signatureField(_ document: PdfDocument, file: StaticString = #filePath, line: UInt = #line) throws -> FormField {
        try XCTUnwrap(PdfForm.read(document).fields.first { $0.kind == .signature }, "no signature field", file: file, line: line)
    }

    static func lastIndex(_ file: [UInt8], _ text: String) -> Int? {
        let pattern = TestPdf.latin(text)
        var found: Int?
        var from = 0
        while let at = file.indexOf(pattern, from: from) {
            found = at
            from = at + 1
        }
        return found
    }

    /// A network with its fields set, where the C# writes an object initializer.
    static func network(_ configure: (FakeNetwork) -> Void = { _ in }) -> FakeNetwork {
        let network = FakeNetwork()
        configure(network)
        return network
    }

    static func request(_ certificate: X509Certificate, _ time: DateTimeOffset, _ configure: (inout PdfSignRequest) -> Void = { _ in }) -> PdfSignRequest {
        var request = PdfSignRequest(certificate, time)
        request.chain = Pki.instance.chain
        configure(&request)
        return request
    }

    /// A request by the test signer, as `SignatureKit.Request(Pki) with { ... }` writes it.
    static func leafRequest(_ configure: (inout PdfSignRequest) -> Void) -> PdfSignRequest {
        var request = SignatureKit.request(Pki.instance)
        configure(&request)
        return request
    }

    /// A second signature by the other key a day later.
    static func second(_ file: [UInt8], fieldName: String? = nil) throws -> [UInt8] {
        try PdfSigner.sign(file, request(Pki.instance.leafEc, Pki.signing.adding(days: 1)!) { $0.fieldName = fieldName })
    }
}
#endif
