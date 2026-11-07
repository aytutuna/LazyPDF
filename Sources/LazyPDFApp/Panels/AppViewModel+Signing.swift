import Foundation

// The window's side of ToolHost.openSigning and takeSigningField (windows/LazyPDF.App/Tools/IToolHost.cs).

extension AppViewModel {
    public func openSigning(_ field: String) {
        signingField = field
        if activeToolId != "certificates" { selectTool("certificates") }
    }

    public func takeSigningField() -> String? {
        defer { signingField = nil }
        return signingField
    }
}
