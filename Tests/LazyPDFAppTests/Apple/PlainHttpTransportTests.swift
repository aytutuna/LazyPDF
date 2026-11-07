#if canImport(Network)
@testable import LazyPDFApp
import LazyPDFKit
import Network
import XCTest

// A listener on 127.0.0.1 stands in for the time stamp, OCSP and CRL servers.

private final class Server {
    enum Reply {
        case send(String, hold: Bool = false)
        case sendBytes([UInt8])
        case nothing
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "lazypdf.plainhttp.test")
    private let lock = NSLock()
    private var requests = [Data]()
    private var open = [NWConnection]()
    let reply: (Int) -> Reply
    private(set) var port: UInt16 = 0

    init(_ reply: @escaping (Int) -> Reply) throws {
        self.reply = reply
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if $0 == .ready { ready.signal() } }
        listener.newConnectionHandler = { [self] in accept($0) }
        listener.start(queue: queue)
        XCTAssertEqual(ready.wait(timeout: .now() + 5), .success)
        port = listener.port?.rawValue ?? 0
    }

    deinit { stop() }

    func stop() {
        listener.cancel()
        lock.lock()
        let connections = open
        lock.unlock()
        connections.forEach { $0.cancel() }
    }

    var seen: [Data] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    func url(_ path: String = "/") -> String { "http://127.0.0.1:\(port)\(path)" }

    private func accept(_ connection: NWConnection) {
        lock.lock()
        open.append(connection)
        let index = requests.count
        requests.append(Data())
        lock.unlock()
        connection.start(queue: queue)
        read(connection, index)
    }

    private func read(_ connection: NWConnection, _ index: Int) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 << 10) { [self] data, _, complete, error in
            lock.lock()
            requests[index].append(data ?? Data())
            let received = requests[index]
            lock.unlock()
            if Self.complete(received) {
                respond(connection, index)
            } else if !complete, error == nil {
                read(connection, index)
            }
        }
    }

    private static func complete(_ request: Data) -> Bool {
        guard let end = request.range(of: Data("\r\n\r\n".utf8)) else { return false }
        let head = String(decoding: request[..<end.lowerBound], as: UTF8.self).lowercased()
        guard let line = head.components(separatedBy: "\r\n").first(where: { $0.hasPrefix("content-length:") }),
              let length = Int(line.dropFirst(15).trimmingCharacters(in: .whitespaces)) else { return true }
        return request.count - end.upperBound >= length
    }

    private func respond(_ connection: NWConnection, _ index: Int) {
        switch reply(index) {
        case .send(let text, let hold):
            connection.send(content: Data(text.utf8), completion: .contentProcessed { _ in
                if !hold { connection.cancel() }
            })
        case .sendBytes(let bytes):
            connection.send(content: Data(bytes), completion: .contentProcessed { _ in connection.cancel() })
        case .nothing:
            break
        }
    }
}

