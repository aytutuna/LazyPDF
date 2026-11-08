#if os(iOS)
import UIKit
import UniformTypeIdentifiers
import LazyPDFKit
import LazyPDFApp

// Follows MainWindow.Files.cs ImportCertificate: picks a .p12 or .pfx, asks for its password and puts the identity in the
// keychain. UIKit presents both, because the password question that asks for this is itself a sheet, and SwiftUI shows one
// sheet at a time.

@MainActor
enum IOSCertificateImport {
    private static let types = [UTType.pkcs12] + ["p12", "pfx"].compactMap { UTType(filenameExtension: $0) }

    static func run(_ keys: IOSCertificates, problem: (Problem) -> Void) async -> CertificateChoice? {
        guard let top = top(), let file = await pick(from: top) else { return nil }
        defer { file.access?.stop() }
        guard let bytes = try? Data(contentsOf: file.url), let password = await ask(from: top) else { return nil }
        do {
            return try keys.importIdentity([UInt8](bytes), password: password)
        } catch {
            problem(Problem(L10n.t("Certificate not imported"),
                            L10n.t("Check the password, and that the file holds a certificate with its private key.")))
            return nil
        }
    }

    private static func top() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        var top = scene?.keyWindow?.rootViewController
        while let next = top?.presentedViewController { top = next }
        return top
    }

    private static func pick(from top: UIViewController) async -> PickedFile? {
        let file: PickedFile? = await withCheckedContinuation { continuation in
            let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
            // The picker keeps its delegate weakly.
            delegate = PickerDelegate { continuation.resume(returning: $0.first) }
            picker.delegate = delegate
            top.present(picker, animated: true)
        }
        delegate = nil
        return file
    }

    private static var delegate: PickerDelegate?

    private static func ask(from top: UIViewController) async -> String? {
        await withCheckedContinuation { continuation in
            let alert = UIAlertController(title: L10n.t("Password of the certificate file"), message: nil, preferredStyle: .alert)
            alert.addTextField {
                $0.isSecureTextEntry = true
                $0.placeholder = L10n.t("Password")
            }
            alert.addAction(UIAlertAction(title: L10n.t("Cancel"), style: .cancel) { _ in continuation.resume(returning: nil) })
            alert.addAction(UIAlertAction(title: L10n.t("Import"), style: .default) { [unowned alert] _ in
                continuation.resume(returning: alert.textFields?.first?.text ?? "")
            })
            var presenter = top
            while let next = presenter.presentedViewController { presenter = next }
            presenter.present(alert, animated: true)
        }
    }
}
#endif
