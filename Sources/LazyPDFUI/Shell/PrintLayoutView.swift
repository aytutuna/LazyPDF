#if canImport(SwiftUI)
import SwiftUI
import LazyPDFApp
import LazyPDFKit

// Follows windows/LazyPDF.App/Services/PrintLayoutWindow.xaml. The Mac print panel has pages per sheet of its own, so
// the Mac asks only for the rest.

@MainActor
@Observable
public final class PrintLayoutChoice {
    public var layout = PrintLayout()

    public init() {}
}

public struct PrintLayoutView: View {
    let choice: PrintLayoutChoice
    let askPerSheet: Bool

    public init(choice: PrintLayoutChoice, askPerSheet: Bool) {
        self.choice = choice
        self.askPerSheet = askPerSheet
    }

    public var body: some View {
        @Bindable var choice = choice
        VStack(alignment: .leading, spacing: 12) {
            if askPerSheet {
                Picker(L10n.t("Pages per sheet"), selection: $choice.layout.perSheet) {
                    ForEach(PrintLayout.perSheetChoices, id: \.self) { Text("\($0)").tag($0) }
                }
                .disabled(choice.layout.booklet)
            }
            Toggle(L10n.t("Booklet"), isOn: $choice.layout.booklet)
            Text(L10n.t("Two pages on each side of a landscape sheet, in the order that folds into a booklet."))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Picker(L10n.t("Pages"), selection: $choice.layout.parity) {
                Text(L10n.t("All pages")).tag(PrintParity.all)
                Text(L10n.t("Odd pages only")).tag(PrintParity.odd)
                Text(L10n.t("Even pages only")).tag(PrintParity.even)
            }
        }
    }
}

/// The sheet the iPhone and iPad show before the print sheet.
public struct PrintLayoutSheet: View {
    @State private var choice = PrintLayoutChoice()
    let print: (PrintLayout) -> Void
    let close: () -> Void

    public init(print: @escaping (PrintLayout) -> Void, close: @escaping () -> Void) {
        self.print = print
        self.close = close
    }

    public var body: some View {
        VStack(spacing: 0) {
            Text(L10n.t("Print layout"))
                .font(.headline)
                .padding(.top, 12)
                .accessibilityAddTraits(.isHeader)
            PrintLayoutView(choice: choice, askPerSheet: true)
                .padding()
            Divider()
            HStack {
                Spacer()
                Button(L10n.t("Cancel"), role: .cancel) { close() }
                    .keyboardShortcut(.cancelAction)
                Button(L10n.t("Print")) { print(choice.layout) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding()
        }
        .presentationDetents([.medium])
    }
}
#endif
