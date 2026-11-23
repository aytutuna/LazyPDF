#if canImport(SwiftUI)
import SwiftUI
import LazyPDFApp
import LazyPDFKit

// Follows windows/LazyPDF.App/Services/PrintLayoutWindow.xaml. The Mac print panel has pages per sheet, a page range,
// odd or even pages and a page order of its own, so the Mac asks only for the booklet and its binding. The iPhone's
// print sheet has none of them and counts pages of the file made here, so the rest is asked for there.

@MainActor
@Observable
public final class PrintLayoutChoice {
    public var layout: PrintLayout
    let documentPages: Int
    let sheetWidth: Double
    let sheetHeight: Double

    /// `remembered` is what was kept from the last print; the binding always starts from the document's reading direction.
    public init(remembered: PrintLayout = PrintLayout(), rightToLeft: Bool = false, documentPages: Int = 0,
                sheetWidth: Double = 612, sheetHeight: Double = 792) {
        layout = remembered
        layout.rightToLeft = rightToLeft
        self.documentPages = documentPages
        self.sheetWidth = sheetWidth
        self.sheetHeight = sheetHeight
    }

    var gapMillimeters: Double {
        get { (layout.gap * 25.4 / 72).rounded() }
        set { layout.gap = newValue * 72 / 25.4 }
    }

    /// What keeps the layout from being printed: a wrong range or a gap with no room.
    var problem: String? {
        layout.rangeError(count: documentPages) ?? layout.validate(sheetWidth: sheetWidth, sheetHeight: sheetHeight)
    }

    var canPrint: Bool { problem == nil && !layout.isEmpty(count: documentPages) }
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
            if choice.layout.imposes {
                Picker(L10n.t("Binding"), selection: $choice.layout.rightToLeft) {
                    Text(L10n.t("Left")).tag(false)
                    Text(L10n.t("Right")).tag(true)
                }
                .pickerStyle(.segmented)
            }
            if onPhone {
                PhoneOptions(choice: choice)
            } else if choice.layout.booklet {
                Text(L10n.t("Two-sided printing must flip on the short edge."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(L10n.t("The print panel's page range and odd or even pages then count the sides of the booklet."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct PhoneOptions: View {
    @Bindable var choice: PrintLayoutChoice

    var body: some View {
        if choice.layout.imposes {
            Stepper(value: $choice.gapMillimeters, in: 0...25, step: 1) {
                Text(L10n.t("Gap between pages (mm)") + ": \(Int(choice.gapMillimeters))")
            }
            Toggle(L10n.t("Border around each page"), isOn: $choice.layout.border)
        }
        TextField(L10n.t("Pages to print, like 1-3, 5"), text: $choice.layout.range)
            .textFieldStyle(.roundedBorder)
            .autocorrectionDisabled()
        let sides = choice.layout.imposes
        Picker(L10n.t("Which sides"), selection: $choice.layout.parity) {
            Text(L10n.t("All pages")).tag(PrintParity.all)
            Text(sides ? L10n.t("Odd sides only") : L10n.t("Odd pages only")).tag(PrintParity.odd)
            Text(sides ? L10n.t("Even sides only") : L10n.t("Even pages only")).tag(PrintParity.even)
        }
        Toggle(L10n.t("Last side first"), isOn: $choice.layout.reverse)
        Text(hint(choice.layout))
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        if let problem = choice.problem {
            Text(problem)
                .font(.footnote)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
        Text(choice.layout.summary(documentPages: choice.documentPages))
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel(choice.layout.summary(documentPages: choice.documentPages))
            .onChange(of: choice.layout) {
                AccessibilityNotification.Announcement(choice.problem ?? choice.layout.summary(documentPages: choice.documentPages)).post()
            }
    }

    private func hint(_ layout: PrintLayout) -> String {
        if layout.booklet && layout.parity == .all && !layout.reverse { return L10n.t("Two-sided printing must flip on the short edge.") }
        if layout.imposes { return L10n.t("To print both sides by hand, print the odd sides, turn the stack over and print the even sides.") }
        return L10n.t("Odd and even go by page number. To print both sides by hand, print the odd pages, turn the stack over and print the even pages.")
    }
}

/// The sheet the iPhone and iPad show before the print sheet.
public struct PrintLayoutSheet: View {
    @State private var choice: PrintLayoutChoice
    let print: (PrintLayout) -> Void
    let close: () -> Void

    public init(remembered: PrintLayout, rightToLeft: Bool, documentPages: Int, sheetWidth: Double, sheetHeight: Double,
                print: @escaping (PrintLayout) -> Void, close: @escaping () -> Void) {
        _choice = State(initialValue: PrintLayoutChoice(remembered: remembered, rightToLeft: rightToLeft, documentPages: documentPages,
                                                        sheetWidth: sheetWidth, sheetHeight: sheetHeight))
        self.print = print
        self.close = close
    }

    public var body: some View {
        VStack(spacing: 0) {
            Text(L10n.t("Print layout"))
                .font(.headline)
                .padding(.top, 12)
                .accessibilityAddTraits(.isHeader)
            ScrollView {
                PrintLayoutView(choice: choice, onPhone: true)
                    .padding()
            }
            Divider()
            HStack {
                Spacer()
                Button(L10n.t("Cancel"), role: .cancel) { close() }
                    .keyboardShortcut(.cancelAction)
                Button(L10n.t("Print")) { print(choice.layout) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!choice.canPrint)
            }
            .padding()
        }
        .presentationDetents([.medium, .large])
    }
}
#endif
