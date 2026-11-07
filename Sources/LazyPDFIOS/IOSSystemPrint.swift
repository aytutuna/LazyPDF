#if os(iOS)
import UIKit

/// The system print sheet for the document as it is now.
@MainActor
public enum IOSSystemPrint {
    /// What is handed to the print sheet: the document's bytes, which it draws as they are.
    public static func item(_ pdf: [UInt8]) -> Data {
        Data(pdf)
    }

    public static func info(name: String) -> UIPrintInfo {
        let info = UIPrintInfo(dictionary: nil)
        info.jobName = name
        info.outputType = .general
        return info
    }

    /// Shows the sheet; `done` runs when it closes, with whether anything was printed.
    public static func present(_ pdf: [UInt8], name: String, done: ((Bool) -> Void)? = nil) {
        let controller = UIPrintInteractionController.shared
        controller.printInfo = info(name: name)
        controller.printingItem = item(pdf)
        controller.present(animated: true) { _, printed, _ in done?(printed) }
    }
}
#endif
