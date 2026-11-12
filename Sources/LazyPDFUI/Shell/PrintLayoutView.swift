#if canImport(SwiftUI)
import SwiftUI
import LazyPDFApp
import LazyPDFKit

// Follows windows/LazyPDF.App/Services/PrintLayoutWindow.xaml. The Mac print panel has pages per sheet, a page range
// and odd or even pages of its own, so the Mac asks only for the booklet. The iPhone's print sheet has no odd or even
// and counts pages of the file made here, so the range is asked for with the rest.

@MainActor
@Observable
public final class PrintLayoutChoice {
    public var layout = PrintLayout()

    public init() {}
}

public struct PrintLayoutView: View {
    let choice: PrintLayoutChoice
    let onPhone: Bool

    public init(choice: PrintLayoutChoice, onPhone: Bool) {
        self.choice = choice
        self.onPhone = onPhone
    }

    public var body: some View {
        @Bindable var choice = choice
        VStack(alignment: .leading, spacing: 12) {
            if onPhone {
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
            if onPhone {
                TextField(L10n.t("Pages to print, like 1-3, 5"), text: $choice.layout.range)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                Picker(L10n.t("Pages"), selection: $choice.layout.parity) {
                    Text(L10n.t("All pages")).tag(PrintParity.all)
                    Text(L10n.t("Odd pages only")).tag(PrintParity.odd)
                    Text(L10n.t("Even pages only")).tag(PrintParity.even)
                }
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
            PrintLayoutView(choice: choice, onPhone: true)
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
