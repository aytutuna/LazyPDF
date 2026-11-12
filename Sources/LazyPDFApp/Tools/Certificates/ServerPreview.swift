import Foundation
import LazyPDFKit

// Twin of windows/LazyPDF.App/Tools/Certificates/ServerPreview.cs.

/// Which servers Add validation data would ask, found by running it against a transport that answers nothing.
enum ServerPreview {
    private static let shown = 6

    private final class Recorder: SignatureTransport {
        var urls: [String] = []

        func post(_ url: String, _ contentType: String, _ body: [UInt8]) -> [UInt8]? {
            urls.append(url)
            return nil
        }

        func get(_ url: String) -> [UInt8]? {
            urls.append(url)
            return nil
        }
    }

    static func hosts(_ file: [UInt8], _ password: String?) async -> [String] {
        await Task.detached { () -> [String] in
            let recorder = Recorder()
            do {
                _ = try PdfLongTermValidation.add(file, recorder, PanelDates.now(), password: password)
            } catch {
                return []
            }
            var seen = Set<String>()
            return recorder.urls.compactMap(host).filter { seen.insert($0).inserted }
        }.value
    }

    static func describe(_ hosts: [String]) -> String {
        hosts.count <= shown ? hosts.joined(separator: ", ") : L10n.t("{0}, and {1} more", hosts.prefix(shown).joined(separator: ", "), hosts.count - shown)
    }

    private static func host(_ url: String) -> String? {
        guard let parts = URLComponents(string: url), let name = parts.host, !name.isEmpty else { return nil }
        let host = parts.port.map { "\(name):\($0)" } ?? name
        return parts.scheme?.lowercased() == "http" ? L10n.t("{0} (not encrypted)", host) : host
    }
}
