#if canImport(SwiftUI)
import SwiftUI
import LazyPDFApp
import LazyPDFKit

// The settings and About overlays of MainWindow.Overlays.cs. The Windows "Open with" switch is the platform shell's.

struct SettingsView: View {
    let vm: AppViewModel
    let about: () -> Void
    let certificates: (() -> Void)?
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.t("Settings"))
                .font(.title2.bold())
                .accessibilityAddTraits(.isHeader)
            Text(L10n.t("Appearance")).font(.callout.weight(.medium))
            Picker(L10n.t("Appearance"), selection: Binding(get: { vm.appearance }, set: { vm.setAppearance($0) })) {
                Text(L10n.t("System")).tag(AppAppearance.system)
                Text(L10n.t("Light")).tag(AppAppearance.light)
                Text(L10n.t("Dark")).tag(AppAppearance.dark)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            #if os(macOS)
            Toggle(L10n.t("Reopen files from last time"), isOn: Binding(get: { vm.reopenLast }, set: { vm.setReopenLast($0) }))
                .padding(.top, 4)
            Text(L10n.t("When Lazy PDF starts without a file, it opens the files and pages that were open when you quit."))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            #endif
            if let certificates {
                Button(L10n.t("Certificates"), action: certificates)
            }
            Button(L10n.t("About Lazy PDF"), action: about)
                .padding(.top, 8)
            HStack {
                Spacer(minLength: 0)
                Button(L10n.t("Done"), action: done)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(minWidth: 340, idealWidth: 440)
        .presentationDetents([.medium])
    }
}

struct AboutView: View {
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Lazy PDF")
                .font(.title2.bold())
                .accessibilityAddTraits(.isHeader)
            Text(L10n.t("Version {0}", AppInfo.version))
            Text(AppInfo.copyright).foregroundStyle(.secondary)
            Text(L10n.t("Free. Source available under PolyForm Noncommercial 1.0.0."))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
            HStack(spacing: 16) {
                if let site = URL(string: AppInfo.site) {
                    Link(((site.host ?? "") + site.path).trimmingCharacters(in: CharacterSet(charactersIn: "/")), destination: site)
                        .accessibilityLabel(L10n.t("Website"))
                }
                if let privacy = URL(string: AppInfo.privacyPage) {
                    Link(L10n.t("Privacy"), destination: privacy)
                }
                if let mail = URL(string: "mailto:" + AppInfo.supportAddress) {
                    Link(AppInfo.supportAddress, destination: mail)
                        .accessibilityLabel(L10n.t("Email support"))
                }
            }
            .padding(.vertical, 8)
            Text(L10n.t("Third-party notices")).font(.callout.weight(.medium))
            ScrollView([.vertical, .horizontal]) {
                Text(AppInfo.notices() ?? L10n.t("The notices file is missing from this copy of Lazy PDF. Reinstall the app to get it back."))
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 200)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            .accessibilityLabel(L10n.t("Third-party notices"))
            HStack {
                Spacer(minLength: 0)
                Button(L10n.t("Done"), action: done)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 8)
        }
        .padding(24)
        .frame(minWidth: 340, idealWidth: 520)
    }
}
#endif
