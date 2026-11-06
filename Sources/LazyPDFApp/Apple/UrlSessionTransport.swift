#if canImport(Darwin)
import Foundation
import LazyPDFKit

// Follows windows/LazyPDF.App/Services/HttpSignatureTransport.cs: posting and fetching for time stamps, OCSP, CRLs and
// issuer certificates, on an ephemeral URLSession. The engine wants nil when a request fails; `lastFailure` says why in
// words a person can act on. Only https is fetched: there is no App Transport Security exception, so a plain http
// address is refused with a text of its own. CRL and OCSP addresses in public certificates are often http, so those
// checks fail here. There is no offline check up front as on Windows;
// a request that finds no connection reports the offline text when it fails.

public final class UrlSessionTransport: SignatureTransport {
    private static let maxResponseBytes = 8 << 20

    private final class Exchange: NSObject, URLSessionDataDelegate {
        var body = Data()
        var status = 0
        var tooLarge = false
        var error: Error?
        let done = DispatchSemaphore(value: 0)

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
    private let lock = NSLock()
    private var failure: String?
    private var task: URLSessionTask?
    private var cancelled = false

    /// A test passes a configuration with its own `protocolClasses`.
    public init(configuration: URLSessionConfiguration = .ephemeral) {
        self.configuration = configuration
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
        guard let address = URL(string: url), address.host != nil, let scheme = address.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return fail(L10n.t("The address is not a web address."))
        }
        guard scheme == "https" else { return fail(L10n.t("This server is not secure (http), so it was not contacted.")) }

        var request = URLRequest(url: address, timeoutInterval: 20)
        request.httpMethod = method
        request.httpBody = body
        if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }

        lock.lock()
        let stopped = cancelled
        lock.unlock()
        if stopped { return fail(Self.timedOut) }

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
            return fail(Self.timedOut)
        }
        running.resume()
        exchange.done.wait()
        lock.lock()
        task = nil
        lock.unlock()

        if exchange.tooLarge { return fail(L10n.t("The server's answer is too large.")) }
        if exchange.status != 0, !(200..<300).contains(exchange.status) {
            return fail(L10n.t("The server answered with an error ({0}).", exchange.status))
        }
        if let error = exchange.error {
            switch (error as? URLError)?.code {
            case .cancelled?, .timedOut?: return fail(Self.timedOut)
            case .notConnectedToInternet?, .dataNotAllowed?:
                return fail(L10n.t("This computer is offline. Connect to the internet and try again."))
            default: return fail(Self.unreachable)
            }
        }
        return [UInt8](exchange.body)
    }

    private static var timedOut: String { L10n.t("The server did not answer in time. Try again later.") }

    private static var unreachable: String { L10n.t("The server could not be reached. Check the connection and try again.") }
}
#endif
