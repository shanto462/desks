import AppKit
import Combine
import DesksCore
import SwiftUI

enum SettingsPage: String, CaseIterable, Identifiable, Hashable {
    case general, layouts, shortcuts, rules, appearance, about
    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .layouts: return "Layouts"
        case .shortcuts: return "Shortcuts"
        case .rules: return "Rules"
        case .appearance: return "Appearance"
        case .about: return "Permissions & About"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape.fill"
        case .layouts: return "rectangle.3.group.fill"
        case .shortcuts: return "keyboard.fill"
        case .rules: return "list.bullet.rectangle.fill"
        case .appearance: return "paintbrush.fill"
        case .about: return "lock.shield.fill"
        }
    }

    var tint: Color {
        switch self {
        case .general: return .gray
        case .layouts: return .blue
        case .shortcuts: return .orange
        case .rules: return .purple
        case .appearance: return .pink
        case .about: return .green
        }
    }
}

@MainActor
final class SettingsNavigation: ObservableObject {
    struct LayoutRef: Equatable {
        let display: DisplayID
        let layout: Int
    }

    @Published var page: SettingsPage? = .general
    /// A layout row to open and scroll to on the Layouts page.
    @Published var focusedLayout: LayoutRef?
}

/// Owns the Settings window. Desks shows in the Dock while it is open.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let model: AppModel
    private let navigation = SettingsNavigation()
    private var window: NSWindow?
    private var titleSink: AnyCancellable?

    init(model: AppModel) {
        self.model = model
    }

    func showLayout(_ layout: Int, on display: DisplayID) {
        navigation.focusedLayout = .init(display: display, layout: layout)
        show(page: .layouts)
    }

    func show(page: SettingsPage? = nil) {
        if let page { navigation.page = page }
        let window = self.window ?? makeWindow()
        self.window = window
        NSApp.setActivationPolicy(.regular)
        // Give the Dock a moment to pick up the policy change, then bring the window forward.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        }
    }

    static let defaultSize = NSSize(width: 820, height: 600)
    static let minSize = NSSize(width: 760, height: 480)

    /// Builds the window. Also used by the render mode.
    static func makeSettingsWindow(model: AppModel, navigation: SettingsNavigation) -> NSWindow {
        let root = SettingsRootView(model: model, navigation: navigation)
        let controller = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: controller)
        window.title = (navigation.page ?? .general).title
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.toolbarStyle = .unified
        window.titlebarSeparatorStyle = .automatic
        window.toolbar = NSToolbar(identifier: "DesksSettingsToolbar")
        window.setContentSize(defaultSize)
        window.contentMinSize = minSize
        window.isReleasedWhenClosed = false
        return window
    }

    private func makeWindow() -> NSWindow {
        let window = Self.makeSettingsWindow(model: model, navigation: navigation)
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("DesksSettings")
        titleSink = navigation.$page.sink { [weak window] page in
            window?.title = (page ?? .general).title
        }
        return window
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

struct SettingsRootView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var navigation: SettingsNavigation

    var body: some View {
        NavigationSplitView {
            List(SettingsPage.allCases, selection: $navigation.page) { page in
                NavigationLink(value: page) {
                    Label {
                        Text(page.title)
                    } icon: {
                        SidebarIcon(symbol: page.symbol, tint: page.tint)
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
        } detail: {
            Group {
                switch navigation.page ?? .general {
                case .general: GeneralPage(model: model)
                case .layouts: LayoutsPage(model: model, navigation: navigation)
                case .shortcuts: ShortcutsPage()
                case .rules: RulesPage(model: model)
                case .appearance: AppearancePage()
                case .about: AboutPage(model: model)
                }
            }
            .navigationTitle((navigation.page ?? .general).title)
            .frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 680, minHeight: 460)
    }
}

/// Coloured rounded square with a white symbol, like System Settings.
struct SidebarIcon: View {
    let symbol: String
    let tint: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 22, height: 22)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(tint.gradient)
            )
    }
}
