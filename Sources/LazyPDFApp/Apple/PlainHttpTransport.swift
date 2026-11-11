#if canImport(Network)
import Foundation
import Network

// The plain http half of UrlSessionTransport. Time stamp servers, OCSP responders and CRL points are mostly http, and
// their answers are signed, so the transport does not need TLS (windows/LazyPDF.App/Services/HttpSignatureTransport.cs
// takes http for the same reason). App Transport Security only covers URLSession, so these requests go over
// Network.framework with a small HTTP/1.1 client: one request per connection, no proxy, no keep-alive.
//
// The addresses come from the PDF, so loopback, link-local and unspecified ones (and localhost names) are refused, as
// on Windows; private LAN ranges stay allowed, since company PKI serves CRLs from them. A plain request connects to the
// first allowed address it resolved, so the address that was checked is the one used. URLSession cannot be told which
// address to use, so for https the name is only checked before the request and a DNS answer that changes in between is
// not caught. A system proxy is not used here and is not checked for https either.

final class PlainHttpTransport {
    enum Failure: Equatable {
        case timedOut, unreachable, offline, tooLarge, local, tooMany
        case status(Int)
    }

    enum Outcome: Equatable {
        case body([UInt8])
        case failed(Failure)
        case redirect(String, keepsMethod: Bool, status: Int)
    }

    static let maxResponseBytes = 8 << 20
    private static let maxRequests = 200

    /// For tests that talk to a listener on this computer.
    var allowLoopback = false

    private let timeout: TimeInterval
    private let lock = NSLock()
    private var requests = 0
    private var running: Exchange?
    private var cancelled = false

    init(timeout: TimeInterval = 20) {
        self.timeout = timeout
    }

    /// Ends the request in flight and fails the ones after it.
    func cancel() {
        lock.lock()
        cancelled = true
        let current = running
        lock.unlock()
        current?.stop()
    }

    /// Counts a request for the https half, which sends its own; nil when it may go ahead.
    func refusal(_ host: String) -> Failure? {
        if !countRequest() { return .tooMany }
        return addresses(host)?.isEmpty == true ? .local : nil
    }

    func send(_ url: URL, method: String, contentType: String?, body: Data?) -> Outcome {
        guard let host = url.host,
              let port = UInt16(exactly: url.port ?? 80).flatMap(NWEndpoint.Port.init(rawValue:)) else {
            return .failed(.unreachable)
        }
        if !countRequest() { return .failed(.tooMany) }
        let found = addresses(host)
        if found?.isEmpty == true { return .failed(.local) }
        let exchange = Exchange(host: found?.first ?? NWEndpoint.Host(host), port: port,
                                request: Self.request(url, host, method, contentType, body), timeout: timeout)
        lock.lock()
        if cancelled {
            lock.unlock()
            return .failed(.timedOut)
        }
        running = exchange
        lock.unlock()
        let outcome = exchange.run()
        lock.lock()
        running = nil
        lock.unlock()
        return outcome
    }