private final class RedirectTarget: URLProtocol {
    static var hosts = [String]()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.hosts.append(request.url?.host ?? "")
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("secure".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class PlainHttpTransportTests: XCTestCase {
    private func transport(_ server: Server, timeout: TimeInterval = 20) -> UrlSessionTransport {
        UrlSessionTransport(configuration: .ephemeral, plain: PlainHttpTransport(timeout: timeout))
    }

    private func ok(_ body: String, extra: String = "") -> String {
        "HTTP/1.1 200 OK\r\nContent-Length: \(body.utf8.count)\r\n\(extra)\r\n\(body)"
    }

    func test_aGetSendsAnHttp11RequestAndGivesTheBody() throws {
        let server = try Server { _ in .send(self.ok("crl")) }
        let transport = transport(server)

        let answer = transport.get(server.url("/ca/root.crl?v=2"))

        XCTAssertEqual(answer, Array("crl".utf8))
        XCTAssertNil(transport.lastFailure)
        let request = String(decoding: server.seen[0], as: UTF8.self)
        XCTAssertEqual(request, "GET /ca/root.crl?v=2 HTTP/1.1\r\nHost: 127.0.0.1:\(server.port)\r\nConnection: close\r\n\r\n")
    }

    func test_aPostSendsTheBodyWithItsContentTypeAndLength() throws {
        let server = try Server { _ in .send(self.ok("stamp")) }
        let transport = transport(server)

        let answer = transport.post(server.url("/tsa"), "application/timestamp-query", [1, 2, 3, 0, 255])

        XCTAssertEqual(answer, Array("stamp".utf8))
        let request = server.seen[0]
        let head = "POST /tsa HTTP/1.1\r\nHost: 127.0.0.1:\(server.port)\r\nConnection: close\r\n"
            + "Content-Type: application/timestamp-query\r\nContent-Length: 5\r\n\r\n"
        XCTAssertEqual(request, Data(head.utf8) + Data([1, 2, 3, 0, 255]))
    }

    func test_anEmptyPathIsSentAsASlash() throws {
        let server = try Server { _ in .send(self.ok("x")) }

        _ = transport(server).get("http://127.0.0.1:\(server.port)")

        XCTAssertTrue(String(decoding: server.seen[0], as: UTF8.self).hasPrefix("GET / HTTP/1.1\r\n"))
    }

    func test_aChunkedAnswerIsJoined() throws {
        let server = try Server { _ in
            .send("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n4;ext=1\r\ndefg\r\n0\r\n\r\n")
        }

        XCTAssertEqual(transport(server).get(server.url()), Array("abcdefg".utf8))
    }

    func test_anAnswerWithoutALengthEndsWhenTheServerCloses() throws {
        let server = try Server { _ in .send("HTTP/1.0 200 OK\r\n\r\nuntil the end") }

        XCTAssertEqual(transport(server).get(server.url()), Array("until the end".utf8))
    }

    func test_aBinaryBodyKeepsItsBytes() throws {
        let body = (0..<256).map { UInt8($0) } + [13, 10, 13, 10]
        let reply = Array("HTTP/1.1 200 OK\r\nContent-Length: \(body.count)\r\n\r\n".utf8) + body
        let server = try Server { _ in .sendBytes(reply) }

        XCTAssertEqual(transport(server).get(server.url()), body)
    }

    func test_anAnswerInManyPartsIsJoined() throws {
        let body = [UInt8](repeating: 7, count: 300_000)
        let reply = Array("HTTP/1.1 200 OK\r\nContent-Length: \(body.count)\r\n\r\n".utf8) + body
        let server = try Server { _ in .sendBytes(reply) }

        XCTAssertEqual(transport(server).get(server.url()), body)
    }

    func test_anOversizedLengthIsRefusedBeforeReadingIt() throws {
        let server = try Server { _ in .send("HTTP/1.1 200 OK\r\nContent-Length: \(9 << 20)\r\n\r\nabc", hold: true) }
        let transport = transport(server)

        L10n.english {
            XCTAssertNil(transport.get(server.url()))
            XCTAssertTrue(transport.lastFailure?.contains("too large") == true)
        }
    }

    func test_anOversizedAnswerWithoutALengthIsRefused() throws {
        let reply = Array("HTTP/1.0 200 OK\r\n\r\n".utf8) + [UInt8](repeating: 1, count: 9 << 20)
        let server = try Server { _ in .sendBytes(reply) }
        let transport = transport(server)

        L10n.english {
            XCTAssertNil(transport.get(server.url()))
            XCTAssertTrue(transport.lastFailure?.contains("too large") == true)
        }
    }

    func test_aNotFoundGivesNilAndTheCode() throws {
        let server = try Server { _ in .send("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n") }
        let transport = transport(server)

        L10n.english {
            XCTAssertNil(transport.get(server.url()))
            XCTAssertTrue(transport.lastFailure?.contains("404") == true)
        }
    }

    func test_aServerThatNeverAnswersTimesOut() throws {
        let server = try Server { _ in .nothing }
        let transport = transport(server, timeout: 0.5)

        L10n.english {
            XCTAssertNil(transport.get(server.url()))
            XCTAssertTrue(transport.lastFailure?.contains("did not answer") == true)
        }
    }

    func test_aConnectionClosedMidBodyGivesNil() throws {
        let server = try Server { _ in .send("HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\nabc") }
        let transport = transport(server)

        L10n.english {
            XCTAssertNil(transport.get(server.url()))
            XCTAssertTrue(transport.lastFailure?.contains("could not be reached") == true)
        }
    }

    func test_aServerThatSendsNonsenseGivesNil() throws {
        let server = try Server { _ in .send("not http at all\r\n\r\n") }

        XCTAssertNil(transport(server).get(server.url()))
    }

    func test_aPortNobodyListensOnGivesNilAndSaysSo() throws {
        let server = try Server { _ in .nothing }
        let url = server.url()
        server.stop()
        let transport = transport(server, timeout: 5)

        L10n.english {
            XCTAssertNil(transport.get(url))
            XCTAssertTrue(transport.lastFailure?.contains("could not be reached") == true)
        }
    }

    func test_aRedirectIsFollowedAndAPostBecomesAGet() throws {
        let server = try Server { index in
            index == 0 ? .send("HTTP/1.1 302 Found\r\nLocation: /moved\r\nContent-Length: 0\r\n\r\n") : .send(self.ok("here"))
        }

        let answer = transport(server).post(server.url("/old"), "text/plain", [1])

        XCTAssertEqual(answer, Array("here".utf8))
        XCTAssertTrue(String(decoding: server.seen[1], as: UTF8.self).hasPrefix("GET /moved HTTP/1.1\r\n"))
    }

    func test_aTemporaryRedirectKeepsThePost() throws {
        let server = try Server { index in
            index == 0 ? .send("HTTP/1.1 307 Temporary Redirect\r\nLocation: /again\r\nContent-Length: 0\r\n\r\n") : .send(self.ok("ok"))
        }

        _ = transport(server).post(server.url("/old"), "text/plain", [1, 2])

        XCTAssertEqual(server.seen[1].suffix(2), Data([1, 2]))
        XCTAssertTrue(String(decoding: server.seen[1], as: UTF8.self).hasPrefix("POST /again HTTP/1.1\r\n"))
    }

    func test_aRedirectLoopGivesUp() throws {
        let server = try Server { _ in .send("HTTP/1.1 302 Found\r\nLocation: /\r\nContent-Length: 0\r\n\r\n") }
        let transport = transport(server)

        L10n.english {
            XCTAssertNil(transport.get(server.url()))
            XCTAssertEqual(transport.lastFailure, "The server answered with an error (302).")
        }
        XCTAssertEqual(server.seen.count, 6)
    }

    func test_aChunkedAnswerOverTheCapIsRefused() throws {
        let chunk = String(repeating: "a", count: 1 << 20)
        let reply = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n"
            + String(repeating: "100000\r\n\(chunk)\r\n", count: 9) + "0\r\n\r\n"
        let server = try Server { _ in .send(reply) }
        let transport = transport(server)

        L10n.english {
            XCTAssertNil(transport.get(server.url()))
            XCTAssertTrue(transport.lastFailure?.contains("too large") == true)
        }
    }

    func test_aHugeChunkSizeIsRefusedWithoutTrapping() throws {
        let server = try Server { _ in
            .send("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n7fffffffffffffff\r\nabc", hold: true)
        }
        let transport = transport(server)

        L10n.english {
            XCTAssertNil(transport.get(server.url()))
            XCTAssertTrue(transport.lastFailure?.contains("too large") == true)
        }
    }

    func test_aChunkSizeLineThatNeverEndsIsGivenUp() throws {
        let junk = String(repeating: "f", count: 4096)
        let server = try Server { _ in .send("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n\(junk)", hold: true) }
        let transport = transport(server)
        let started = Date()

        XCTAssertNil(transport.get(server.url()))

        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    func test_aPortOutOfRangeFailsInsteadOfTrapping() {
        let transport = UrlSessionTransport(configuration: .ephemeral, plain: PlainHttpTransport(timeout: 2))

        L10n.english {
            XCTAssertNil(transport.get("http://127.0.0.1:99999/"))
            XCTAssertTrue(transport.lastFailure?.contains("could not be reached") == true)
        }
    }

    func test_aRedirectToANonWebSchemeFails() throws {
        let server = try Server { _ in .send("HTTP/1.1 302 Found\r\nLocation: ftp://x/\r\nContent-Length: 0\r\n\r\n") }
        let transport = transport(server)

        L10n.english {
            XCTAssertNil(transport.get(server.url()))
            XCTAssertTrue(transport.lastFailure?.contains("could not be reached") == true)
        }
    }

    func test_aRedirectToHttpsHandsOverToTheSecureSession() throws {
        let server = try Server { _ in
            .send("HTTP/1.1 301 Moved\r\nLocation: https://secure.example/x\r\nContent-Length: 0\r\n\r\n")
        }
        RedirectTarget.hosts = []
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RedirectTarget.self]
        let chained = UrlSessionTransport(configuration: configuration, plain: PlainHttpTransport(timeout: 5))

        XCTAssertEqual(chained.get(server.url()), Array("secure".utf8))
        XCTAssertEqual(RedirectTarget.hosts, ["secure.example"])
    }

    func test_aCancelledTransportFailsTheRequestsAfterIt() throws {
        let server = try Server { _ in .send(self.ok("x")) }
        let transport = transport(server)

        transport.cancel()

        L10n.english {
            XCTAssertNil(transport.get(server.url()))
            XCTAssertTrue(transport.lastFailure?.contains("did not answer") == true)
        }
        XCTAssertTrue(server.seen.isEmpty)
    }

    func test_cancellingEndsARequestInFlight() throws {
        let server = try Server { _ in .nothing }
        let transport = transport(server)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { transport.cancel() }
        let started = Date()

        XCTAssertNil(transport.get(server.url()))

        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }
}
#endif
