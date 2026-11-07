#if canImport(SwiftUI)
import SwiftUI
import LazyPDFApp
import LazyPDFKit

// The overlays of MainWindow.Overlays.cs that stand over the window: the unsaved-changes question and the recovery offer.
// The password question is a sheet (PasswordSheet) since it takes typing.

struct ModalCard<Buttons: View>: View {
    let title: String
    let text: String
    var detail: String?
    @ViewBuilder let buttons: () -> Buttons

    var body: some View {
        ZStack {
            Color.black.opacity(0.25)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {}
            VStack(alignment: .leading, spacing: 12) {
                Text(title)
                    .font(.title3.bold())
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text(text).fixedSize(horizontal: false, vertical: true)
                if let detail {
                    Text(detail)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    buttons()
                }
                .buttonStyle(.bordered)
            }
            .padding(24)
            .frame(minWidth: 320, maxWidth: 440)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .shadow(radius: 20)
            .padding(24)
        }
        .accessibilityAddTraits(.isModal)
    }
}

/// What to do with the changes of a document that is closing; with only redaction marks waiting there is nothing to save.
struct CloseCard: View {
    let tab: DocumentTab
    let save: () -> Void
    let discard: () -> Void
    let cancel: () -> Void

    var body: some View {
        let marksOnly = !tab.isDirty
        let lost = L10n.t("Your changes are lost if you do not save them.")
        let marks = L10n.plural(tab.pendingMarks, one: "{0} redaction mark is not applied yet.", other: "{0} redaction marks are not applied yet.")
        ModalCard(title: marksOnly ? L10n.t("Close {0}?", tab.title) : L10n.t("Save changes to {0}?", tab.title),
                  text: marksOnly ? marks : tab.pendingMarks > 0 ? "\(lost) \(marks)" : lost) {
            if !marksOnly {
                Button(L10n.t("Save"), action: save)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            Button(marksOnly ? L10n.t("Close") : L10n.t("Don't save"), role: marksOnly ? nil : .destructive, action: discard)
            Button(L10n.t("Cancel"), role: .cancel, action: cancel)
                .keyboardShortcut(.cancelAction)
        }
    }
}

/// After a crash: the documents that were open with changes.
struct RecoveryCard: View {
    let titles: [String]
    let restore: () -> Void
    let discard: () -> Void

    var body: some View {
        ModalCard(title: L10n.plural(titles.count, one: "Restore {0} file?", other: "Restore {0} files?"),
                  text: L10n.t("Lazy PDF closed before these were saved. Restore them to carry on where you were."),
                  detail: titles.joined(separator: "\n")) {
            Button(L10n.t("Restore"), action: restore)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            Button(L10n.t("Discard"), role: .destructive, action: discard)
        }
    }
}

/// The password or certificate of a locked file.
struct PasswordSheet: View {
    let vm: AppViewModel
    let request: OpenRequest
    /// Chooses a .p12 or .pfx file and returns the identity it put in the keychain; nil when the person gave up.
    var importCertificate: (@MainActor () async -> CertificateChoice?)?
    @State private var password = ""
    @State private var chosen: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(request.needsCertificate ? L10n.t("Choose a certificate") : L10n.t("Password needed"))
                .font(.title3.bold())
                .accessibilityAddTraits(.isHeader)
            Text(request.needsCertificate
                 ? L10n.t("{0} is encrypted for the holders of certain certificates. Pick the certificate that can open it.", request.name)
                 : L10n.t("{0} is protected. Type its password to open it.", request.name))
                .fixedSize(horizontal: false, vertical: true)
            if request.needsCertificate {
                List(request.certificates, selection: $chosen) { choice in
                    VStack(alignment: .leading) {
                        Text(choice.name)
                        Text("\(choice.issuer) \u{00B7} \(choice.expires.formatted(date: .numeric, time: .omitted))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(choice.id)
                }
                .frame(height: 160)
                .accessibilityLabel(L10n.t("Certificates"))
            } else {
                SecureField(L10n.t("Password"), text: $password)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(submit)
            }
            if let problem {
                Text(problem)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                if request.needsCertificate, let importCertificate {
                    Button(L10n.t("Import a certificate…")) {
                        Task {
                            if let choice = await importCertificate() { await vm.submitCertificate(choice) }
                        }
                    }
                }
                Spacer(minLength: 0)
                Button(L10n.t("Cancel"), role: .cancel) { vm.cancelPending() }
                    .keyboardShortcut(.cancelAction)
                Button(L10n.t("Open"), action: submit)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(request.needsCertificate && chosen == nil)
            }
        }
        .padding(24)
        .frame(minWidth: 340, idealWidth: 420)
        .onChange(of: request.attempts) { password = "" }
        .presentationDetents([.medium])
    }

    private var problem: String? {
        if request.needsCertificate && request.certificates.isEmpty {
            return L10n.t("No certificate with a private key was found. Import one from a .p12 or .pfx file.")
        }
        return request.problem
    }

    private func submit() {
        if request.needsCertificate {
            guard let choice = request.certificates.first(where: { $0.id == chosen }) else { return }
            Task { await vm.submitCertificate(choice) }
        } else {
            let typed = password
            Task { await vm.submitPassword(typed) }
        }
    }
}
#endif
