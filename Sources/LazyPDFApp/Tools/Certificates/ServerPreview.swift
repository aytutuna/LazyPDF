import Foundation
import LazyPDFKit

// Twin of windows/LazyPDF.App/Tools/Certificates/ServerPreview.cs.

/// Which servers Add validation data and the online checks would ask, before any is contacted.
enum ServerPreview {
    private static let shown = 6

    static func hosts(_ file: [UInt8], _ password: String?) async -> [String] {
        await Task.detached { () -> [String] in
            guard let servers = try? PdfLongTermValidation.servers(file, password: password) else { return [] }
            var seen = Set<String>()
            return servers.compactMap { host($0.url) }.filter { seen.insert($0).inserted }
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