    private func countRequest() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        requests += 1
        return requests <= Self.maxRequests
    }

    /// The allowed addresses of a host, empty when all are refused; nil when the name does not resolve.
    private func addresses(_ host: String) -> [NWEndpoint.Host]? {
        let name = host.lowercased()
        if !allowLoopback, name == "localhost" || name.hasSuffix(".localhost") { return [] }
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &list) == 0 else { return nil }
        defer { freeaddrinfo(list) }
        var allowed = [NWEndpoint.Host]()
        var entry = list
        while let current = entry?.pointee {
            entry = current.ai_next
            guard let sockAddress = current.ai_addr else { continue }
            var bytes = [UInt8]()
            if current.ai_family == AF_INET {
                bytes = sockAddress.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                    withUnsafeBytes(of: $0.pointee.sin_addr) { Array($0) }
                }
            } else if current.ai_family == AF_INET6 {
                bytes = sockAddress.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                    withUnsafeBytes(of: $0.pointee.sin6_addr) { Array($0) }
                }
            }
            if bytes.isEmpty || (!allowLoopback && Self.isLocal(bytes)) { continue }
            if bytes.count == 4, let address = IPv4Address(Data(bytes)) {
                allowed.append(.ipv4(address))
            } else if bytes.count == 16, let address = IPv6Address(Data(bytes)) {
                allowed.append(.ipv6(address))
            }
        }
        return allowed
    }

    /// Loopback, link-local and unspecified addresses, also as IPv4-mapped IPv6.
    private static func isLocal(_ bytes: [UInt8]) -> Bool {
        if bytes.count == 16 {
            if bytes.prefix(10).allSatisfy({ $0 == 0 }), bytes[10] == 0xff, bytes[11] == 0xff {
                return isLocal(Array(bytes[12...]))
            }
            if bytes.prefix(15).allSatisfy({ $0 == 0 }), bytes[15] <= 1 { return true }
            return bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80
        }
        return bytes[0] == 127 || (bytes[0] == 169 && bytes[1] == 254) || bytes.allSatisfy { $0 == 0 }
    }

    private static func request(_ url: URL, _ host: String, _ method: String, _ contentType: String?,
                                _ body: Data?) -> Data {
        let parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var target = parts?.percentEncodedPath ?? "/"
        if target.isEmpty { target = "/" }
        if let query = parts?.percentEncodedQuery { target += "?" + query }
        var head = "\(method) \(target) HTTP/1.1\r\n"
        head += "Host: \(host.contains(":") ? "[\(host)]" : host)\(url.port.map { ":\($0)" } ?? "")\r\n"
        head += "Connection: close\r\n"
        if let contentType { head += "Content-Type: \(contentType)\r\n" }
        if let body { head += "Content-Length: \(body.count)\r\n" }
        var bytes = Data((head + "\r\n").utf8)
        if let body { bytes.append(body) }
        return bytes
    }
}

// Everything but run() and stop() happens on `queue`, so the parser state needs no lock.
private final class Exchange {
    private let queue = DispatchQueue(label: "lazypdf.plainhttp")
    private let connection: NWConnection
    private let request: Data
    private let timeout: TimeInterval
    private let done = DispatchSemaphore(value: 0)
    private var outcome: PlainHttpTransport.Outcome?

    private var buffer = [UInt8]()
    private var headersDone = false
    private var status = 0
    private var chunked = false
    private var length: Int?
    private var body = [UInt8]()

    init(host: NWEndpoint.Host, port: NWEndpoint.Port, request: Data, timeout: TimeInterval) {
        connection = NWConnection(host: host, port: port, using: .tcp)
        self.request = request
        self.timeout = timeout
    }

    func run() -> PlainHttpTransport.Outcome {
        queue.async { self.start() }
        done.wait()
        return outcome ?? .failed(.unreachable)
    }

    func stop() {
        queue.async { self.finish(.failed(.timedOut)) }
    }

    private func start() {
        guard outcome == nil else { return }
        connection.stateUpdateHandler = { [self] state in
            switch state {
            case .ready:
                connection.send(content: request, completion: .contentProcessed { [self] error in
                    if error != nil { finish(.failed(.unreachable)) }
                })
                receive()
            case .waiting(let error), .failed(let error):
                let offline = Self.isOffline(error) || connection.currentPath?.status == .unsatisfied
                finish(.failed(offline ? .offline : .unreachable))
            default:
                break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + timeout) { [self] in finish(.failed(.timedOut)) }
    }

    private static func isOffline(_ error: NWError) -> Bool {
        guard case .posix(let code) = error else { return false }
        return code == .ENETDOWN || code == .ENETUNREACH
    }

    private func finish(_ result: PlainHttpTransport.Outcome) {
        guard outcome == nil else { return }
        outcome = result
        connection.stateUpdateHandler = nil
        connection.cancel()
        done.signal()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 << 10) { [self] data, _, complete, error in
            if let data, !data.isEmpty {
                buffer.append(contentsOf: data)
                if let result = consume() {
                    finish(result)
                    return
                }
            }
            if complete { finish(atEnd()) } else if error != nil { finish(.failed(.unreachable)) } else { receive() }
        }
    }

