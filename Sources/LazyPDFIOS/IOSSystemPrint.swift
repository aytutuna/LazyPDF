#if os(iOS)
import UIKit
import LazyPDFKit
import LazyPDFApp

/// The system print sheet for the document as it is now.
@MainActor
public enum IOSSystemPrint {
    /// What is handed to the print sheet. UIKit cannot read a file locked with a password or for certificate recipients,
    /// so those go as the engine's unlocked copy; the rest as the session has it.
    public static func item(_ session: PdfEditSession) throws -> Data {
        guard session.document.security != nil else { return Data(session.current) }
        return Data(try session.document.saveRewrite(PdfSaveOptions()))
    }

    public static func info(name: String) -> UIPrintInfo {
        let info = UIPrintInfo(dictionary: nil)
        info.jobName = name
        info.outputType = .general
        return info
    }

    /// Shows the sheet; `done` runs when it closes, with whether anything was printed. `problem` gets what keeps it from
    /// opening.
    public static func present(_ session: PdfEditSession, name: String, problem: (Problem) -> Void, done: ((Bool) -> Void)? = nil) {
        let data: Data
        do {
            data = try item(session)
        } catch {
            problem(Problem(L10n.t("Not printed"), L10n.t("A copy of {0} could not be made for printing. Check that the disk has room.", name)))
            return
        }
        guard UIPrintInteractionController.canPrint(data) else {
            problem(Problem(L10n.t("Not printed"), L10n.t("The printer did not take {0}. Check that it is on and has no error, then try again.", name)))
            return
        }
        let controller = UIPrintInteractionController.shared
        controller.printInfo = info(name: name)
        controller.printingItem = data
        controller.present(animated: true) { _, printed, _ in done?(printed) }
    }
}
#endif
