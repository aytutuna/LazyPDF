#if canImport(Network)
import Foundation
import Network

// The plain http half of UrlSessionTransport. Time stamp servers, OCSP responders and CRL points are mostly http, and
// their answers are signed, so the transport does not need TLS (windows/LazyPDF.App/Services/HttpSignatureTransport.cs
// takes http for the same reason). App Transport Security only covers URLSession, so these requests go over
// Network.framework with a small HTTP/1.1 client: one request per connection, no proxy, no keep-alive.

final class PlainHttpTransport {
    enum Failure: Equatable {
        case timedOut, unreachable, offline, tooLarge
        case status(Int)
    }

    enum Outcome: Equatable {
        case body([UInt8])
        case failed(Failure)
        case redirect(String, keepsMethod: Bool)
    }

    static let maxResponseBytes = 8 << 20

    private let timeout: TimeInterval
    private let lock = NSLock()
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

    func send(_ url: URL, method: String, contentType: String?, body: Data?) -> Outcome {
        guard let host = url.host, let port = NWEndpoint.Port(rawValue: UInt16(url.port ?? 80)) else {
            return .failed(.unreachable)
        }
        let exchange = Exchange(host: host, port: port, request: Self.request(url, host, method, contentType, body),
                                timeout: timeout)
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

    init(host: String, port: NWEndpoint.Port, request: Data, timeout: TimeInterval) {
        connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
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
        connection.stateUpdateHandler = { [self] state in
            switch state {
            case .ready:
                connection.send(content: request, completion: .contentProcessed { [self] error in
                    if error != nil { finish(.failed(.unreachable)) }
                })
                receive()
            case .waiting(let error), .failed(let error):
                finish(.failed(Self.isOffline(error) ? .offline : .unreachable))
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
            return .redirect(target, keepsMethod: code == 307 || code == 308)
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
        while let lineEnd = Self.find(buffer, [13, 10]) {
            let line = String(decoding: buffer[..<lineEnd], as: UTF8.self)
            guard let size = Int(line.split(separator: ";").first?.trimmingCharacters(in: .whitespaces) ?? "", radix: 16),
                  size >= 0 else { return .failed(.unreachable) }
            if size == 0 { return .body(body) }
            let chunkEnd = lineEnd + 2 + size
            if buffer.count < chunkEnd + 2 { return nil }
            body.append(contentsOf: buffer[(lineEnd + 2)..<chunkEnd])
            if body.count > PlainHttpTransport.maxResponseBytes { return .failed(.tooLarge) }
            buffer.removeSubrange(..<(chunkEnd + 2))
        }
        return nil
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
