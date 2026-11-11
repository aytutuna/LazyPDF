#if canImport(SwiftUI)
import SwiftUI
import LazyPDFApp
import LazyPDFKit

// Follows windows/LazyPDF.App/TabStripPanel.cs and MainWindow.Tabs.cs: Home, then the documents; the title, a dot while
// there are unsaved changes, a close button, a drag to move a tab and a click of the middle button to close it.

private struct TabEntry: Identifiable {
    let tab: any StripTab
    var id: ObjectIdentifier { ObjectIdentifier(tab) }
}

struct TabStrip: View {
    let vm: AppViewModel
    let close: (DocumentTab) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(vm.strip.map { TabEntry(tab: $0) }) { entry in
                    item(entry.tab)
                }
                // Dropping past the last tab puts the tab last.
                Color.clear
                    .frame(width: 24, height: 28)
                    .dropDestination(for: String.self) { ids, _ in
                        move(ids, to: vm.strip.count - 1)
                    }
            }
            .padding(.horizontal, 2)
        }
        .accessibilityLabel(L10n.t("Open files"))
    }

    @ViewBuilder private func item(_ tab: any StripTab) -> some View {
        let selected = vm.activeTab === tab
        let view = TabItem(tab: tab, selected: selected, select: { vm.select(tab) }, close: {
            if let document = tab as? DocumentTab { close(document) }
        })
        .dropDestination(for: String.self) { ids, _ in
            move(ids, to: vm.strip.firstIndex { $0 === tab } ?? vm.strip.count - 1)
        }
        if let document = tab as? DocumentTab {
            view.draggable(document.id.uuidString)
        } else {
            view
        }
    }

    private func move(_ ids: [String], to index: Int) -> Bool {
        guard let id = ids.first, let tab = vm.documents.first(where: { $0.id.uuidString == id }) else { return false }
        vm.moveTab(tab, to: index)
        return true
    }
}

private struct TabItem: View {
    let tab: any StripTab
    let selected: Bool
    let select: () -> Void
    let close: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Button(action: select) {
                HStack(spacing: 6) {
                    Image(systemName: tab.symbol)
                    Text(tab.title).lineLimit(1)
                    if tab.isDirty {
                        Circle().fill(.secondary).frame(width: 6, height: 6)
                    }
                }
                .foregroundStyle(selected ? Color.primary : Color.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(tab.automationName)
            .accessibilityAddTraits(selected ? .isSelected : [])
            if tab.canClose {
                Button(action: close) {
                    Image(systemName: "xmark").font(.caption2)
                }
                .buttonStyle(.plain)
                .help(L10n.t("Close"))
                .accessibilityLabel(L10n.t("Close"))
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, tab.canClose ? 8 : 10)
        .padding(.vertical, 5)
        .background(selected ? Color.accentColor.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
        .overlay(alignment: .bottom) {
            if selected {
                Capsule().fill(Color.accentColor).frame(height: 2).padding(.horizontal, 8)
            }
        }
        .contentShape(Rectangle())
        .contextMenu {
            if tab.canClose {
                Button(L10n.t("Close"), action: close)
            }
        }
        .closesOnMiddleClick(enabled: tab.canClose, close)
    }
}

/// The tabs of an open file as a menu: the strip's stand-in on the iPhone, and its list of everything when it overflows.
struct DocumentSwitcher: View {
    let vm: AppViewModel
    var showsTitle = true

    var body: some View {
        Menu {
            ForEach(vm.strip.map { TabEntry(tab: $0) }) { entry in
                Toggle(isOn: Binding(get: { vm.activeTab === entry.tab }, set: { _ in vm.select(entry.tab) })) {
                    Label(entry.tab.isDirty ? entry.tab.title + " \u{2022}" : entry.tab.title, systemImage: entry.tab.symbol)
                }
                .accessibilityLabel(entry.tab.automationName)
            }
        } label: {
            if showsTitle {
                Label(vm.activeTab.isDirty ? vm.activeTab.title + " \u{2022}" : vm.activeTab.title, systemImage: vm.activeTab.symbol)
                    .accessibilityLabel(vm.activeTab.automationName)
            } else {
                Image(systemName: "list.bullet")
            }
        }
        .help(L10n.t("All open files"))
        .accessibilityLabel(L10n.t("All open files"))
    }
}

#if os(macOS)
import AppKit

private struct MiddleClickCatcher: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.action = action
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.action = action
    }

    // Takes the mouse only for the middle button, so every other click reaches the tab below.
    final class CatcherView: NSView {
        var action: () -> Void = {}

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let type = NSApp.currentEvent?.type, type == .otherMouseDown || type == .otherMouseUp else { return nil }
            return super.hitTest(point)
        }

        override func otherMouseUp(with event: NSEvent) {
            if event.buttonNumber == 2 { action() } else { super.otherMouseUp(with: event) }
        }
    }
}

extension View {
    func closesOnMiddleClick(enabled: Bool, _ action: @escaping () -> Void) -> some View {
        overlay { if enabled { MiddleClickCatcher(action: action) } }
    }
}
#else
extension View {
    func closesOnMiddleClick(enabled: Bool, _ action: @escaping () -> Void) -> some View {
        self
    }
}
#endif
#endif
