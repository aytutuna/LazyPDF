#if canImport(Security)
import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Signatures/IssuerFetchTests.cs: the same cases.

final class IssuerFetchTests: XCTestCase {
    private let pki = Pki.instance

    private final class Answering: SignatureTransport {
        private let answer: (String) -> [UInt8]?
        var gets = 0

        init(_ answer: @escaping (String) -> [UInt8]?) { self.answer = answer }

        func post(_ url: String, _ contentType: String, _ body: [UInt8]) -> [UInt8]? { nil }

        func get(_ url: String) -> [UInt8]? {
            gets += 1
            return answer(url)
        }
    }

    // The signer's own certificate only: the intermediate is neither in the signature nor in a /DSS.
    private func signedWithoutIntermediate(withRoot: Bool = false) throws -> [UInt8] {
        var request = SignatureKit.request(pki)
        request.chain = withRoot ? [pki.root] : []
        return try PdfSigner.sign(SignatureKit.plain(), request)
    }

    private func verify(_ file: [UInt8], _ transport: SignatureTransport?) throws -> SignatureReport {
        var options = pki.trusting
        options.now = Pki.signing
        options.transport = transport
        let reports = try PdfSignatureVerifier.verify(file, options)
        XCTAssertEqual(reports.count, 1)
        return try XCTUnwrap(reports.first)
    }

    func test_aSignerWhoseIssuerIsOnlyReachableByLinkIsUntrustedWithoutATransport() throws {
        let report = try verify(signedWithoutIntermediate(), nil)

        XCTAssertEqual(report.verdict, .validButUntrusted)
        XCTAssertTrue(report.problems.contains(.untrustedSigner))
    }

    func test_aTransportFetchesTheMissingIssuerAndTheSignerIsValid() throws {
        let network = FakeNetwork()

        let report = try verify(signedWithoutIntermediate(), network)

        XCTAssertEqual(report.verdict, .valid)
        XCTAssertFalse(report.problems.contains(.untrustedSigner))
        XCTAssertTrue(network.requests.contains(Pki.issuerUrl))
    }

    func test_aFetchedCertificateAloneTrustsNothing() throws {
        var options = VerifyOptions()
        options.now = Pki.signing
        options.transport = FakeNetwork()

        let reports = try PdfSignatureVerifier.verify(signedWithoutIntermediate(withRoot: true), options)

        XCTAssertEqual(reports.count, 1)
        XCTAssertTrue(try XCTUnwrap(reports.first).problems.contains(.untrustedSigner))
    }

    func test_garbageOrNothingFromTheTransportLeavesTheSignerUntrusted() throws {
        let file = try signedWithoutIntermediate()

        for transport in [Answering { _ in nil }, Answering { _ in [1, 2, 3, 4] }] {
            let report = try verify(file, transport)

            XCTAssertTrue(report.problems.contains(.untrustedSigner))
            XCTAssertTrue(transport.gets > 0)
        }
    }

    func test_theTransportIsNotAskedWhenTheChainIsComplete() throws {
        let network = Answering { _ in nil }
        let file = try PdfSigner.sign(SignatureKit.plain(), SignatureKit.request(pki))

        let report = try verify(file, network)

        XCTAssertEqual(report.verdict, .valid)
        XCTAssertEqual(network.gets, 0)
    }

    func test_fetchingStopsWhenAnIssuerDoesNotExtendTheChain() throws {
        let pki = self.pki
        let endless = Answering { _ in try? pki.issued("Elsewhere", [.digitalSignature]).rawData }

        let report = try verify(signedWithoutIntermediate(), endless)

        XCTAssertTrue(report.problems.contains(.untrustedSigner))
        XCTAssertEqual(endless.gets, 1)
    }

    func test_aSignatureIsNotFetchedForTwiceWhileItIsCheckedAtTwoTimes() throws {
        let network = Answering { _ in nil }
        var options = pki.trusting
        options.now = Pki.signing.adding(days: 1)
        options.transport = network

        _ = try PdfSignatureVerifier.verify(signedWithoutIntermediate(), options)

        XCTAssertEqual(network.gets, 1)
    }
}
#endif
