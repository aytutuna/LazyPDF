import Foundation

// Twin of windows/LazyPDF.Core/Stamps/StampTokens.cs: the {tokens} of a header or footer slot.

enum StampTokens {
    struct Values {
        let page: Int
        let pages: Int
        let bates: String
        let spec: HeaderFooterSpec
    }

    /// Replaces the known {tokens} of a slot's text; an unknown one is left as typed.
    static func expand(_ template: String, _ values: Values) -> String {
        let scalars = Array(template.unicodeScalars)
        if !scalars.contains("{") { return template }
        var result = String.UnicodeScalarView()
        var i = 0
        while i < scalars.count {
            if scalars[i] == "{", let end = scalars[i...].firstIndex(of: "}"), end > i,
               let text = value(String(String.UnicodeScalarView(scalars[(i + 1)..<end])), values) {
                result.append(contentsOf: text.unicodeScalars)
                i = end
            } else {
                result.append(scalars[i])
            }
            i += 1
        }
        return String(result)
    }

    private static func value(_ token: String, _ v: Values) -> String? {
        let colon = token.unicodeScalars.firstIndex(of: ":")
        let name = colon.map { String(token.unicodeScalars[..<$0]) } ?? token
        let argument = colon.map { String(token.unicodeScalars[token.unicodeScalars.index(after: $0)...]) }
        let spec = v.spec
        switch name {
        case "page": return String(v.page)
        case "pages": return String(v.pages)
        case "file": return spec.fileName
        case "bates": return spec.bates == nil ? nil : v.bates
        case "date":
            let format = argument.flatMap { $0.isEmpty ? nil : $0 } ?? spec.dateFormat
            return try? spec.date.toString(format, spec.culture)
        default: return nil
        }
    }
}
