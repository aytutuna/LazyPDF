#if canImport(Darwin)
import Foundation
import LazyPDFKit

// Follows windows/LazyPDF.App/Services/HttpSignatureTransport.cs: posting and fetching for time stamps, OCSP, CRLs and
// issuer certificates, on an ephemeral URLSession. The engine wants nil when a request fails; `lastFailure` says why in
// words a person can act on. URLSession carries https only: there is no App Transport Security exception, so plain http
// addresses, which most CRL, OCSP and time stamp points are, go through PlainHttpTransport instead. There is no
// offline check up front as on Windows; a request that finds no connection reports the offline text when it fails.
// Every hop, redirects included (the session reports https ones and this class follows them), is checked and counted by
// PlainHttpTransport. URLSession cannot be told which address to connect to, so for https the host is only resolved and
// checked beforehand; a DNS answer that changes in between is not caught.

public final class UrlSessionTransport: SignatureTransport {
    private static let maxResponseBytes = 8 << 20

    private final class Exchange: NSObject, URLSessionDataDelegate {
        var body = Data()
        var status = 0
        var redirect: String?
        var tooLarge = false
        var error: Error?
        let done = DispatchSemaphore(value: 0)

        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            redirect = request.url?.absoluteString
            status = response.statusCode
            completionHandler(nil)
            task.cancel()
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if !(200..<300).contains(status) {
                completionHandler(.cancel)
            } else if response.expectedContentLength > Int64(UrlSessionTransport.maxResponseBytes) {
                tooLarge = true
                completionHandler(.cancel)
            } else {
                completionHandler(.allow)
            }
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            body.append(data)
            if body.count > UrlSessionTransport.maxResponseBytes {
                tooLarge = true
                dataTask.cancel()
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            self.error = error
            done.signal()
        }
    }

    private let configuration: URLSessionConfiguration
    private let plain: PlainHttpTransport
    private let lock = NSLock()
    private var failure: String?
    private var task: URLSessionTask?
    private var cancelled = false

    /// A test passes a configuration with its own `protocolClasses`.
    public convenience init(configuration: URLSessionConfiguration = .ephemeral) {
        self.init(configuration: configuration, plain: PlainHttpTransport())
    }

    init(configuration: URLSessionConfiguration, plain: PlainHttpTransport) {
        self.configuration = configuration
        self.plain = plain
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 20
    }

    /// Why the last request gave nothing; nil after one that worked.
    public var lastFailure: String? {
        lock.lock()
        defer { lock.unlock() }
        return failure
    }

    /// Ends the request in flight and fails the ones after it.
    public func cancel() {
        lock.lock()
        cancelled = true
        let running = task
        lock.unlock()
        running?.cancel()
        plain.cancel()
    }

    public func post(_ url: String, _ contentType: String, _ body: [UInt8]) -> [UInt8]? {
        send(url, "POST", contentType, Data(body))
    }

    public func get(_ url: String) -> [UInt8]? {
        send(url, "GET", nil, nil)
    }

    private func fail(_ text: String) -> [UInt8]? {
        lock.lock()
        failure = text
        lock.unlock()
        return nil
    }

    private func send(_ url: String, _ method: String, _ contentType: String?, _ body: Data?) -> [UInt8]? {
        lock.lock()
        failure = nil
        lock.unlock()
        guard let first = URL(string: url), first.host != nil, let scheme = first.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return fail(L10n.t("The address is not a web address."))
        }
        var address = first
        var method = method
        var body = body
        var contentType = contentType
        var redirects = 0
        for _ in 0...Self.maxRedirects {
            let outcome: PlainHttpTransport.Outcome
            if address.scheme?.lowercased() == "https" {
                if let refusal = plain.refusal(address.host ?? "") { return fail(Self.text(refusal)) }
                outcome = secureSend(address, method, contentType, body)
            } else {
                outcome = plain.send(address, method: method, contentType: contentType, body: body)
            }
            switch outcome {
            case .body(let bytes): return bytes
            case .failed(let reason): return fail(Self.text(reason))
            case .redirect(let target, let keepsMethod, let code):
                if redirects == Self.maxRedirects { return fail(Self.text(.status(code))) }
                redirects += 1
                guard let next = URL(string: target, relativeTo: address)?.absoluteURL, next.host != nil,
                      ["http", "https"].contains(next.scheme?.lowercased()) else {
                    return fail(Self.unreachable)
                }
                address = next
                if !keepsMethod { (method, body, contentType) = ("GET", nil, nil) }
            }
        }
        return fail(Self.unreachable)
    }

    private static let maxRedirects = 5

    private static func text(_ reason: PlainHttpTransport.Failure) -> String {
        switch reason {
        case .timedOut: return timedOut
        case .unreachable: return unreachable
        case .offline: return L10n.t("This computer is offline. Connect to the internet and try again.")
        case .tooLarge: return L10n.t("The server's answer is too large.")
        case .local: return L10n.t("The address points to this computer, so it was not used.")
        case .tooMany: return L10n.t("Too many requests for one file. Stopped.")
        case .status(let code): return L10n.t("The server answered with an error ({0}).", code)
        }
    }

    private func secureSend(_ address: URL, _ method: String, _ contentType: String?,
                            _ body: Data?) -> PlainHttpTransport.Outcome {
        var request = URLRequest(url: address, timeoutInterval: 20)
        request.httpMethod = method
        request.httpBody = body
        if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }

        lock.lock()
        let stopped = cancelled
        lock.unlock()
        if stopped { return .failed(.timedOut) }

        let exchange = Exchange()
        let session = URLSession(configuration: configuration, delegate: exchange, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let running = session.dataTask(with: request)
        lock.lock()
        task = running
        let stoppedSince = cancelled
        lock.unlock()
        if stoppedSince {
            running.cancel()
            return .failed(.timedOut)
        }
        running.resume()
        exchange.done.wait()
        lock.lock()
        task = nil
        lock.unlock()

        if let target = exchange.redirect {
            return .redirect(target, keepsMethod: exchange.status == 307 || exchange.status == 308, status: exchange.status)
        }
        if exchange.tooLarge { return .failed(.tooLarge) }
        if exchange.status != 0, !(200..<300).contains(exchange.status) { return .failed(.status(exchange.status)) }
        if let error = exchange.error {
            switch (error as? URLError)?.code {
            case .cancelled?, .timedOut?: return .failed(.timedOut)
            case .notConnectedToInternet?, .dataNotAllowed?: return .failed(.offline)
            default: return .failed(.unreachable)
            }
        }
        return .body([UInt8](exchange.body))
    }

    private static var timedOut: String { L10n.t("The server did not answer in time. Try again later.") }

    private static var unreachable: String { L10n.t("The server could not be reached. Check the connection and try again.") }
}
#endif
