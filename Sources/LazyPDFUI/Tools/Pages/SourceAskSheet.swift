#if canImport(SwiftUI)
import SwiftUI
import LazyPDFApp
import LazyPDFKit

// The question of SourceQuestion; follows windows/LazyPDF.App/Tools/Pages/SourcePasswordWindow.xaml and
// SourceCertificateWindow.xaml: the password or the identity a file needs before a tool takes pages from it.

struct SourceAskSheet: View {
    let question: SourceQuestion
    let ask: SourceQuestion.Ask
    @State private var password = ""
    @State private var chosen: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(ask.kind == .certificate ? L10n.t("Choose a certificate") : L10n.t("Password needed"))
                .font(.title3.bold())
                .accessibilityAddTraits(.isHeader)
            Text(ask.kind == .certificate
                 ? L10n.t("{0} is encrypted for the holders of certain certificates. Pick the certificate that can open it.", ask.name)
                 : L10n.t("{0} needs a password to open.", ask.name))
                .fixedSize(horizontal: false, vertical: true)
            if ask.kind == .certificate {
                List(ask.choices, selection: $chosen) { choice in
                    VStack(alignment: .leading) {
                        Text(choice.name)
                        Text("\(choice.issuer) \u{00B7} \(choice.expires.formatted(date: .numeric, time: .omitted))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(choice.id)
                }
                .frame(minHeight: 120, maxHeight: 180)
                .accessibilityLabel(L10n.t("Certificates"))
            } else {
                SecureField(L10n.t("Password"), text: $password)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(submit)
            }
            if let problem = ask.problem {
                Text(problem)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.updatesFrequently)
            }
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button(L10n.t("Cancel"), role: .cancel) { question.giveUp() }
                    .keyboardShortcut(.cancelAction)
                Button(L10n.t("Open"), action: submit)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(ask.kind == .certificate && chosen == nil)
            }
        }
        .padding(24)
        .frame(minWidth: 320, idealWidth: 420)
        .presentationDetents([.medium])
    }

    private func submit() {
        if ask.kind == .certificate {
            question.answer(certificate: ask.choices.first { $0.id == chosen })
        } else {
            question.answer(password: password)
        }
    }
}

extension View {
    /// Shows the question of `question` as a sheet while there is one; closing the sheet gives up.
    func sourceQuestion(_ question: SourceQuestion) -> some View {
        sheet(item: Binding(get: { question.asking }, set: { if $0 == nil { question.giveUp() } })) { ask in
            SourceAskSheet(question: question, ask: ask)
        }
    }

    /// The keyboard of a field that takes a number.
    func numberField() -> some View {
        #if os(iOS)
        keyboardType(.decimalPad)
        #else
        self
        #endif
    }
}
#endif
