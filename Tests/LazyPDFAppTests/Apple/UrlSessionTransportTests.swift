#if canImport(Darwin)
import LazyPDFApp
import LazyPDFKit
import XCTest

// Mirrors windows/LazyPDF.App.Tests/HttpSignatureTransportTests.cs with a URLProtocol in place of the handler. There is
// no IsOffline guard to skip on. Plain http goes to PlainHttpTransport, which PlainHttpTransportTests covers.

private final class Stub: URLProtocol {
    static var answer: (URLRequest) throws -> (status: Int, body: Data) = { _ in (200, Data()) }
    static var seen: [(request: URLRequest, body: Data)] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = Data()
        if let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(buffer, count: count)
            }
            stream.close()
        }
        Self.seen.append((request, body))
        do {
            let (status, data) = try Self.answer(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

final class UrlSessionTransportTests: XCTestCase {
    private func transport(_ answer: @escaping (URLRequest) throws -> (status: Int, body: Data)) -> UrlSessionTransport {
        Stub.answer = answer
        Stub.seen = []
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Stub.self]
        return UrlSessionTransport(configuration: configuration)
    }

    func test_aPostSendsTheBodyWithItsContentTypeAndGivesTheAnswer() {
        let transport = transport { _ in (200, Data([9, 8, 7])) }

        let answer = transport.post("https://tsa.example/stamp", "application/timestamp-query", [1, 2, 3])

        XCTAssertEqual(answer, [9, 8, 7])
        XCTAssertEqual(Stub.seen.first?.body, Data([1, 2, 3]))
        XCTAssertEqual(Stub.seen.first?.request.httpMethod, "POST")
        XCTAssertEqual(Stub.seen.first?.request.value(forHTTPHeaderField: "Content-Type"), "application/timestamp-query")
        XCTAssertNil(transport.lastFailure)
    }

    func test_aGetGivesTheBody() {
        let transport = transport { _ in (200, Data([5])) }

        XCTAssertEqual(transport.get("https://crl.example/ca.crl"), [5])
    }

    func test_anErrorStatusGivesNilAndTheCode() {
        let transport = transport { _ in (503, Data()) }

        L10n.english {
            XCTAssertNil(transport.get("https://ocsp.example/"))
            XCTAssertTrue(transport.lastFailure?.contains("503") == true)
        }
    }

    func test_aServerThatCannotBeReachedGivesNilAndSaysSo() {
        let transport = transport { _ in throw URLError(.cannotConnectToHost) }

        L10n.english {
            XCTAssertNil(transport.get("https://ocsp.example/"))
            XCTAssertTrue(transport.lastFailure?.contains("could not be reached") == true)
        }
    }

    func test_noConnectionGivesNilAndSaysTheComputerIsOffline() {
        let transport = transport { _ in throw URLError(.notConnectedToInternet) }

        L10n.english {
            XCTAssertNil(transport.get("https://ocsp.example/"))
            XCTAssertTrue(transport.lastFailure?.contains("offline") == true)
        }
    }

    func test_aSlowServerGivesNilAndSaysItDidNotAnswer() {
        let transport = transport { _ in throw URLError(.timedOut) }

        L10n.english {
            XCTAssertNil(transport.get("https://ocsp.example/"))
            XCTAssertTrue(transport.lastFailure?.contains("did not answer") == true)
        }
    }

    func test_onlyWebAddressesAreFetched() {
        let transport = transport { _ in (200, Data([1])) }

        for url in ["file:///C:/secret.txt", "ftp://host/a", "not an address"] {
            XCTAssertNil(transport.get(url), url)
            XCTAssertNotNil(transport.lastFailure, url)
        }
        XCTAssertTrue(Stub.seen.isEmpty)
    }

    func test_aPlainHttpAddressDoesNotGoThroughUrlSession() {
        let transport = transport { _ in (200, Data([1])) }

        _ = transport.get("http://127.0.0.1:1/ca.crl")

        XCTAssertTrue(Stub.seen.isEmpty)
    }

    func test_anAnswerThatIsTooLargeIsRefused() {
        let transport = transport { _ in (200, Data(count: 9 << 20)) }

        L10n.english {
            XCTAssertNil(transport.get("https://ocsp.example/"))
            XCTAssertTrue(transport.lastFailure?.contains("too large") == true)
        }
    }

    func test_aSuccessClearsTheLastFailure() {
        var calls = 0
        let transport = transport { _ in
            calls += 1
            return calls == 1 ? (404, Data()) : (200, Data([1]))
        }

        _ = transport.get("https://a.example/")
        XCTAssertNotNil(transport.lastFailure)
        _ = transport.get("https://a.example/")

        XCTAssertNil(transport.lastFailure)
    }

    func test_aCancelledTransportFailsTheRequestsAfterIt() {
        let transport = transport { _ in (200, Data([1])) }

        transport.cancel()

        L10n.english {
            XCTAssertNil(transport.get("https://a.example/"))
            XCTAssertTrue(transport.lastFailure?.contains("did not answer") == true)
        }
        XCTAssertTrue(Stub.seen.isEmpty)
    }
}
#endif
