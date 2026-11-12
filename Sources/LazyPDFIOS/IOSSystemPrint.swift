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

    // Regions where Letter is the usual office paper.
    static let letterRegions: Set<String> = ["US", "CA", "MX", "PH", "CL", "CO", "VE", "CR", "GT", "DO", "PA", "SV", "NI", "HN", "PR", "BO", "PE"]

    /// The sheet size a layout is made for: the sheet UIKit prints on is chosen later and takes the pages scaled to fit.
    static var paper: (width: Double, height: Double) {
        letterRegions.contains(Locale.current.region?.identifier ?? "") ? (612, 792) : (595, 842)
    }

    /// Shows the sheet; `done` runs when it closes, with whether anything was printed. `problem` gets what keeps it from
    /// opening and `notice` what the layout had to leave out.
    public static func present(_ session: PdfEditSession, name: String, layout: PrintLayout = PrintLayout(), problem: (Problem) -> Void,
                               notice: (String, String) -> Void = { _, _ in }, done: ((Bool) -> Void)? = nil) {
        let data: Data
        do {
            if layout.isPlain {
                data = try item(session)
            } else {
                guard !layout.pages(count: session.document.pages.count).isEmpty else {
                    problem(Problem(L10n.t("Not printed"), L10n.t("None of the pages you chose are left to print.")))
                    return
                }
                let sheets = try layout.file(session.document, sheetWidth: paper.width, sheetHeight: paper.height)
                data = Data(sheets.bytes)
                if let note = PrintLayout.droppedNote(sheets.dropped) { notice(L10n.t("Left off the sheets"), note) }
            }
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