    /// Reads what has arrived; nil while more is needed.
    private func consume() -> PlainHttpTransport.Outcome? {
        if !headersDone {
            guard let end = Self.find(buffer, [13, 10, 13, 10]) else {
                return buffer.count > 64 << 10 ? .failed(.unreachable) : nil
            }
            let head = String(decoding: buffer[..<end], as: UTF8.self)
            buffer.removeSubrange(..<(end + 4))
            headersDone = true
            if let early = readHead(head) { return early }
        }
        if chunked { return readChunks() }
        body.append(contentsOf: buffer)
        buffer.removeAll()
        if body.count > PlainHttpTransport.maxResponseBytes { return .failed(.tooLarge) }
        if let length, body.count >= length { return .body(Array(body.prefix(length))) }
        return nil
    }

    private func readHead(_ head: String) -> PlainHttpTransport.Outcome? {
        var lines = head.components(separatedBy: "\r\n")
        let statusLine = lines.removeFirst().split(separator: " ")
        guard statusLine.count >= 2, statusLine[0].hasPrefix("HTTP/"), let code = Int(statusLine[1]) else {
            return .failed(.unreachable)
        }
        status = code
        var headers = [String: String]()
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        if [301, 302, 303, 307, 308].contains(code), let target = headers["location"] {
            return .redirect(target, keepsMethod: code == 307 || code == 308, status: code)
        }
        if !(200..<300).contains(code) { return .failed(.status(code)) }
        if code == 204 { return .body([]) }
        chunked = headers["transfer-encoding"]?.lowercased().contains("chunked") == true
        if !chunked, let text = headers["content-length"] {
            guard let size = Int(text), size >= 0 else { return .failed(.unreachable) }
            if size > PlainHttpTransport.maxResponseBytes { return .failed(.tooLarge) }
            length = size
            if size == 0 { return .body([]) }
        }
        return nil
    }

    private func readChunks() -> PlainHttpTransport.Outcome? {
        while true {
            guard let lineEnd = Self.find(buffer, [13, 10]) else {
                return buffer.count > 1024 ? .failed(.unreachable) : nil
            }
            let line = String(decoding: buffer[..<lineEnd], as: UTF8.self)
            guard let size = Int(line.split(separator: ";").first?.trimmingCharacters(in: .whitespaces) ?? "", radix: 16),
                  size >= 0 else { return .failed(.unreachable) }
            if size == 0 { return .body(body) }
            guard size <= PlainHttpTransport.maxResponseBytes - body.count else { return .failed(.tooLarge) }
            let chunkEnd = lineEnd + 2 + size
            if buffer.count < chunkEnd + 2 { return nil }
            body.append(contentsOf: buffer[(lineEnd + 2)..<chunkEnd])
            if body.count > PlainHttpTransport.maxResponseBytes { return .failed(.tooLarge) }
            buffer.removeSubrange(..<(chunkEnd + 2))
        }
    }

    private func atEnd() -> PlainHttpTransport.Outcome {
        if headersDone, !chunked, length == nil { return .body(body) }
        return .failed(.unreachable)
    }

    private static func find(_ bytes: [UInt8], _ pattern: [UInt8]) -> Int? {
        guard bytes.count >= pattern.count else { return nil }
        for start in 0...(bytes.count - pattern.count) where bytes[start] == pattern[0] {
            if bytes[start..<(start + pattern.count)].elementsEqual(pattern) { return start }
        }
        return nil
    }
}
#endif
